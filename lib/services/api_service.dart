import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static const String defaultBaseUrl = 'https://gps.khanhub.site/api/mobile';
  static String baseUrl = defaultBaseUrl;

  static Future<void> initBaseUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('custom_api_url');
      if (savedUrl != null && savedUrl.trim().isNotEmpty) {
        baseUrl = savedUrl.trim().replaceAll(RegExp(r'/+$'), '');
      }
    } catch (_) {}
  }

  static Future<void> setBaseUrl(String newUrl) async {
    baseUrl = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_api_url', baseUrl);
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
        } catch (_) {}
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
    final token = prefs.getString('api_token') ?? '';
    final response = await http.get(
      Uri.parse('$baseUrl/parent_students.php'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getBusLocation(int deviceId, {int? studentId}) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';
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
    final token = prefs.getString('api_token') ?? '';
    final response = await http.get(
      Uri.parse('$baseUrl/attendance_history.php?student_id=$studentId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getLeaveRequests() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';
    final response = await http.get(
      Uri.parse('$baseUrl/leave_request.php'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> submitLeave(int studentId, String leaveDate, String reason, String comment) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';
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
    final token = prefs.getString('api_token') ?? '';
    final response = await http.get(
      Uri.parse('$baseUrl/announcements.php'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> getRoster() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';

    final response = await http.get(
      Uri.parse('$baseUrl/roster.php'),
      headers: {
        'Authorization': 'Bearer $token',
      },
    );
    return _safeDecode(response.body);
  }

  static Future<Map<String, dynamic>> markAttendance(int studentId, String eventType, double lat, double lng, {String shift = 'morning'}) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';

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
    final token = prefs.getString('api_token') ?? '';
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
    final token = prefs.getString('api_token') ?? '';
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

  static Future<Map<String, dynamic>> changePassword(String oldPassword, String newPassword) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';
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
