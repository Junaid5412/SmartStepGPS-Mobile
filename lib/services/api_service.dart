import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiService {
  static const String defaultBaseUrl = 'https://gps.khanhub.site/api/mobile';
  static String baseUrl = defaultBaseUrl;

  static const _secureStorage = FlutterSecureStorage();

  static Future<String> getToken() async {
    String? token = await _secureStorage.read(key: 'api_token');
    if (token != null && token.isNotEmpty) return token;

    // Fallback/Migration from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString('api_token');
    if (token != null && token.isNotEmpty) {
      await _secureStorage.write(key: 'api_token', value: token);
      await prefs.remove('api_token');
      return token;
    }
    return '';
  }

  static Future<void> setToken(String token) async {
    await _secureStorage.write(key: 'api_token', value: token);
  }

  static Future<void> clearToken() async {
    await _secureStorage.delete(key: 'api_token');
  }

  /// Only an https URL on a host we own may replace the base URL.
  ///
  /// This override is read from SharedPreferences, which is plain, unencrypted XML inside the app
  /// sandbox - readable on a rooted or debuggable device. Previously any string was accepted, so
  /// writing `http://attacker.example/` there would have sent every request, including the login
  /// credentials and the Bearer token, to that host in cleartext. Scheme and host are now both
  /// checked, and anything that fails falls back to the built-in default.
  static const List<String> _allowedHosts = ['gps.khanhub.site'];

  static bool _isAllowedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'https') return false;
    return _allowedHosts.contains(uri.host);
  }

  static Future<void> initBaseUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('custom_api_url');
      if (savedUrl != null && savedUrl.trim().isNotEmpty) {
        final cleaned = savedUrl.trim().replaceAll(RegExp(r'/+$'), '');
        if (_isAllowedUrl(cleaned)) {
          baseUrl = cleaned;
        } else {
          // Tampered or stale value - discard it and go back to the default.
          await prefs.remove('custom_api_url');
          baseUrl = defaultBaseUrl;
        }
      }
    } catch (e) { debugPrint('ApiService: could not read saved base URL: $e'); }
  }

  static Future<bool> setBaseUrl(String newUrl) async {
    final cleaned = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (!_isAllowedUrl(cleaned)) return false;
    baseUrl = cleaned;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_api_url', baseUrl);
    return true;
  }

  static Map<String, dynamic> _safeDecode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'success': false, 'error': 'Invalid response format'};
    } catch (e) {
      // Extract JSON if preceded by PHP warnings or notices
      final firstBrace = body.indexOf('{');
      final lastBrace = body.lastIndexOf('}');
      if (firstBrace != -1 && lastBrace != -1 && lastBrace > firstBrace) {
        try {
          final sub = body.substring(firstBrace, lastBrace + 1);
          final decoded = jsonDecode(sub);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) { /* this was only a best-effort retry; the HTML-stripping fallback below still runs */ }
      }
      // Remove HTML tags if server threw an error page
      final clean = body.replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
      return {'success': false, 'error': clean.isNotEmpty ? clean : 'Invalid server response'};
    }
  }

  static Future<Map<String, dynamic>> login(String username, String password, String fcmToken) async {
    final response = await http.post(
      Uri.parse('$baseUrl/login.php'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'fcm_token': fcmToken,
      }),
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getSettings() async {
    final response = await http.get(Uri.parse('$baseUrl/settings.php'));
    if (response.statusCode == 200) {
      return _safeDecode(response.body);
    }
    return {'success': false};
  }

  static Future<Map<String, dynamic>> getParentStudents() async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    final response = await http.get(
      Uri.parse('$baseUrl/parent_students.php'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getBusLocation(int deviceId, {int? studentId}) async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    String url = '$baseUrl/bus_location.php?device_id=$deviceId';
    if (studentId != null && studentId > 0) {
      url += '&student_id=$studentId';
    }
    final response = await http.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getAttendanceHistory(int studentId) async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    final response = await http.get(
      Uri.parse('$baseUrl/attendance_history.php?student_id=$studentId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getLeaveRequests() async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    final response = await http.get(
      Uri.parse('$baseUrl/leave_request.php'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> submitLeave(int studentId, String leaveDate, String reason, String comment) async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/leave_request.php'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'student_id': studentId,
        'leave_date': leaveDate,
        'reason': reason,
        'comment': comment,
      }),
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getAnnouncements() async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    final response = await http.get(
      Uri.parse('$baseUrl/announcements.php'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getRoster() async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();

    final response = await http.get(
      Uri.parse('$baseUrl/roster.php'),
      headers: {
        'Authorization': 'Bearer $token',
      },
    );
    return _safeDecode(response.body);
  }

  /// [lat]/[lng] are nullable on purpose. When the monitor has no usable fix we send JSON null, so
  /// the server stores NULL and the portal can honestly say "No GPS Stamp" — rather than the old
  /// behaviour of sending 0.0, 0.0, which recorded a real-looking coordinate off the coast of Africa
  /// for every attendance event ever taken.
  static Future<Map<String, dynamic>> markAttendance(
      int studentId, String eventType, double? lat, double? lng,
      {String shift = 'morning'}) async {
    final token = await getToken();

    final response = await http.post(
      Uri.parse('$baseUrl/attendance.php'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'student_id': studentId,
        'event_type': eventType,
        'shift': shift,
        'lat': lat,
        'lng': lng,
      }),
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    final response = await http.get(
      Uri.parse('$baseUrl/profile.php'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> updateProfile({
    required String fatherName,
    required String fatherPhone,
    required String fatherEmail,
    required String motherName,
    required String motherPhone,
    required String motherEmail,
    required String address,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/profile.php'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'update_profile',
        'father_name': fatherName,
        'father_phone': fatherPhone,
        'father_email': fatherEmail,
        'mother_name': motherName,
        'mother_phone': motherPhone,
        'mother_email': motherEmail,
        'address': address,
      }),
    );
    final data = _safeDecode(response.body);
    if (data['success'] == true && data['updated_name'] != null) {
      await prefs.setString('user_name', data['updated_name']);
    }
    return data;
  }

  /// Raises an account-deletion request. Nothing is deleted here: a school administrator reviews it,
  /// and the account is removed only on approval.
  static Future<Map<String, dynamic>> requestAccountDeletion({String reason = ''}) async {
    final token = await getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/delete_account.php'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'reason': reason}),
    );
    return _safeDecode(response.body);
  }

  /// Status of the most recent deletion request for the signed-in account, if any.
  static Future<Map<String, dynamic>> getAccountDeletionStatus() async {
    final token = await getToken();
    final response = await http.get(
      Uri.parse('$baseUrl/delete_account.php'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> changePassword(String oldPassword, String newPassword) async {
    final prefs = await SharedPreferences.getInstance();
    final token = await getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/profile.php'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'change_password',
        'old_password': oldPassword,
        'new_password': newPassword,
      }),
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> requestPasswordOtp(String identifier) async {
    final response = await http.post(
      Uri.parse('$baseUrl/forgot_password.php'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'request_otp',
        'identifier': identifier,
      }),
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> verifyPasswordReset(String email, String otp, String newPassword) async {
    final response = await http.post(
      Uri.parse('$baseUrl/forgot_password.php'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'verify_reset',
        'email': email,
        'otp': otp,
        'new_password': newPassword,
      }),
    );
    return _safeDecode(response.body);
  }
}
