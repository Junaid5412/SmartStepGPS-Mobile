import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// The version shown in reports - keep in step with pubspec.yaml.
const String kAppVersion = '1.2.13+36';

/// Errors the app catches are reported to the portal (api/mobile/app_error.php -> App Errors page).
///
/// An iPhone that failed on start-up left nothing behind to look at: the phone could not be connected to a Mac
/// and no report reached the portal. Every error caught here - Flutter's own, an uncaught async one, a plugin's -
/// is sent with the app version, the phone's system and the screen it happened on. Nothing personal: no names,
/// no tokens, no positions. The same error is sent once per run, at most 20 a run, and a failure to send is
/// silently dropped - reporting must never itself become a problem.
class AppErrors {
  AppErrors._();

  /// The screen on show, for the report (set by the main screens).
  static String screen = 'start';

  static final Set<String> _seen = {};
  static int _sent = 0;
  static String? _installId;

  static Future<String> _id() async {
    if (_installId != null) return _installId!;
    try {
      final p = await SharedPreferences.getInstance();
      var id = p.getString('install_id');
      if (id == null || id.isEmpty) {
        final r = Random.secure();
        id = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
        await p.setString('install_id', id);
      }
      return _installId = id;
    } catch (_) {
      return _installId = 'unknown';
    }
  }

  static Future<void> report(Object error, StackTrace? stack, {String kind = 'error'}) async {
    try {
      final msg = error.toString();
      debugPrint('AppErrors [$kind] $msg');
      final key = '$kind|${msg.length > 240 ? msg.substring(0, 240) : msg}';
      if (!_seen.add(key) || _sent >= 20) return;
      _sent++;
      final id = await _id();
      await http
          .post(
            Uri.parse('${ApiService.baseUrl}/app_error.php'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'platform': Platform.isIOS ? 'ios' : Platform.isAndroid ? 'android' : Platform.operatingSystem,
              'os': Platform.operatingSystemVersion,
              'app_version': kAppVersion,
              'kind': kind,
              'screen': screen,
              'message': msg.length > 2000 ? msg.substring(0, 2000) : msg,
              'stack': (stack ?? StackTrace.empty).toString().split('\n').take(60).join('\n'),
              'install_id': id,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // never let reporting fail the app
    }
  }

  /// Catch everything Flutter and the platform let through, report it, and keep the app running.
  static void install() {
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      if (prev != null) prev(details);
      report(details.exception, details.stack, kind: details.silent ? 'flutter_silent' : 'flutter');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack, kind: 'uncaught');
      return true;   // handled: an uncaught async error must not close the app
    };
  }
}
