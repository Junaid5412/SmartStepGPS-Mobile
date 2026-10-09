import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../services/api_service.dart';
import 'monitor_store.dart';
import 'route_planner.dart';

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

  /// The latest phone position - filtered and smoothed (see [_onFix]) - or null.
  final ValueNotifier<LatLng?> position = ValueNotifier(null);
  DateTime? at;
  Position? _last; // the latest accepted raw fix (speed, heading, accuracy)
  final _smooth = _Smoother();
  DateTime? _jumpSince; // fixes refused as impossible jumps since then

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
      _gps = Geolocator.getPositionStream(locationSettings: _settings()).listen(_onFix, onError: (Object e) => debugPrint('Phone location: $e'));
    } catch (e) {
      debugPrint('Phone location unavailable: $e');
    } finally {
      _starting = false;
    }
  }

  /// Older phones report positions that jump about, arrive late, or come from the network instead
  /// of GPS. Before a fix moves the bus it has to pass every check - and then it is blended with
  /// the previous ones by how accurate each is (a Kalman filter, as navigation apps do):
  ///   - not from a mock-location app;
  ///   - recent (some phones replay an old cached fix when GPS restarts);
  ///   - accurate enough: rough network fixes are ignored while good GPS fixes are coming in;
  ///   - physically possible: no jump faster than 160 km/h;
  ///   - standing still: tiny movements inside the accuracy circle do not move the bus.
  void _onFix(Position p) {
    if (p.isMocked) return;
    final now = DateTime.now();
    if (now.difference(p.timestamp).inSeconds.abs() > 20) return;
    final acc = p.accuracy > 0 ? p.accuracy : 50.0;
    if (acc > 150) return;
    final recentGood = at != null && now.difference(at!).inSeconds < 20 && (_last?.accuracy ?? 999) <= 40;
    if (acc > 60 && recentGood) return;
    final cur = position.value;
    if (cur != null && at != null) {
      final d = RoutePlanner.meters(cur, LatLng(p.latitude, p.longitude));
      final dt = now.difference(at!).inMilliseconds / 1000.0;
      if (d > 40 && d / (dt < 1 ? 1 : dt) > 45) {
        // > 160 km/h: a glitch, not the bus. But if every fix for 10 s says so, the earlier
        // position was the wrong one (a rough first fix): start again from here.
        _jumpSince ??= now;
        if (now.difference(_jumpSince!).inSeconds < 10) return;
        _smooth.reset();
      }
    }
    _jumpSince = null;
    final out = _smooth.add(p.latitude, p.longitude, acc, p.speed < 0 ? 0 : p.speed, now);
    _last = p;
    at = now;
    // Standing still: hold the bus where it is rather than let it drift around the stop.
    if (cur != null && p.speed >= 0 && p.speed < 0.8 && RoutePlanner.meters(cur, out) < acc * 0.6) return;
    position.value = out;
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
      final pos = position.value ?? LatLng(p.latitude, p.longitude); // the smoothed position
      final r = await ApiService.postMonitorLocation(
          pos.latitude, pos.longitude, p.accuracy, p.speed < 0 ? 0 : p.speed * 3.6, p.heading);
      _offUntil = r['enabled'] == false ? DateTime.now().add(_offRetry) : null;
    } catch (_) {
      /* next time */
    } finally {
      _uploading = false;
    }
  }

  void stop() {
    _smooth.reset();
    _starting = false;
    _gps?.cancel();
    _gps = null;
    _sender?.cancel();
    _sender = null;
    _send = false;
    _offUntil = null;
  }
}

/// Blends successive fixes by their accuracy - a one-state Kalman filter per axis, in metres. A
/// fix with a 5 m accuracy pulls hard; one with 60 m barely moves the estimate. The uncertainty
/// grows with time at the speed the bus could have moved, so a moving bus is followed promptly.
class _Smoother {
  double? _lat, _lng;
  double _var = -1; // metres squared; < 0 = no estimate yet
  DateTime? _t;

  LatLng add(double lat, double lng, double acc, double speed, DateTime now) {
    if (_var < 0 || _lat == null || _t == null || now.difference(_t!).inSeconds > 30) {
      _lat = lat;
      _lng = lng;
      _var = acc * acc;
    } else {
      final dt = now.difference(_t!).inMilliseconds / 1000.0;
      final q = speed > 3 ? speed : 3.0; // metres per second the bus may have moved
      if (dt > 0) _var += dt * q * q;
      final k = _var / (_var + acc * acc);
      _lat = _lat! + k * (lat - _lat!);
      _lng = _lng! + k * (lng - _lng!);
      _var = (1 - k) * _var;
    }
    _t = now;
    return LatLng(_lat!, _lng!);
  }

  void reset() {
    _var = -1;
    _lat = _lng = null;
    _t = null;
  }
}
