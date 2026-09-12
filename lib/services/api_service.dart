import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static const String baseUrl = 'https://gps.khanhub.site/api/mobile';

  static Future<Map<String, dynamic>> login(String username, String password, String fcmToken) async {
    final response = await http.post(
      Uri.parse('\$baseUrl/login.php'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'fcm_token': fcmToken,
      }),
    );
    return jsonDecode(response.body);
  }

  static Future<Map<String, dynamic>> getRoster() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';

    final response = await http.get(
      Uri.parse('\$baseUrl/roster.php'),
      headers: {
        'Authorization': 'Bearer \$token',
      },
    );
    return jsonDecode(response.body);
  }

  static Future<Map<String, dynamic>> markAttendance(int studentId, String eventType, double lat, double lng) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';

    final response = await http.post(
      Uri.parse('\$baseUrl/attendance.php'),
      headers: {
        'Authorization': 'Bearer \$token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'student_id': studentId,
        'event_type': eventType,
        'lat': lat,
        'lng': lng,
      }),
    );
    return jsonDecode(response.body);
  }
}
