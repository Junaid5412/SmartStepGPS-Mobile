import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../services/api_service.dart';
import 'monitor_store.dart';

/// The monitor's phone position, shared by every monitor screen - and sent to the server as the
/// BACKUP position of the bus, for parents, when the bus's GPS tracker has gone quiet.
///
/// Runs only while a shift is open. Sending stops as soon as every child of the shift is done (at
/// school in the morning, home in the evening), and backs off when the school has the backup
/// switched off for this bus (Fleet -> Monitor Phone Backup on the portal).
class PhoneLocation {
  PhoneLocation._();
  static final PhoneLocation instance = PhoneLocation._();

  static const _sendEvery = Duration(seconds: 5); // parents' map asks every 3 s
  static const _offRetry = Duration(minutes: 2); // re-ask whether the backup was switched on

  /// The latest phone fix, or null.
  final ValueNotifier<LatLng?> position = ValueNotifier(null);
  DateTime? at;
  Position? _last;

  StreamSubscription<Position>? _gps;
  Timer? _sender;
  bool _starting = false;
  bool _send = false;
  DateTime? _offUntil;
  bool _asked = false; // the permission prompt once per app run, not every 20 s
  bool _uploading = false;

  bool get running => _gps != null || _starting;

  /// Called whenever the roster or the clock changes: run while a shift is open, send while
  /// that shift still has children to pick up or drop off.
  void sync(MonitorStore store) {
    final w = store.focus;
    final open = w != null && w.isOpen;
    if (!open) {
      stop();
      return;
    }
    final c = store.counts(w.key);
    _send = c.total > 0 && c.done < c.total;
    if (!running) _start();
    if (_send && _sender == null) {
      _sender = Timer.periodic(_sendEvery, (_) => _upload());
      _upload();
    } else if (!_send) {
      _sender?.cancel();
      _sender = null;
    }
  }

  Future<void> _start() async {
    _starting = true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && !_asked) {
        _asked = true;
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      if (!_starting) return; // stopped while asking
      _gps = Geolocator.getPositionStream(locationSettings: _settings()).listen((p) {
        _last = p;
        at = DateTime.now();
        position.value = LatLng(p.latitude, p.longitude);
      }, onError: (Object e) => debugPrint('Phone location: $e'));
    } catch (e) {
      debugPrint('Phone location unavailable: $e');
    } finally {
      _starting = false;
    }
  }

  /// A fix every 1-2 s even while the bus stands at a stop (distanceFilter 0): with a distance
  /// filter a standing bus produced no fixes, sending stopped, and parents lost the bus at stops.
  static LocationSettings _settings() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 2),
        );
      case TargetPlatform.iOS:
        return AppleSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
          activityType: ActivityType.automotiveNavigation,
          pauseLocationUpdatesAutomatically: false,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0);
    }
  }

  Future<void> _upload() async {
    final p = _last, fixAt = at;
    if (!_send || p == null || fixAt == null) return;
    if (_uploading || (_offUntil != null && DateTime.now().isBefore(_offUntil!))) return;
    // The phone stopped getting fixes: let the server's copy age out rather than keep repeating an
    // old position as if it were live. A standing bus still sends - parents must not lose it at a stop.
    if (DateTime.now().difference(fixAt).inSeconds > 30) return;
    _uploading = true;
    try {
      final r = await ApiService.postMonitorLocation(
          p.latitude, p.longitude, p.accuracy, p.speed < 0 ? 0 : p.speed * 3.6, p.heading);
      _offUntil = r['enabled'] == false ? DateTime.now().add(_offRetry) : null;
    } catch (_) {
      /* next time */
    } finally {
      _uploading = false;
    }
  }

  void stop() {
    _starting = false;
    _gps?.cancel();
    _gps = null;
    _sender?.cancel();
    _sender = null;
    _send = false;
    _offUntil = null;
  }
}
