import 'dart:async';
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import 'map_config.dart';

/// Keeps the school's app-module switches (App Module Settings on the portal) current while the parent
/// app is open.
///
/// The dashboard used to re-read the full settings every 10 seconds, and only the dashboard listened: a
/// module switched off while the parent was already INSIDE it (the map, attendance, notices, leave) stayed
/// on screen. Now one small request goes out every few seconds, and everything that shows a module -
/// the dashboard's cards and each module's own screen - listens to the same source and reacts at once.
class ModuleWatcher extends ChangeNotifier {
  ModuleWatcher._();
  static final ModuleWatcher instance = ModuleWatcher._();

  static const Duration every = Duration(seconds: 3);

  final Map<String, bool> _modules = {
    'attendance': true,
    'bus_tracking': true,
    'announcements': true,
    'leave': true,
    'call_monitor': true,
  };
  Timer? _timer;
  bool _busy = false;
  int _users = 0;

  Map<String, bool> get modules => Map<String, bool>.unmodifiable(_modules);

  /// On unless the school switched it off.
  bool isOn(String key) => _modules[key] != false;

  /// Begin polling (counted: the dashboard starts it, and it stops when the last user stops).
  void start() {
    _users++;
    if (_timer != null) return;
    _poll();
    _timer = Timer.periodic(every, (_) => _poll());
  }

  void stop() {
    if (_users > 0) _users--;
    if (_users == 0) {
      _timer?.cancel();
      _timer = null;
      // Nobody is watching any more (signed out): forget the last school's switches, so the next person
      // to sign in on this phone - a monitor, or a parent of another school - starts from a clean slate.
      _modules.updateAll((k, v) => true);
    }
  }

  /// Ask right now (the app has just come back to the front).
  Future<void> refresh() => _poll();

  /// Take the flags from a settings response too, so both sources always agree.
  void apply(Map<dynamic, dynamic> m) => _merge(m);

  void _merge(Map<dynamic, dynamic> m) {
    var changed = false;
    for (final k in _modules.keys.toList()) {
      if (!m.containsKey(k)) continue;
      final v = m[k] != false;
      if (_modules[k] != v) {
        _modules[k] = v;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> _poll() async {
    if (_busy) return;
    _busy = true;
    try {
      final res = await ApiService.getModules();
      if (res['success'] != true) return;
      final m = res['modules'];
      if (m is Map) _merge(m);
      // The map chosen on the portal travels with the switches: an open map changes over within seconds.
      final mp = res['map'];
      if (mp is Map) MapConfig.instance.apply(mp);
    } catch (e) {
      debugPrint('ModuleWatcher: poll failed: $e');
    } finally {
      _busy = false;
    }
  }
}
