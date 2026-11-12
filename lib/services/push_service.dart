import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'app_errors.dart';

/// Notifications for parents: the phone's registration for push, and the unread count for the bell.
///
/// Push itself is native: Google FCM on Android (android/.../Push.kt), Apple APNs on iPhone (ios/Runner/AppDelegate.swift).
/// This class asks the phone for its push address ("token") and gives it to the school's server, which then knows where
/// to send. Nothing here is needed for the Notifications screen to work: when push is not set up on the portal, or the
/// person said no to notifications, the list still fills and the bell still counts while the app is open.
class PushService extends ChangeNotifier {
  PushService._();
  static final PushService instance = PushService._();

  static const MethodChannel _native = MethodChannel('smartstep/push');
  static const String _androidPackage = 'com.smartstep.gps';

  int _unread = 0;
  int _lastId = -1;          // -1: not heard from the server yet (the first answer must not count as "new")
  String? _token;            // this phone's push address, once registered
  bool _registering = false;

  int get unread => _unread;

  /// True when this phone is registered for push: a new notification then arrives as a system notification, and the
  /// app does not also need to show its own banner.
  bool get registered => _token != null;

  /// The newest notification, when one arrived while the app is open and the phone is NOT registered for push.
  /// The dashboard shows it once and clears it.
  Map<String, dynamic>? pendingBanner;

  /// From the few-seconds poll (ModuleWatcher): {last_id, unread}.
  void applyPoll(Map<dynamic, dynamic> n) {
    final last = (n['last_id'] as num?)?.toInt() ?? 0;
    final unread = (n['unread'] as num?)?.toInt() ?? 0;
    final isNew = _lastId >= 0 && last > _lastId;
    final changed = unread != _unread || last != _lastId;
    final after = _lastId;
    _lastId = last;
    _unread = unread;
    if (isNew && !registered) _fetchBanner(after);
    if (changed) notifyListeners();
  }

  Future<void> _fetchBanner(int after) async {
    try {
      final res = await ApiService.getNotifications(after: after);
      final list = res['notifications'];
      if (res['success'] == true && list is List && list.isNotEmpty && list.first is Map) {
        pendingBanner = Map<String, dynamic>.from(list.first as Map);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('PushService: banner fetch failed: $e');
    }
  }

  /// The list was opened and everything marked read.
  void markAllRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
    if (Platform.isIOS) _native.invokeMethod('clearBadge').catchError((_) => null);
  }

  /// Register this phone for the signed-in family's notifications. Safe to call on every start: the token changes
  /// rarely, and the server simply refreshes it. [ask] = show the system's "Allow notifications?" question if it has
  /// not been answered yet.
  Future<void> start({bool ask = true}) async {
    if (_registering) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _registering = true;
    try {
      String? token;
      if (Platform.isAndroid) {
        // What Firebase needs comes from the school's server (uploaded on the portal) - null while push is not set up.
        final cfg = await ApiService.getPushClient(_androidPackage);
        final f = cfg['fcm'];
        if (f is! Map) return;
        if (ask) await _native.invokeMethod('ask');
        token = await _native.invokeMethod<String>('register', {
          'app_id': '${f['app_id'] ?? ''}',
          'api_key': '${f['api_key'] ?? ''}',
          'project_id': '${f['project_id'] ?? ''}',
          'sender_id': '${f['sender_id'] ?? ''}',
        });
      } else {
        if (!ask && (await _native.invokeMethod<bool>('allowed')) != true) return;
        token = await _native.invokeMethod<String>('register');
        _native.invokeMethod('clearBadge').catchError((_) => null);
      }
      if (token == null || token.isEmpty) return;
      final res = await ApiService.postNotifications({
        'action': 'register',
        'platform': Platform.isIOS ? 'ios' : 'android',
        'token': token,
        'app_version': kAppVersion,
      });
      if (res['success'] == true) {
        _token = token;
        try {
          (await SharedPreferences.getInstance()).setString('push_token', token);
        } catch (_) {/* only used to sign this phone off later */}
        notifyListeners();
      }
    } on MissingPluginException {
      // an older native build without the channel: no push, everything else works
    } catch (e, st) {
      AppErrors.report(e, st, kind: 'push_register');
    } finally {
      _registering = false;
    }
  }

  /// Signing out: this phone must stop getting the family's notifications. Call BEFORE the sign-in token is cleared.
  Future<void> stop() async {
    String? token = _token;
    try {
      token ??= (await SharedPreferences.getInstance()).getString('push_token');
    } catch (_) {}
    _token = null;
    _unread = 0;
    _lastId = -1;
    pendingBanner = null;
    if (token != null && token.isNotEmpty) {
      try {
        await ApiService.postNotifications({'action': 'unregister', 'token': token}).timeout(const Duration(seconds: 6));
      } catch (e) {
        debugPrint('PushService: unregister failed: $e');
      }
    }
    try {
      await _native.invokeMethod('unregister');
    } catch (_) {/* nothing registered */}
  }
}
