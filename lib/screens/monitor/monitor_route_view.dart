import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_service.dart';
import '../../services/map_config.dart';
import '../../services/module_watcher.dart';
import '../../widgets/bus_map_common.dart';
import '../../widgets/google_bus_map.dart';
import '../../widgets/libre_bus_map.dart';
import 'monitor_actions.dart';
import 'monitor_shift_view.dart';
import 'monitor_store.dart';
import 'monitor_widgets.dart';
import 'phone_location.dart';
import 'route_planner.dart';
import '../../services/app_errors.dart';

/// The Shift tab - the ONE place attendance is marked. While a shift is open it shows the stops in
/// the best order, either on a live MAP or as a LIST (a switch at the top, remembered per phone);
/// both use the same stops, order and buttons. When no shift is open it shows the countdown.
///
/// WHERE THE BUS IS: the bus's own GPS tracker is the truth - it is in the bus. It is asked as often
/// as the server says (every 3 s while driving), and its position counts while it is reporting: a
/// fix from the last minute, or - the bus standing at a stop or parked - whatever the server says
/// is still a live tracker (a standing tracker only sends every few minutes, and it has not moved).
/// The monitor's phone is always shown as a small blue dot ("you"). It stands in for the bus ONLY when
/// the school has the Monitor Phone Backup switched on for this bus AND the tracker has lost its GPS
/// or signal; switched off, the bus stays at the tracker's last position, marked "no signal".
///
/// - The order: the shortest one-way drive from where the bus is (RoutePlanner) - near stops first,
///   far ones last; the school first in the evening and last in the morning. Re-worked at once when
///   a child is picked up or dropped (an instant estimate, then the road plan), when the bus leaves
///   the planned road, and every few minutes.
/// - The bus moves ALONG the planned road between fixes, and the part already driven disappears.
/// - Every stop shows when the bus should reach it ("Reach 7:45 AM").
/// - Stops whose children are all on leave for this trip are greyed out and left off the route.
/// - Arriving within [_arriveM] of any stop opens it, whatever the plan said.
/// - The bus arrow glides between fixes at the screen's refresh rate; only that layer redraws.
/// - Location is followed only while this tab is showing and a shift is open.
class MonitorRouteView extends StatefulWidget {
  final MonitorStore store;
  final bool active;
  final String? shiftKey; // for the closed-shift view's Morning / Evening switch
  final ValueChanged<String> onSwitchShift;
  const MonitorRouteView({
    super.key,
    required this.store,
    required this.active,
    required this.shiftKey,
    required this.onSwitchShift,
  });

  @override
  State<MonitorRouteView> createState() => _MonitorRouteViewState();
}

enum _St { todo, done, leave }

class _Stop {
  final String key;
  final String title;
  final String subtitle;
  final LatLng? point;
  final FamilyGroup? family;
  final List<dynamic> kids;
  final _St state;
  final bool school;
  _Stop(this.key, this.title, this.subtitle, this.point, this.family, this.kids, this.state, {this.school = false});
}

class _Fix {
  final LatLng pos;
  final double heading;
  const _Fix(this.pos, this.heading);
}

class _MonitorRouteViewState extends State<MonitorRouteView> with SingleTickerProviderStateMixin {
  static const _arriveM = 70.0;
  static const _trackerFreshSec = 60; // older than this, the tracker has lost signal
  static const _phoneFreshSec = 30;
  static const _dwellSec = 40; // time spent at each stop, for the arrival times
  static const _doha = LatLng(25.2854, 51.5310);
  static const _prefMode = 'monitor_shift_view';

  final _map = MapController();
  bool _cardOpen = false; // the map's stop card: small, or opened upwards
  static const Widget _baseMap = BaseMapLayer(); // follows the portal's map choice by itself

  /// The official Google map's camera, while that map is on screen; and the bus position it follows.
  BusMapCam? _gcam;
  final ValueNotifier<LatLng?> _shownPos = ValueNotifier(null);
  bool get _googleOn => MapConfig.instance.value.isNative;   // official Google map or OpenFreeMap
  String _mapKind = '';

  void _camFollow(LatLng p) {
    try {
      if (_googleOn) {
        _gcam?.follow(p);
      } else {
        _map.move(p, _map.camera.zoom);
      }
    } catch (_) {}
  }

  void _camNorth() {
    try {
      if (_googleOn) {
        _gcam?.north();
      } else {
        _map.rotate(0);
      }
    } catch (_) {}
  }

  void _camMoveNorth(LatLng p, double minZoom) {
    try {
      if (_googleOn) {
        _gcam?.moveNorth(p, minZoom);
      } else {
        _map.moveAndRotate(p, math.max(_map.camera.zoom, minZoom), 0);
      }
    } catch (_) {}
  }
  bool _mapReady = false;
  bool _fitted = false;
  bool _listMode = false;
  bool _showDone = false;

  // ---- where the bus is ---------------------------------------------------------------------------
  bool _phoneOn = false;
  bool _tracking = false;
  bool _pollBusy = false; // a tracker poll is on its way
  Timer? _trackerPoll; // the next tracker poll (rescheduled after each answer, at the server's pace)
  LatLng? _busPos; // the tracker
  DateTime? _busAt; // when the server received that fix (from its age_sec - not this phone's clock)
  bool _trackerOnline = false; // the server's verdict: the tracker is reporting
  String _trackerState = ''; // moving / idle / parked / nosignal / offline
  double _trackerSpeed = 0; // km/h
  double? _trackerCourse;
  String _trackerNote = ''; // gps_weak | stale | parked ... - why the server shows no speed
  bool _phoneBackup = false; // the school allows the monitor's phone to stand in for the tracker
  LatLng? _phonePos; // the monitor's phone
  DateTime? _phoneAt;
  LatLng? _bestPrev;
  double _heading = 0;
  LatLng? _headAnchor; // where the current heading was measured from
  bool? _headFromTracker;
  final ValueNotifier<_Fix?> _shown = ValueNotifier(null); // the gliding bus arrow
  final ValueNotifier<LatLng?> _phoneDot = ValueNotifier(null);
  final ValueNotifier<double> _rotation = ValueNotifier(0); // the map's turn in degrees (0 = north up)
  late final AnimationController _glide;
  LatLng? _glideFrom, _glideTo;
  RouteLine? _glidePath; // gliding along the road the server matched between two tracker fixes (off the planned line)
  List<LatLng> _trackerPath = const []; // that road, as the last tracker poll sent it
  double? _glideAlongFrom, _glideAlongTo; // gliding ALONG the planned road (metres along it), when on it
  double? _targetAlong; // where on the road the glide ends
  double? _shownAlong; // where on the road the bus is drawn now (null: off the road)
  DateTime _lastTrim = DateTime.now();
  double _headFrom = 0, _headTo = 0;
  DateTime _lastTarget = DateTime.now();
  bool _follow = true;

  // ---- the route ----------------------------------------------------------------------------------
  RoutePlan? _plan;
  List<String> _planKeys = [];
  final Map<String, double> _legSec = {}; // road time to each stop from the one before it
  double _leadStraight = 0; // straight-line metres from the bus to the next stop when planned
  List<LatLng>? _lineNow; // the planned line, with the part already driven cut off
  RouteLine? _route; // the planned line, measured: the bus is put on it and followed along it
  double? _along; // how far along it the bus last was
  DateTime? _offSince; // the bus has been off the planned road since then
  String _planSig = '';
  DateTime _planAt = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _planFrom;
  bool _planning = false;
  bool _planAgain = false; // something changed while a plan was being worked out
  int _planGen = 0; // a newer plan makes a slower, older answer worthless
  String? _activeKey; // the stop she is at, or chose
  final Set<String> _skipped = {};
  String? _planShift; // the shift the skips and the chosen stop belong to
  String? _banner;
  Timer? _bannerTimer;
  Timer? _clock; // arrival times move with the clock

  MonitorStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    AppErrors.screen = 'monitor_route';
    _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 950))..addListener(_onGlide);
    // Which map to draw (App Module Settings on the portal).
    MapConfig.instance.addListener(_onMapSource);
    MapConfig.instance.refresh();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _listMode = p.getString(_prefMode) == 'list');
    });
    store.addListener(_onStore);
    ModuleWatcher.instance.addListener(_onModules);
    _syncTracking();
  }

  void _onModules() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(MonitorRouteView old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) {
      // The native map exists only while this tab is on screen (see _mapView): leaving the tab removes it, so
      // its camera and "ready" state go with it and a fresh map is fitted again when the monitor comes back.
      if (!widget.active && _googleOn) {
        _gcam = null;
        _mapReady = false;
        _fitted = false;
      }
      _syncTracking();
    }
  }

  @override
  void dispose() {
    ModuleWatcher.instance.removeListener(_onModules);
    MapConfig.instance.removeListener(_onMapSource);
    store.removeListener(_onStore);
    _stopTracking();
    _glide.dispose();
    _shown.dispose();
    _phoneDot.dispose();
    _shownPos.dispose();
    _rotation.dispose();
    _bannerTimer?.cancel();
    super.dispose();
  }

  /// The portal switched the map: the zoom limit and the credit line follow it.
  void _onMapSource() {
    if (!mounted) return;
    final s = MapConfig.instance.value;
    final kind = s.isGoogleSdk ? 'google' : s.isLibre ? 'libre' : 'tiles';
    final changedKind = _mapKind.isNotEmpty && kind != _mapKind;
    _mapKind = kind;
    if (!changedKind) {
      setState(() {});
      return;
    }
    _gcam = null;
    _rotation.value = 0;
    setState(() {
      _mapReady = false;   // a different kind of map starts from scratch
      _fitted = false;
    });
  }

  ShiftWindow? get _shift {
    final f = store.focus;
    return (f != null && f.isOpen) ? f : null;
  }

  void _onStore() {
    _syncTracking();
    if (mounted) _maybePlan();
  }

  void _setMode(bool list) {
    setState(() => _listMode = list);
    SharedPreferences.getInstance().then((p) => p.setString(_prefMode, list ? 'list' : 'map'));
  }

  // ---------------------------------------------------------------------------------------- location

  void _syncTracking() {
    final want = widget.active && _shift != null;
    if (want && !_tracking) {
      _startTracking();
    } else if (!want && _tracking) {
      _stopTracking();
    } else if (want && store.busDeviceId > 0 && _trackerPoll == null && !_pollBusy) {
      _pollTracker(); // the bus was assigned after this page opened: start following its tracker now
    }
  }

  void _startTracking() {
    _tracking = true;
    // 1. The bus tracker - the real position of the bus - as often as the server says (3 s driving).
    if (store.busDeviceId > 0) _pollTracker();
    // 2. The monitor's phone - always shown as "you"; the bus only when the backup is allowed.
    _startPhone();
    // 3. Arrival times count down with the clock.
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  // The phone's position comes from the dashboard-wide PhoneLocation (which also sends it to the
  // server as the bus's backup position), so the GPS is started once, not once per screen.
  void _startPhone() {
    if (_phoneOn) return;
    _phoneOn = true;
    PhoneLocation.instance.position.addListener(_onPhone);
    if (PhoneLocation.instance.position.value != null) _onPhone();
  }

  void _onPhone() {
    final p = PhoneLocation.instance.position.value;
    if (p == null || !mounted) return;
    _phonePos = p;
    _phoneAt = PhoneLocation.instance.at ?? DateTime.now();
    _phoneDot.value = p;
    _onAnyFix();
  }

  /// A number from the server's JSON, whether it arrives as a number or as text.
  static double? _numOf(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

  /// One tracker poll; the next is scheduled when this one has answered, at the pace the server asks
  /// for (3 s moving, 5 s standing, up to 10 s parked), so a slow answer never piles polls up.
  Future<void> _pollTracker() async {
    _trackerPoll?.cancel();
    _trackerPoll = null;
    _pollBusy = true;
    var next = 5;
    try {
      final r = await ApiService.getBusLocation(store.busDeviceId, lite: true).timeout(const Duration(seconds: 10));
      if (!_tracking || !mounted) return;
      final ps = r['poll_sec'];
      if (ps is num) next = ps.toInt().clamp(2, 10);
      if (r['phone_backup'] is bool) _phoneBackup = r['phone_backup'] as bool;
      final bs = r['bus_status'];
      if (bs is Map) {
        _trackerState = '${bs['state'] ?? ''}';
        _trackerOnline = bs['online'] == true;
      }
      // The tracker's OWN fix. (The server's "location" can be this very phone's backup position for parents.)
      Map? loc = r['tracker_location'] is Map ? r['tracker_location'] as Map : null;
      if (loc == null) {
        final l = r['location'] ?? r['last_known_location'];
        if (l is Map && l['source'] != 'monitor') loc = l;
      }
      // A placeholder is not a fix: a bus that has never reported is put at the school by the server. Taken as a
      // live tracker it planned the route from the school and kept the phone backup from taking over.
      if (loc != null && (loc['source'] == 'placeholder' || _numOf(loc['age_sec']) == null)) loc = null;
      final lat = _numOf(loc?['lat']), lng = _numOf(loc?['lng']);
      if (loc == null || lat == null || lng == null) {
        setState(() {});
        return;
      }
      final p = LatLng(lat, lng);
      // How old the fix is by the SERVER's clock (age_sec) - a phone set to another time zone or a
      // tracker with a wrong clock no longer makes a live tracker look stale.
      final age = _numOf(loc['age_sec']);
      final at = age != null
          ? DateTime.now().subtract(Duration(seconds: age.abs().round()))
          : (DateTime.tryParse('${loc['updated_at'] ?? ''}'.replaceFirst(' ', 'T')) ?? DateTime.now());
      _trackerSpeed = _numOf(loc['speed']) ?? 0;
      _trackerCourse = _numOf(loc['course']);
      _trackerNote = '${loc['speed_note'] ?? ''}';
      final isNew = _busPos == null || RoutePlanner.meters(_busPos!, p) >= 1;
      // The road from the tracker's last fix to this one (server road matching), for the glide.
      if (isNew) {
        final pp = loc['path'];
        _trackerPath = [
          if (pp is List)
            for (final q in pp)
              if (q is List && q.length >= 2) LatLng(_numOf(q[0]) ?? 0, _numOf(q[1]) ?? 0),
        ];
      }
      _busPos = p;
      _busAt = at;
      if (isNew) {
        _onAnyFix();
      } else {
        setState(() {}); // same place: only the label (live / no signal) may change
      }
    } catch (_) {
      /* next poll */
    } finally {
      _pollBusy = false;
      if (_tracking && mounted && store.busDeviceId > 0) {
        _trackerPoll = Timer(Duration(seconds: next), _pollTracker);
      }
    }
  }

  void _stopTracking() {
    _tracking = false;
    if (_phoneOn) PhoneLocation.instance.position.removeListener(_onPhone);
    _phoneOn = false;
    _trackerPoll?.cancel();
    _trackerPoll = null;
    _clock?.cancel();
    _clock = null;
  }

  int get _trackerAge => _busAt == null ? 1 << 30 : DateTime.now().difference(_busAt!).inSeconds.abs();

  /// The tracker's position can be used for the bus: a fix from the last minute - or the server says
  /// the tracker is reporting and the bus is standing (parked or idling). A standing tracker sends
  /// only every few minutes, but the bus has not moved, so its position is right.
  bool get _trackerFresh =>
      _busPos != null &&
      (_trackerAge <= _trackerFreshSec ||
          (_trackerOnline && (_trackerState == 'parked' || _trackerState == 'idle') && _trackerAge <= 900));

  /// The phone is reporting. Its own last-fix time: standing at a stop the phone keeps sending fixes but holds
  /// the bus still (no new position), and judging by the last MOVE made the backup lapse after 30 s at a stop.
  bool get _phoneFresh {
    final at = _phoneOn ? (PhoneLocation.instance.at ?? _phoneAt) : _phoneAt;
    return at != null && DateTime.now().difference(at).inSeconds <= _phoneFreshSec;
  }

  /// The phone may stand in for the bus: the school switched the Monitor Phone Backup on - or the bus has
  /// no tracker at all.
  bool get _phoneAllowed => _phoneBackup || store.busDeviceId <= 0;

  /// The bus position to use: the tracker while it is reporting; the phone only when the backup is
  /// allowed; else the tracker's last position (shown as "no signal"). The phone is used with the backup
  /// off only when the tracker has never given a position at all - otherwise the page would be empty.
  LatLng? get _best {
    if (_trackerFresh) return _busPos;
    if (_phoneAllowed && _phoneFresh) return _phonePos;
    return _busPos ?? _phonePos;
  }

  bool get _usingPhone => !_trackerFresh && _phonePos != null && _best == _phonePos && _busPos != _phonePos;

  String get _sourceLabel {
    if (_trackerFresh) {
      if (_trackerNote == 'gps_weak') return 'Bus tracker · weak GPS, last good position';
      if (_trackerAge <= _trackerFreshSec) return 'Bus tracker · live';
      return _trackerState == 'parked' ? 'Bus tracker · parked' : 'Bus tracker · standing';
    }
    if (_usingPhone) return _busPos == null ? 'Your phone GPS · tracker not reporting yet' : 'Your phone GPS · tracker no signal';
    if (_busPos != null) return 'Tracker no signal · last ${_busAt == null ? '' : DateFormat('h:mm a').format(_busAt!)}';
    return 'Finding the bus…';
  }

  Widget _srcIcon() => Icon(
        _usingPhone ? Icons.smartphone_rounded : Icons.directions_bus_rounded,
        size: 15,
        color: _trackerFresh ? MonitorColors.green : MonitorColors.amber,
      );

  static const _onRouteM = 45.0; // closer than this to the planned road, the bus is drawn ON it

  void _onAnyFix() {
    if (!mounted) return;
    final p = _best;
    if (p == null) return;
    final prev = _bestPrev;
    if (prev != null && RoutePlanner.meters(prev, p) < 1) return; // nothing moved
    _bestPrev = p;
    final src = _trackerFresh;

    // Where on the planned road the bus is.
    final route = _route;
    final spot = route?.locate(p, near: _along);
    final hit = (spot != null && spot.off <= _onRouteM) ? spot : null; // on the road

    // Direction of travel: along the road when on it; else the tracker's own course while driving;
    // else measured over a real move (15 m - GPS wanders a few metres when standing), starting again
    // whenever the position switches between tracker and phone.
    if (hit != null) {
      _heading = route!.headingAt(hit.along);
      _headAnchor = p;
      _headFromTracker = src;
    } else if (src && _trackerSpeed >= 5 && _trackerCourse != null) {
      _heading = _trackerCourse!;
      _headAnchor = p;
      _headFromTracker = src;
    } else if (_headAnchor == null || _headFromTracker != src) {
      _headAnchor = p;
      _headFromTracker = src;
    } else if (RoutePlanner.meters(_headAnchor!, p) > 15) {
      _heading = RoutePlanner.bearing(_headAnchor!, p);
      _headAnchor = p;
    }

    // Glide over the time since the last new position: the tracker sends about every 10 s while
    // driving, so the bus keeps moving between its fixes instead of jumping and waiting (phone ~1 s).
    final gap = DateTime.now().difference(_lastTarget).inMilliseconds.clamp(800, 11000);
    _lastTarget = DateTime.now();
    final cur = _shown.value;
    final fromAlong = _shownAlong;
    if (hit != null && fromAlong != null && hit.along >= fromAlong - 30 && hit.along - fromAlong < 1500) {
      _glideAlongFrom = fromAlong; // along the road, round its bends
      _glideAlongTo = hit.along;
    } else {
      _glideAlongFrom = _glideAlongTo = null; // straight (just joined the road, or off it)
    }
    _targetAlong = hit?.along;
    _glideFrom = cur?.pos ?? hit?.point ?? p;
    _glideTo = hit?.point ?? p;
    // Not along the planned line: along the road the server matched from the last tracker fix, when it fits.
    _glidePath = null;
    final tp = _trackerPath;
    final gFrom = _glideFrom, gTo = _glideTo;
    if (_glideAlongFrom == null && src && tp.length >= 2 && gFrom != null && gTo != null
        && RoutePlanner.meters(tp.last, gTo) <= 20 && RoutePlanner.meters(gFrom, tp.first) <= 60) {
      _glidePath = RouteLine([gFrom, ...tp.sublist(0, tp.length - 1), gTo]);
    }
    _headFrom = cur?.heading ?? _heading;
    _headTo = _heading;
    _glide.duration = Duration(milliseconds: gap);
    _glide.forward(from: 0);

    // The line still to drive. Off the road: a link from the bus to the road, and - after a few seconds -
    // a new plan from where the bus really is (see _maybePlan).
    if (route != null && spot != null) {
      if (hit != null) {
        _along = hit.along;
        _offSince = null;
        _lineNow = route.from(fromAlong ?? hit.along);
      } else {
        _offSince ??= DateTime.now();
        _lineNow = [p, ...route.from(spot.along)];
      }
    }
    setState(() {});

    _checkArrival(p);
    _maybePlan();
  }

  void _onGlide() {
    final a = _glideFrom, b = _glideTo;
    if (a == null || b == null) return;
    final t = _glide.value; // even speed: the bus does not stop and start between fixes
    final route = _route;
    final af = _glideAlongFrom, at = _glideAlongTo;
    LatLng pos;
    double head;
    if (route != null && af != null && at != null) {
      final d = af + (at - af) * t;
      pos = route.at(d);
      head = at - af > 3 ? route.headingAt(d) : _headTo;
      _shownAlong = d;
      // Trim the driven part behind the bus about once a second, like navigation apps.
      if (DateTime.now().difference(_lastTrim).inMilliseconds > 1000) {
        _lastTrim = DateTime.now();
        setState(() => _lineNow = route.from(d));
      }
    } else if (_glidePath != null && _glidePath!.length > 0) {
      final gp = _glidePath!;
      final d = gp.length * t;
      pos = gp.at(d);
      head = gp.headingAt(d);
      _shownAlong = t >= 1 ? _targetAlong : null;
    } else {
      pos = LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
      var dh = (_headTo - _headFrom) % 360;
      if (dh > 180) dh -= 360;
      head = (_headFrom + dh * t) % 360;
      _shownAlong = t >= 1 ? _targetAlong : null;
    }
    _shown.value = _Fix(pos, head);
    _shownPos.value = pos;
    if (_follow && _mapReady && !_listMode) _camFollow(pos);
  }

  // ---------------------------------------------------------------------------------------- stops

  bool _hasNotice(dynamic s, String shift) => store.noticeFor(s, shift) != null;

  List<_Stop> _stops(ShiftWindow w) {
    final shift = w.key;
    final morning = w.isMorning;
    final out = <_Stop>[];
    final sp = store.schoolLat != null && store.schoolLng != null ? LatLng(store.schoolLat!, store.schoolLng!) : null;

    // Evening: children still at school board there first.
    if (!morning) {
      final atSchool = store.students.where((s) => store.stageOf(s, shift) == Stage.waiting).toList();
      final needs = atSchool.where((s) => !_hasNotice(s, shift)).toList();
      out.add(_Stop('school', store.schoolName, needs.isEmpty ? 'Everyone has boarded' : '${needs.length} to board here',
          sp, null, atSchool, needs.isEmpty ? _St.done : _St.todo, school: true));
    }

    for (final f in store.families(shift)) {
      final waiting = f.students.where((s) => store.stageOf(s, shift) == Stage.waiting).toList();
      final onBus = f.students.where((s) => store.stageOf(s, shift) == Stage.onBus).toList();
      // Every child here is on leave for this trip and nobody has been marked: not a stop at all.
      final allLeave = f.students.every((s) => _hasNotice(s, shift) && store.stageOf(s, shift) == Stage.waiting);
      final _St st;
      if (morning) {
        final need = waiting.where((s) => !_hasNotice(s, shift)).length;
        st = need > 0 ? _St.todo : (allLeave ? _St.leave : _St.done);
      } else {
        // Still to do: a child on the bus for this home, or one still to board at school (not on leave).
        // Before, a home counted as done until its child boarded: "12 of 12 done" at the start of the trip.
        final toBoard = waiting.where((s) => !_hasNotice(s, shift)).length;
        st = (onBus.isNotEmpty || toBoard > 0) ? _St.todo : (allLeave ? _St.leave : _St.done);
      }
      final pt = f.hasCoords ? LatLng(double.parse('${f.stopLat}'), double.parse('${f.stopLng}')) : null;
      out.add(_Stop(f.key, f.parentName, f.address, pt, f, f.students, st));
    }

    // Morning: everyone gets off at school, last.
    if (morning) {
      final onBus = store.students.where((s) => store.stageOf(s, shift) == Stage.onBus).toList();
      final homesLeft = out.any((s) => s.state == _St.todo);
      out.add(_Stop('school', store.schoolName,
          onBus.isEmpty ? (homesLeft ? 'Everyone gets off here' : 'Everyone is at school') : '${onBus.length} on the bus',
          sp, null, onBus, (onBus.isEmpty && !homesLeft) ? _St.done : _St.todo, school: true));
    }
    return out;
  }

  /// The nearest unfinished stop to where the bus is (the school only once it is the stop to make).
  _Stop? _nearest(List<_Stop> stops, ShiftWindow w) {
    final at = _best;
    final todo = stops.where((s) => s.state == _St.todo && !_skipped.contains(s.key)).toList();
    if (todo.isEmpty) return null;
    // Evening: boarding at school comes first; morning: school comes last.
    if (!w.isMorning) {
      final school = todo.where((s) => s.school).firstOrNull;
      if (school != null) return school;
    }
    final homes = todo.where((s) => !s.school).toList();
    final pool = homes.isNotEmpty ? homes : todo;
    if (at == null) return pool.first;
    final located = pool.where((s) => s.point != null).toList();
    if (located.isEmpty) return pool.first;
    located.sort((a, b) => RoutePlanner.meters(at, a.point!).compareTo(RoutePlanner.meters(at, b.point!)));
    return located.first;
  }

  /// The stop to deal with now: the one she is at or chose; else (evening) boarding at school; else the
  /// first stop of the plan - the shortest drive from the bus - still to do; else the nearest.
  /// The moment a child there is picked up or dropped, that stop is no longer "to do" and this moves on.
  _Stop? _next(List<_Stop> stops, ShiftWindow w) {
    final todo = {for (final s in stops) if (s.state == _St.todo) s.key: s};
    if (_activeKey != null && todo.containsKey(_activeKey)) return todo[_activeKey];
    if (!w.isMorning) {
      final school = todo.values.where((s) => s.school).firstOrNull;
      if (school != null) return school;
    }
    for (final k in _planKeys) {
      final s = todo[k];
      if (s == null || _skipped.contains(k)) continue;
      // Morning: the school only once no home is left.
      if (s.school && w.isMorning && todo.values.any((o) => !o.school && !_skipped.contains(o.key))) continue;
      return s;
    }
    return _nearest(stops, w) ?? (todo.isEmpty ? null : todo.values.first);
  }

  void _checkArrival(LatLng p) {
    final w = _shift;
    if (w == null) return;
    final all = _stops(w);
    final homesLeft = all.any((s) => !s.school && s.state == _St.todo);
    final schoolLeft = all.any((s) => s.school && s.state == _St.todo);
    final stops = all.where((s) {
      if (s.state != _St.todo || s.point == null) return false;
      // Morning: driving past the school with homes still to visit is not arriving there.
      if (w.isMorning && s.school && homesLeft) return false;
      // Evening: the homes come only after boarding at school.
      if (!w.isMorning && !s.school && schoolLeft) return false;
      return true;
    }).toList();
    _Stop? hit;
    var best = _arriveM;
    for (final s in stops) {
      final d = RoutePlanner.meters(p, s.point!);
      if (d < best) {
        best = d;
        hit = s;
      }
    }
    if (hit == null || hit.key == _activeKey) return;
    setState(() => _activeKey = hit!.key);
    _say('Arrived at ${hit.title}.');
    _planSig = '';
    if (!_listMode) setState(() => _cardOpen = true); // at the stop: its children, ready to mark
  }

  void _say(String text) {
    _bannerTimer?.cancel();
    setState(() => _banner = text);
    _bannerTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _banner = null);
    });
  }

  // ---------------------------------------------------------------------------------------- planning

  /// Works out (again) the order of the stops still to do and the road line through them.
  ///
  /// When: the stops change (a child picked up or dropped, a stop chosen or skipped) - AT ONCE, first
  /// with an instant on-phone estimate so the next stop and the order move on the moment she marks,
  /// then with the road plan a second or two later; when the bus has left the planned road for 8 s
  /// (a different road taken); after a big jump; and every 3 minutes while driving. Never more than
  /// every 15 s for the last three, to stay gentle with the free routing service.
  Future<void> _maybePlan() async {
    final w = _shift;
    if (w == null) return;
    // Only from where the bus really is. Starting from the school while the first position was
    // still on its way (just after opening the app) drew school -> next stop -> school: two roads
    // between the next stop and the school, and no line from the bus at all.
    final start = _best;
    if (start == null) return;
    // A new shift starts clean: a family skipped, or a stop chosen, in the morning means nothing in the evening.
    if (_planShift != w.key) {
      if (_planShift != null) {
        _skipped.clear();
        _activeKey = null;
      }
      _planShift = w.key;
    }
    final stops = _stops(w);
    final todo = stops.where((s) => s.state == _St.todo && s.point != null).toList();
    final sig = '${w.key}|${todo.map((s) => s.key).join(',')}|$_activeKey|${_skipped.join(',')}';
    final moved = _planFrom == null ? 1e9 : RoutePlanner.meters(_planFrom!, start);
    final age = DateTime.now().difference(_planAt);
    final changed = sig != _planSig;
    // Off the road only counts against a ROAD line: a straight-line estimate (routing service down) is never
    // driven exactly, and re-planned it every 15 s. That estimate is retried for the road line once a minute.
    final roadLine = _plan?.road ?? false;
    final offRoad = roadLine && _offSince != null && DateTime.now().difference(_offSince!) > const Duration(seconds: 8);
    final retryRoad = _plan != null && !roadLine && age > const Duration(seconds: 60);
    // Driving along the planned road is what it is for: only a big move OFF it, or an old plan, re-plans.
    final drifting = (moved > 800 && _offSince != null) || (age > const Duration(minutes: 3) && moved > 300);
    if (!changed && !offRoad && !drifting && !retryRoad) return;
    if (_planning && !changed) { // a change of stops does not wait: it starts over, and the older answer is dropped
      _planAgain = true;
      return;
    }
    if (!changed && age < const Duration(seconds: 15)) return;

    // First: the stop she is at or chose; in the evening, boarding at school. Last: the school in the
    // morning. In between: the shortest one-way drive (near first), skipped stops after the others.
    final active = _activeKey == null ? null : todo.where((s) => s.key == _activeKey).firstOrNull;
    final schoolStop = todo.where((s) => s.school).firstOrNull;
    final lead = <_Stop>[
      if (!w.isMorning && schoolStop != null) schoolStop,
      if (active != null && active != schoolStop) active,
      // Morning, the school chosen with homes still left: it is next, so the line goes there first.
      if (w.isMorning && active != null && active == schoolStop) active,
    ];
    final end = (w.isMorning && schoolStop != null && !lead.contains(schoolStop)) ? schoolStop : null;
    final rest = todo.where((s) => !lead.contains(s) && s != end && !_skipped.contains(s.key)).toList();
    final skipped = todo.where((s) => !lead.contains(s) && s != end && _skipped.contains(s.key)).toList();
    final from = lead.isNotEmpty ? lead.last.point! : start;
    final gen = ++_planGen;
    _planning = true;
    try {
      List<String> keysOf(RoutePlan p) =>
          [...lead.map((s) => s.key), for (final i in p.order) rest[i].key, ...skipped.map((s) => s.key), if (end != null) end.key];

      // 1. Instant: straight lines, no network - the next stop and the order change right now.
      if (changed) {
        final quick = await RoutePlanner.plan(from, [for (final s in rest) s.point!], end: end?.point, road: false);
        if (!mounted || gen != _planGen) return;
        final keys = keysOf(quick);
        final byKey = {for (final s in todo) s.key: s};
        // A road line already on screen stays until the new road line arrives (instead of straight lines for a
        // few seconds after every mark): only the order, the next stop and the times change now.
        _apply(quick, [start, for (final k in keys) byKey[k]!.point!], false, keys, rest, end, sig, start, orderOnly: _plan?.road ?? false);
        // Several children marked one after another: one road request for the last, not one for each.
        await Future.delayed(const Duration(milliseconds: 700));
        if (!mounted || gen != _planGen) return;
      }

      // 2. The road plan: real driving times for the order, and the line along the roads - from the bus
      //    to the next stop, and on through the rest.
      final plan = await RoutePlanner.plan(from, [for (final s in rest) s.point!], end: end?.point);
      if (!mounted || gen != _planGen) return;
      final keys = keysOf(plan);
      final byKey = {for (final s in todo) s.key: s};
      final ordered = [for (final k in keys) byKey[k]!.point!];
      final full = await RoutePlanner.roadPath([start, ...ordered]);
      if (!mounted || gen != _planGen) return;
      if (full != null) {
        _legSec.clear();
        for (var i = 0; i < keys.length && i < full.legSeconds.length; i++) {
          _legSec[keys[i]] = full.legSeconds[i];
        }
        _apply(plan, full.line, true, keys, rest, end, sig, start, legsDone: true);
      } else {
        _apply(plan, [start, ...ordered], false, keys, rest, end, sig, start);
      }
    } finally {
      if (gen == _planGen) _planning = false;
      if (_planAgain && mounted) {
        _planAgain = false;
        Future.microtask(_maybePlan);
      }
    }
  }

  /// Puts a plan on screen: the order, the times, the line - and the bus onto the new line.
  void _apply(RoutePlan plan, List<LatLng> line, bool road, List<String> keys, List<_Stop> rest, _Stop? end,
      String sig, LatLng start, {bool legsDone = false, bool orderOnly = false}) {
    if (!legsDone) {
      _legSec.clear();
      for (var i = 0; i < plan.order.length && i < plan.legSeconds.length; i++) {
        _legSec[rest[plan.order[i]].key] = plan.legSeconds[i];
      }
      if (end != null && plan.legSeconds.length > plan.order.length) _legSec[end.key] = plan.legSeconds[plan.order.length];
    }
    if (orderOnly) {
      setState(() {
        _planKeys = keys;
        _planSig = sig;
        final p0 = _firstStopPoint(keys);
        _leadStraight = p0 == null ? 0 : RoutePlanner.meters(start, p0);
      });
      return;
    }
    final route = RouteLine(line);
    // A glide along the OLD line cannot go on along the new one: finish it in a straight line.
    final shownNow = _shown.value?.pos;
    if (_glideAlongFrom != null && shownNow != null && _glide.isAnimating) {
      final left = (_glide.duration ?? const Duration(seconds: 1)) * (1 - _glide.value);
      _glideAlongFrom = _glideAlongTo = null;
      _glideFrom = shownNow;
      _glide.duration = left < const Duration(milliseconds: 300) ? const Duration(milliseconds: 300) : left;
      _glide.forward(from: 0);
    }
    // Where the bus is NOW: the road plan took a few seconds, and the position it was asked from is behind
    // the bus - placing it there made the arrow jump back at the end of the glide.
    final nowPos = _glideTo ?? _best ?? start;
    final here = route.locate(shownNow ?? nowPos);
    final at = route.locate(nowPos);
    setState(() {
      _plan = RoutePlan(plan.order, line, plan.legMeters, plan.legSeconds, road);
      _route = route;
      _shownAlong = (here != null && here.off <= _onRouteM) ? here.along : null;
      _targetAlong = (at != null && at.off <= _onRouteM) ? at.along : null;
      _along = at?.along;
      _offSince = null;
      _lineNow = route.from(_shownAlong ?? at?.along ?? 0);
      _planKeys = keys;
      _planSig = sig;
      _planAt = DateTime.now();
      _planFrom = start;
      final p0 = _firstStopPoint(keys);
      _leadStraight = p0 == null ? 0 : RoutePlanner.meters(start, p0);
    });
  }

  LatLng? _firstStopPoint(List<String> keys) {
    final w = _shift;
    if (w == null || keys.isEmpty) return null;
    return _stops(w).where((s) => s.key == keys.first).firstOrNull?.point;
  }

  /// Town driving speed, from the road plan when there is one.
  double get _mps {
    final p = _plan;
    if (p != null && p.road) {
      final m = p.legMeters.fold<double>(0, (a, b) => a + b), s = p.legSeconds.fold<double>(0, (a, b) => a + b);
      if (s > 0) return (m / s).clamp(4.0, 20.0);
    }
    return 28 / 3.6;
  }

  /// When the bus should reach each stop still to do, in Qatar time (this phone's clock).
  Map<String, DateTime> _etas(List<_Stop> stops) {
    final out = <String, DateTime>{};
    final at = _best;
    if (at == null) return out;
    final byKey = {for (final s in stops) if (s.state == _St.todo && s.point != null) s.key: s};
    var t = DateTime.now();
    LatLng prev = at;
    var first = true;
    for (final k in _planKeys) {
      final s = byKey[k];
      if (s == null) continue;
      final straight = RoutePlanner.meters(prev, s.point!);
      final double secs;
      if (first && _legSec[k] != null && _leadStraight > 50) {
        // The road time to the next stop when planned, shrinking as the bus closes in.
        secs = _legSec[k]! * (straight / _leadStraight).clamp(0.0, 1.5);
      } else if (!first && _legSec[k] != null) {
        secs = _legSec[k]!;
      } else {
        secs = straight * 1.3 / _mps;
      }
      t = t.add(Duration(seconds: secs.round()));
      out[k] = t;
      t = t.add(const Duration(seconds: _dwellSec));
      prev = s.point!;
      first = false;
    }
    return out;
  }

  String _away(_Stop s) {
    if (s.point == null) return 'No location saved';
    final p = _best;
    if (p == null) return '';
    final m = RoutePlanner.meters(p, s.point!);
    if (m < _arriveM) return 'You are here';
    final road = m * 1.3;
    return road < 1000 ? '${(road / 10).round() * 10} m' : '${(road / 1000).toStringAsFixed(1)} km';
  }

  String _reach(Map<String, DateTime> etas, _Stop s) {
    final t = etas[s.key];
    if (t == null) return '';
    if (s.point != null && _best != null && RoutePlanner.meters(_best!, s.point!) < _arriveM) return 'Here now';
    return 'Reach ${DateFormat('h:mm a').format(t)}';
  }

  // ---------------------------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final w = _shift;
    if (w == null) {
      final key = widget.shiftKey ?? store.focus?.key;
      if (key == null || store.window(key) == null) return const Center(child: CircularProgressIndicator());
      return MonitorShiftView(store: store, shiftKey: key, onSwitchShift: widget.onSwitchShift);
    }
    final stops = _stops(w);
    final next = _next(stops, w);
    if (_planSig.isEmpty || (next != null && !_planKeys.contains(next.key))) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybePlan());
    }
    final etas = _etas(stops);
    final done = stops.where((s) => !s.school && s.state == _St.done).length;
    final homes = stops.where((s) => !s.school && s.state != _St.leave).length;

    return Column(children: [
      _topBar(w, done, homes),
      Expanded(child: _listMode ? _list(w, stops, next, etas) : _mapView(w, stops, next, etas)),
    ]);
  }

  Widget _topBar(ShiftWindow w, int done, int homes) => Material(
        color: w.color,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
             Row(children: [
              Icon(w.icon, color: Colors.amberAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${w.name} shift', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                  Text('$done of $homes stops done · closes ${fmtTime(w.closesAt)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              ),
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _modeBtn(Icons.map_rounded, 'Map', !_listMode, () => _setMode(false), w),
                  _modeBtn(Icons.view_list_rounded, 'List', _listMode, () => _setMode(true), w),
                ]),
              ),
             ]),
             const SizedBox(height: 8),
             ClipRRect(
               borderRadius: BorderRadius.circular(4),
               child: LinearProgressIndicator(
                 value: homes == 0 ? 0 : done / homes,
                 minHeight: 5,
                 backgroundColor: Colors.white.withValues(alpha: 0.2),
                 valueColor: const AlwaysStoppedAnimation(Colors.amberAccent),
               ),
             ),
             _onBusButton(w),
            ]),
          ),
        ),
      );

  // ------------------------------------------------------------------------------- children on the bus

  /// The children for the list button (App Module Settings -> "Children on the Bus list"; one switch for both
  /// shifts):
  ///   evening - every child ON the bus, in the planned drop order (stop number), then by name;
  ///   morning - every child still TO PICK UP (not on leave), nearest to the bus first.
  /// Each entry: the child, its stop number in the plan (999 = not planned), and metres from the bus (morning).
  List<(dynamic, int, double?)> _listKids(ShiftWindow w) {
    final homeKeys = _planKeys.where((k) => k != 'school').toList();
    final out = <(dynamic, int, double?)>[];
    if (!w.isMorning) {
      for (final f in store.families(w.key, Stage.onBus)) {
        final n = homeKeys.indexOf(f.key);
        for (final s in f.students) {
          out.add((s, n < 0 ? 999 : n + 1, null));
        }
      }
      out.sort((a, b) {
        final c = a.$2.compareTo(b.$2);
        return c != 0 ? c : '${a.$1['name'] ?? ''}'.compareTo('${b.$1['name'] ?? ''}');
      });
      return out;
    }
    final at = _best;
    for (final f in store.families(w.key, Stage.waiting)) {
      double? d;
      if (at != null && f.hasCoords) {
        d = RoutePlanner.meters(at, LatLng(double.parse('${f.stopLat}'), double.parse('${f.stopLng}')));
      }
      final n = homeKeys.indexOf(f.key);
      for (final s in f.students) {
        if (_hasNotice(s, w.key)) continue;   // on leave: nothing to pick up
        out.add((s, n < 0 ? 999 : n + 1, d));
      }
    }
    out.sort((a, b) {
      final da = a.$3, db = b.$3;
      if (da != null && db != null && da != db) return da.compareTo(db);
      if (da != null && db == null) return -1;
      if (da == null && db != null) return 1;
      final c = a.$2.compareTo(b.$2);
      return c != 0 ? c : '${a.$1['name'] ?? ''}'.compareTo('${b.$1['name'] ?? ''}');
    });
    return out;
  }

  static String _dist(double m) => m < 1000 ? '${(m / 10).round() * 10} m' : '${(m / 1000).toStringAsFixed(1)} km';

  /// The list button under the progress bar: "Children on the bus · 7" in the evening, "Children to pick up · 5"
  /// in the morning. Opens one list of those children, each with its own button, so they can be marked in
  /// whatever order the bus goes - not only stop by stop.
  Widget _onBusButton(ShiftWindow w) {
    if (!ModuleWatcher.instance.isOn('monitor_onbus')) return const SizedBox.shrink();
    final n = w.isMorning ? _listKids(w).length : store.counts(w.key).onBus;
    if (n == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Material(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openOnBus(w),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Icon(w.isMorning ? Icons.hail_rounded : Icons.airline_seat_recline_normal_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(w.isMorning ? 'Children to pick up · $n' : 'Children on the bus · $n',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13.5)),
              ),
              Text(w.isMorning ? 'Nearest first' : 'Drop in any order',
                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 20),
            ]),
          ),
        ),
      ),
    );
  }

  void _openOnBus(ShiftWindow w) {
    final morning = w.isMorning;
    final label = morning ? 'Picked up' : 'Dropped';
    final type = morning ? 'pickup' : 'dropoff';
    // Morning: re-sort by distance as the bus moves - every 4 s, not on every frame of the bus gliding.
    final tick = ValueNotifier<int>(0);
    final timer = morning ? Timer.periodic(const Duration(seconds: 4), (_) => tick.value++) : null;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (ctx, scroll) => AnimatedBuilder(
          // Live: a child marked here - or anywhere else - leaves the list at once; in the morning the order
          // follows the bus.
          animation: Listenable.merge([store, ModuleWatcher.instance, tick]),
          builder: (ctx, _) {
            final kids = _listKids(w);
            if (kids.isEmpty || !ModuleWatcher.instance.isOn('monitor_onbus')) {
              return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(24, 8, 24, 32), children: [
                const Icon(Icons.check_circle_rounded, color: MonitorColors.green, size: 46),
                const SizedBox(height: 10),
                Text(morning ? 'Everyone has been picked up.' : 'Every child has been dropped.',
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ]);
            }
            return ListView.separated(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              itemCount: kids.length + 1,
              separatorBuilder: (_, i) => i == 0 ? const SizedBox(height: 4) : const Divider(height: 1),
              itemBuilder: (ctx, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(morning ? 'Children to pick up (${kids.length})' : 'Children on the bus (${kids.length})',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(
                          morning
                              ? 'Nearest to the bus first - mark whoever gets on, in any order.'
                              : 'Numbered in the planned order - mark whoever gets off, in any order.',
                          style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
                    ]),
                  );
                }
                final (kid, stopNo, metres) = kids[i - 1];
                final name = '${kid['name'] ?? 'Student'}';
                final grade = '${kid['grade'] ?? ''}'.trim();
                final where = '${kid['address'] ?? ''}'.trim();
                final sub = [if (grade.isNotEmpty) grade, if (where.isNotEmpty) where].join(' · ');
                // Evening: the stop number. Morning: how far the child's home is from the bus.
                final badge = morning ? (metres == null ? '–' : _dist(metres)) : (stopNo >= 999 ? '-' : '$stopNo');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(children: [
                    Container(
                      constraints: BoxConstraints(minWidth: morning ? 52 : 28),
                      height: 28,
                      padding: EdgeInsets.symmetric(horizontal: morning ? 6 : 0),
                      alignment: Alignment.center,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(color: w.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                      child: Text(badge, style: TextStyle(color: w.color, fontWeight: FontWeight.w800, fontSize: morning ? 11.5 : 12.5)),
                    ),
                    Initials(name: name, size: 38, color: w.color),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        if (sub.isNotEmpty)
                          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => MonitorActions(ctx, store).mark(w, kid, type),
                      icon: const Icon(Icons.check_rounded, size: 17),
                      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                      style: FilledButton.styleFrom(
                        backgroundColor: morning ? w.color : MonitorColors.green,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 38),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                      ),
                    ),
                  ]),
                );
              },
            );
          },
        ),
      ),
    ).whenComplete(() {
      timer?.cancel();
      tick.dispose();
    });
  }

  Widget _modeBtn(IconData i, String t, bool on, VoidCallback tap, ShiftWindow w) => InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(i, size: 16, color: on ? w.color : Colors.white),
            const SizedBox(width: 4),
            Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: on ? w.color : Colors.white)),
          ]),
        ),
      );

  // ---------------------------------------------------------------------------------------- map view

  Widget _mapView(ShiftWindow w, List<_Stop> stops, _Stop? next, Map<String, DateTime> etas) {
    final center = _best ?? stops.firstWhere((s) => s.point != null, orElse: () => _Stop('', '', '', _doha, null, const [], _St.todo)).point!;
    if (!_fitted && _best == null && _mapReady) {
      final pts = [for (final s in stops) if (s.point != null && s.state != _St.done) s.point!];
      if (pts.length > 1) {
        _fitted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _listMode) return;
          if (_googleOn) {
            _gcam?.fit(pts, padding: 56, maxZoom: 17);
          } else {
            _map.fitCamera(CameraFit.coordinates(
              coordinates: pts,
              maxZoom: 17,
              padding: EdgeInsets.fromLTRB(40, 70, 70, MediaQuery.of(context).size.height * 0.25),
            ));
          }
        });
      }
    }
    return Stack(children: [
      // THE NATIVE MAP ONLY WHILE THIS TAB IS ON SCREEN. The monitor dashboard keeps its tabs in an IndexedStack,
      // which builds every tab at once - so this map (MapLibre or the official Google map, both native views)
      // used to be created hidden behind the Home tab the moment a monitor with a shift signed in. A native map
      // made and never shown has no real drawing surface, and on iPhones that is what closed the app right after
      // sign-in. Now it is made when the Shift tab opens and removed when the monitor leaves it.
      if (_googleOn && widget.active)
        _googleMap(w, stops, next, center)
      else if (_googleOn)
        const ColoredBox(color: Color(0xFFE8EDF3), child: SizedBox.expand())
      else
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: center,
          initialZoom: 16,
          // The map has street detail up to zoom 15 and is drawn larger up to 18; closer than
          // that it would go blank, and Qatar fits in zoom 8.
          minZoom: 8,
          maxZoom: MapConfig.instance.value.maxZoom,
          // Two fingers turn the map a full 360 degrees; the compass button snaps it back to north.
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
          onMapReady: () => setState(() => _mapReady = true),
          onPositionChanged: (camera, hasGesture) {
            _rotation.value = camera.rotation;
            if (hasGesture && _follow) setState(() => _follow = false);
          },
        ),
        children: [
          _baseMap,
          if (_plan != null && (_lineNow ?? _plan!.line).length > 1)
            PolylineLayer(polylines: [
              Polyline(points: _lineNow ?? _plan!.line, strokeWidth: 6, color: w.color.withValues(alpha: 0.85), borderStrokeWidth: 2, borderColor: Colors.white),
            ]),
          MarkerLayer(markers: [
            for (final s in stops)
              if (s.point != null)
                Marker(
                  point: s.point!,
                  width: 44,
                  height: 44,
                  rotate: true,
                  child: GestureDetector(onTap: () => _choose(s), child: _pin(s, next, w)),
                ),
          ]),
          // The monitor's phone: a small blue dot.
          ValueListenableBuilder<LatLng?>(
            valueListenable: _phoneDot,
            builder: (context, p, _) => p == null
                ? const SizedBox.shrink()
                : MarkerLayer(markers: [
                    Marker(
                      point: p,
                      width: 20,
                      height: 20,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
                        ),
                      ),
                    ),
                  ]),
          ),
          // The bus - from its tracker - gliding.
          ValueListenableBuilder<_Fix?>(
            valueListenable: _shown,
            builder: (context, f, _) => f == null
                ? const SizedBox.shrink()
                : MarkerLayer(markers: [
                    Marker(
                      point: f.pos,
                      width: 46,
                      height: 46,
                      child: Transform.rotate(angle: f.heading * math.pi / 180, child: _arrow(w)),
                    ),
                  ]),
          ),
          // Licence credit: under the position label, clear of the stop card at the bottom.
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 50, 8, 4),
              child: Text(MapConfig.instance.value.credit, style: const TextStyle(fontSize: 9, color: Color(0xFF64748B))),
            ),
          ),
        ],
      ),
      Positioned(
        top: 10,
        left: 12,
        right: 64,
        child: Align(
          alignment: Alignment.centerLeft,
          child: _glass(Row(mainAxisSize: MainAxisSize.min, children: [
            _srcIcon(),
            const SizedBox(width: 6),
            Flexible(child: Text(_sourceLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
            if (_plan != null && !_plan!.road) ...[
              const SizedBox(width: 6),
              const Text('· est. route', style: TextStyle(fontSize: 11, color: MonitorColors.muted)),
            ],
          ])),
        ),
      ),
      Positioned(
        right: 12,
        top: 10,
        child: Column(children: [
          _fab(_follow ? Icons.navigation_rounded : Icons.navigation_outlined, _follow ? 'Following the bus' : 'Follow the bus', () {
            setState(() => _follow = true);
            final f = _shown.value;
            if (f != null && _mapReady) _camMoveNorth(f.pos, 16);
          }, on: _follow),
          const SizedBox(height: 10),
          _fab(Icons.format_list_numbered_rounded, 'All stops', () {
            setState(() => _cardOpen = true);
          }),
          // Compass: appears once the map is turned; one tap brings north back up.
          ValueListenableBuilder<double>(
            valueListenable: _rotation,
            builder: (context, rot, _) {
              final turned = rot % 360;
              if (!(turned > 1 && turned < 359)) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  elevation: 4,
                  shadowColor: Colors.black38,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _camNorth,
                    child: Tooltip(
                      message: 'Point north up',
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        // North on screen is the map's turn, clockwise; the needle follows it.
                        child: Transform.rotate(
                          angle: rot * math.pi / 180,
                          child: const Icon(Icons.navigation_rounded, color: Color(0xFFDC2626), size: 22),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ]),
      ),
      if (_banner != null)
        Positioned(
          top: 52,
          left: 12,
          right: 64,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: MonitorColors.navy, borderRadius: BorderRadius.circular(12)),
            child: Text(_banner!, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ),
      Positioned(
        left: 10,
        right: 10,
        bottom: 10,
        child: _stopCardSmall(w, stops, next, etas),
      ),
    ]);
  }

  /// The map's card. Closed: the next stop in two lines and the one button that matters there.
  /// Open (tap): every child with their buttons, call / directions / skip, and all stops.
  Widget _stopCardSmall(ShiftWindow w, List<_Stop> stops, _Stop? next, Map<String, DateTime> etas) {
    final maxOpen = MediaQuery.of(context).size.height * 0.62;
    void toggle() => setState(() => _cardOpen = !_cardOpen);
    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: toggle,
              child: Column(children: [
                Container(width: 34, height: 4, margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(color: MonitorColors.line, borderRadius: BorderRadius.circular(4))),
                if (next == null) _allDone(w) else _nextLine(next, w, etas),
              ]),
            ),
            if (_cardOpen)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxOpen),
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (next != null) ...[
                      const SizedBox(height: 10),
                      ..._kidRows(next, w),
                      _bulk(next, w),
                      const SizedBox(height: 8),
                      _stopTools(next),
                    ],
                    const Divider(height: 22, color: MonitorColors.line),
                    const SectionTitle('All stops'),
                    const SizedBox(height: 4),
                    ..._compactStops(stops, next, w, etas),
                  ]),
                ),
              )
            else if (next != null)
              ..._quickAction(next, w),
          ]),
        ),
      ),
    );
  }

  /// "1  Imran Khan                Reach 7:45 AM"
  /// "   Next stop · 2.5 km · 3 left        ⌃"
  Widget _nextLine(_Stop s, ShiftWindow w, Map<String, DateTime> etas) {
    final idx = _planKeys.indexOf(s.key);
    final reach = _reach(etas, s);
    final left = _planKeys.length;
    return Row(children: [
      Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: w.color, shape: BoxShape.circle),
        child: s.school
            ? const Icon(Icons.school_rounded, size: 18, color: Colors.white)
            : Text(idx >= 0 ? '${idx + 1}' : '•', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
          Text(
            [s.school ? 'Next: school' : 'Next stop', _away(s), if (left > 1) '$left left'].where((t) => t.isNotEmpty).join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: MonitorColors.muted),
          ),
        ]),
      ),
      if (reach.isNotEmpty) ...[
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: w.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
          child: Text(reach.replaceFirst('Reach ', ''), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: w.color)),
        ),
      ],
      Icon(_cardOpen ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded, color: MonitorColors.muted, size: 22),
    ]);
  }

  /// Closed card: the stop's main step as one button ("Picked up · Zara", "All picked up (2)"),
  /// with call and directions beside it. Leave to confirm, or anything else, opens the card.
  List<Widget> _quickAction(_Stop s, ShiftWindow w) {
    final kids = _mainKids(s, w);
    final type = _mainType(s, w);
    final leaveToConfirm = s.kids.where((k) {
      final a = _action(k, s, w);
      return a != null && (a.$2 == 'leave' || a.$2 == 'by_parent');
    }).length;
    final f = s.family;
    final actions = MonitorActions(context, store);
    final String label;
    VoidCallback? onTap;
    if (kids.length == 1) {
      label = '${_action(kids.first, s, w)!.$1} · ${'${kids.first['name'] ?? ''}'.split(' ').first}';
      onTap = () => actions.mark(w, kids.first, type);
    } else if (kids.length > 1) {
      label = '${_mainTitle(s, w)} (${kids.length})';
      onTap = () => actions.markMany(w, kids, type, _mainTitle(s, w));
    } else {
      label = leaveToConfirm > 0 ? 'Confirm leave ($leaveToConfirm)' : 'Open stop';
      onTap = () => setState(() => _cardOpen = true);
    }
    return [
      if (leaveToConfirm > 0 && kids.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('$leaveToConfirm on leave here - tap the card to confirm',
              style: const TextStyle(fontSize: 11.5, color: MonitorColors.byParent, fontWeight: FontWeight.w600)),
        ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: SizedBox(
            height: 42,
            child: FilledButton.icon(
              onPressed: onTap,
              icon: Icon(kids.isEmpty ? Icons.unfold_more_rounded : Icons.check_rounded, size: 18),
              label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              style: FilledButton.styleFrom(
                backgroundColor: kids.isEmpty ? (leaveToConfirm > 0 ? MonitorColors.byParent : w.color) : (type == 'dropoff' ? MonitorColors.green : w.color),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        if (f != null && f.phone.isNotEmpty) ...[
          const SizedBox(width: 8),
          _roundTool(Icons.call_rounded, 'Call', () => actions.call(f.phone)),
        ],
        if (f != null && f.hasCoords) ...[
          const SizedBox(width: 8),
          _roundTool(Icons.directions_rounded, 'Directions', () => actions.directions(f)),
        ],
      ]),
    ];
  }

  Widget _roundTool(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: Material(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(width: 42, height: 42, child: Icon(icon, color: MonitorColors.navy, size: 20)),
          ),
        ),
      );

  // ---------------------------------------------------------------------------------------- list view

  Widget _list(ShiftWindow w, List<_Stop> stops, _Stop? next, Map<String, DateTime> etas) {
    final ordered = _ordered(stops);
    final todo = [
      if (next != null) next,
      ...ordered.where((s) => s.state == _St.todo && s.key != next?.key),
    ];
    final leave = stops.where((s) => s.state == _St.leave).toList();
    final doneStops = stops.where((s) => s.state == _St.done).toList();
    return RefreshIndicator(
      onRefresh: () => store.load(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          PageWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.only(bottom: 12), child: _summary(w, stops, etas)),
              if (next == null) Padding(padding: const EdgeInsets.only(bottom: 12), child: SurfaceCard(child: _allDone(w))),
              for (final s in todo)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: _stopCard(s, w, next?.key == s.key, etas)),
              if (leave.isNotEmpty) ...[
                const SizedBox(height: 4),
                SectionTitle('On leave - not on the route (${leave.length})'),
                const SizedBox(height: 6),
                for (final s in leave) Padding(padding: const EdgeInsets.only(bottom: 8), child: _stopCard(s, w, false, etas)),
              ],
              if (doneStops.isNotEmpty) ...[
                const SizedBox(height: 4),
                InkWell(
                  onTap: () => setState(() => _showDone = !_showDone),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    child: Row(children: [
                      const Icon(Icons.task_alt_rounded, color: MonitorColors.green, size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Done (${doneStops.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                      Icon(_showDone ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: MonitorColors.muted),
                    ]),
                  ),
                ),
                if (_showDone)
                  for (final s in doneStops) Padding(padding: const EdgeInsets.only(bottom: 8), child: _stopCard(s, w, false, etas)),
              ],
            ]),
          ),
        ],
      ),
    );
  }

  /// Stops in the planned order: the planned ones first, then any not planned yet (just added, or
  /// no location). The school stays where the trip has it - last in the morning, first in the
  /// evening - so a newly added home never lands after it.
  List<_Stop> _ordered(List<_Stop> stops) {
    final homes = [
      for (final k in _planKeys) ...stops.where((s) => s.key == k && !s.school),
      ...stops.where((s) => !_planKeys.contains(s.key) && !s.school),
    ];
    final school = stops.where((s) => s.school).toList();
    final morning = _shift?.isMorning ?? true;
    return morning ? [...homes, ...school] : [...school, ...homes];
  }

  Widget _stopCard(_Stop s, ShiftWindow w, bool isNext, Map<String, DateTime> etas) {
    final actions = MonitorActions(context, store);
    final reach = s.state == _St.todo ? _reach(etas, s) : '';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isNext ? w.color : MonitorColors.line, width: isNext ? 1.6 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(width: 34, height: 34, child: _pin(s, isNext ? s : null, w)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (isNext)
                Text('NEXT STOP', style: TextStyle(color: w.color, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: .6)),
              Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              Text(
                [if (reach.isNotEmpty) reach, if (s.state == _St.todo) _away(s), if (s.state == _St.leave) 'Everyone on leave'].where((t) => t.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: isNext ? w.color : MonitorColors.muted, fontWeight: isNext ? FontWeight.w700 : FontWeight.w500),
              ),
            ]),
          ),
          if (s.family != null && s.family!.phone.isNotEmpty)
            IconButton(tooltip: 'Call', visualDensity: VisualDensity.compact, onPressed: () => actions.call(s.family!.phone),
                icon: const Icon(Icons.call_rounded, color: Color(0xFF1D4ED8), size: 20)),
          if (s.family != null && s.family!.hasCoords)
            IconButton(tooltip: 'Directions', visualDensity: VisualDensity.compact, onPressed: () => actions.directions(s.family!),
                icon: const Icon(Icons.directions_rounded, color: MonitorColors.byParent, size: 20)),
        ]),
        if (s.state != _St.leave || isNext) ...[
          const SizedBox(height: 6),
          ..._kidRows(s, w),
          _bulk(s, w),
        ],
      ]),
    );
  }

  // ---------------------------------------------------------------------------------------- shared pieces

  Widget _glass(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 10, offset: Offset(0, 2))],
        ),
        child: child,
      );

  Widget _fab(IconData icon, String tip, VoidCallback onTap, {bool on = false}) => Tooltip(
        message: tip,
        child: Material(
          color: on ? MonitorColors.navy : Colors.white,
          shape: const CircleBorder(),
          elevation: 3,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 44, height: 44, child: Icon(icon, color: on ? Colors.white : MonitorColors.navy)),
          ),
        ),
      );

  /// The official Google map: the stops, the monitor's phone, the bus and the planned line.
  Widget _googleMap(ShiftWindow w, List<_Stop> stops, _Stop? next, LatLng center) {
    final pins = <GPin>[
      for (final s in stops)
        if (s.point != null) GPin(id: 'stop_${s.key}', pos: s.point!, style: _pinStyle(s, next, w), onTap: () => _choose(s)),
      if (_phoneDot.value != null)
        GPin(id: 'phone', pos: _phoneDot.value!, style: const PinStyle(size: 18, color: Color(0xFF2563EB), border: 3)),
    ];
    final src = MapConfig.instance.value;
    final lines = [
      if (_plan != null && (_lineNow ?? _plan!.line).length > 1)
        GLine(id: 'plan', points: _lineNow ?? _plan!.line, color: w.color.withValues(alpha: 0.85)),
    ];
    BusLook look() => BusLook(
          body: PinStyle(size: 34, color: Colors.white, border: 0, icon: Icons.navigation_rounded, fg: w.color, halo: w.color.withValues(alpha: 0.18)),
          heading: _shown.value?.heading ?? 0,
          rotate: true,
        );
    final pad = EdgeInsets.only(top: 50, bottom: MediaQuery.of(context).size.height * 0.22);
    void ready(BusMapCam cam) {
      _gcam = cam;
      setState(() => _mapReady = true);
    }
    void gesture() {
      if (_follow) setState(() => _follow = false);
    }
    if (src.isLibre) {
      return LibreBusMap(
        key: ValueKey('lmap-${src.signature}'),
        styleUrl: src.url,
        initialCenter: center,
        initialZoom: 16,
        pins: pins,
        lines: lines,
        bus: _shownPos,
        busLook: look,
        padding: pad,
        onReady: ready,
        onUserGesture: gesture,
        onRotation: (r) => _rotation.value = r,
      );
    }
    return GoogleBusMap(
      key: ValueKey('gmap-${src.signature}'),
      initialCenter: center,
      initialZoom: 16,
      hybrid: src.googleHybrid,
      pins: pins,
      lines: lines,
      bus: _shownPos,
      busLook: look,
      padding: pad,
      onReady: ready,
      onUserGesture: gesture,
      onRotation: (r) => _rotation.value = r,
    );
  }

  /// A stop's pin on the official Google map - the same colours and numbers as [_pin].
  PinStyle _pinStyle(_Stop s, _Stop? next, ShiftWindow w) {
    final isNext = next?.key == s.key;
    final idx = _planKeys.indexOf(s.key);
    final Color bg = switch (s.state) {
      _St.done => MonitorColors.green,
      _St.leave => const Color(0xFFCBD5E1),
      _St.todo => isNext ? w.color : const Color(0xFF64748B),
    };
    final size = isNext ? 40.0 : 30.0;
    if (s.school) return PinStyle(size: size, color: bg, border: isNext ? 3 : 2, icon: Icons.school_rounded);
    if (s.state == _St.leave) return PinStyle(size: size, color: bg, border: 2, text: 'L', fg: const Color(0xFF475569));
    if (s.state == _St.done) return PinStyle(size: size, color: bg, border: 2, icon: Icons.check_rounded);
    return PinStyle(size: size, color: bg, border: isNext ? 3 : 2, text: idx >= 0 ? '${idx + 1}' : '•');
  }

  Widget _arrow(ShiftWindow w) => Stack(alignment: Alignment.center, children: [
        Container(width: 46, height: 46, decoration: BoxDecoration(color: w.color.withValues(alpha: 0.18), shape: BoxShape.circle)),
        Container(
          width: 30,
          height: 30,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 6)]),
          child: Icon(Icons.navigation_rounded, color: w.color, size: 22),
        ),
      ]);

  Widget _pin(_Stop s, _Stop? next, ShiftWindow w) {
    final isNext = next?.key == s.key;
    final idx = _planKeys.indexOf(s.key);
    final Color bg = switch (s.state) {
      _St.done => MonitorColors.green,
      _St.leave => const Color(0xFFCBD5E1),
      _St.todo => isNext ? w.color : const Color(0xFF64748B),
    };
    final size = isNext ? 40.0 : 30.0;
    return Center(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: isNext ? 3 : 2),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
        ),
        child: s.school
            ? Icon(Icons.school_rounded, size: isNext ? 20 : 16, color: Colors.white)
            : s.state == _St.leave
                ? const Text('L', style: TextStyle(color: Color(0xFF475569), fontWeight: FontWeight.w800, fontSize: 12))
                : s.state == _St.done
                    ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                    : Text(idx >= 0 ? '${idx + 1}' : '•',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: isNext ? 15 : 12)),
      ),
    );
  }

  void _choose(_Stop s) {
    if (s.state != _St.todo) return;
    setState(() {
      _activeKey = s.key;
      _skipped.remove(s.key);
      _planSig = '';
    });
    _say('${s.title} is next.');
    _maybePlan();
    if (!_listMode) setState(() => _cardOpen = true);
  }

  /// What to do with this child at this stop: label, event, colour. Null when nothing is needed.
  (String, String, Color)? _action(dynamic kid, _Stop s, ShiftWindow w) {
    final shift = w.key;
    final stage = store.stageOf(kid, shift);
    final n = store.noticeFor(kid, shift);
    if (stage == Stage.waiting && n != null) return ('Confirm leave', n == 'parent' ? 'by_parent' : 'leave', n == 'parent' ? MonitorColors.byParent : MonitorColors.red);
    if (w.isMorning) {
      if (!s.school && stage == Stage.waiting) return ('Picked up', 'pickup', w.color);
      if (s.school && stage == Stage.onBus) return ('At school', 'dropoff', MonitorColors.green);
    } else {
      if (s.school && stage == Stage.waiting) return ('Boarded', 'pickup', w.color);
      if (!s.school && stage == Stage.onBus) return ('Dropped home', 'dropoff', MonitorColors.green);
    }
    return null;
  }

  /// The stop's main step for this shift, and the children it applies to (not those on leave).
  String _mainType(_Stop s, ShiftWindow w) => w.isMorning ? (s.school ? 'dropoff' : 'pickup') : (s.school ? 'pickup' : 'dropoff');
  List<dynamic> _mainKids(_Stop s, ShiftWindow w) => s.kids.where((k) => _action(k, s, w)?.$2 == _mainType(s, w)).toList();
  String _mainTitle(_Stop s, ShiftWindow w) =>
      w.isMorning ? (s.school ? 'Everyone at school' : 'All picked up') : (s.school ? 'All boarded' : 'All dropped home');

  /// "All picked up (2)", "Everyone at school (6)", "All boarded (5)", "All dropped home (2)".
  Widget _bulk(_Stop s, ShiftWindow w) {
    final kids = _mainKids(s, w);
    if (kids.length < 2) return const SizedBox.shrink();
    final type = _mainType(s, w);
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 6),
      child: SizedBox(
        height: 44,
        child: FilledButton.icon(
          onPressed: () => MonitorActions(context, store).markMany(w, kids, type, _mainTitle(s, w)),
          icon: const Icon(Icons.done_all_rounded),
          label: Text('${_mainTitle(s, w)} (${kids.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
          style: FilledButton.styleFrom(
            backgroundColor: type == 'dropoff' ? MonitorColors.green : w.color,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
  }

  Widget _stopTools(_Stop s) {
    final actions = MonitorActions(context, store);
    final f = s.family;
    Widget tool(IconData i, String t, VoidCallback? onTap) => Expanded(
          child: TextButton.icon(
            onPressed: onTap,
            icon: Icon(i, size: 17),
            label: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            style: TextButton.styleFrom(
              foregroundColor: MonitorColors.navy,
              backgroundColor: const Color(0xFFF1F5F9),
              disabledForegroundColor: const Color(0xFFCBD5E1),
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        );
    return Row(children: [
      tool(Icons.call_rounded, 'Call', f != null && f.phone.isNotEmpty ? () => actions.call(f.phone) : null),
      const SizedBox(width: 8),
      tool(Icons.directions_rounded, 'Directions', f != null && f.hasCoords ? () => actions.directions(f) : null),
      const SizedBox(width: 8),
      tool(Icons.skip_next_rounded, 'Skip', s.school
          ? null
          : () => setState(() {
                _skipped.add(s.key);
                if (_activeKey == s.key) _activeKey = null;
                _planSig = '';
                _say('${s.title} skipped for now - it stays in the list.');
              })),
    ]);
  }

  List<Widget> _kidRows(_Stop s, ShiftWindow w) {
    final actions = MonitorActions(context, store);
    Widget buttons(dynamic k) {
      final a = _action(k, s, w);
      if (a == null) return Icon(StatusStyle.icon(store.eventOf(k, w.key)), color: StatusStyle.color(store.eventOf(k, w.key)));
      final small = ButtonStyle(
        visualDensity: VisualDensity.compact,
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      );
      return Row(mainAxisSize: MainAxisSize.min, children: [
        FilledButton(
          onPressed: () => actions.mark(w, k, a.$2),
          style: small.merge(FilledButton.styleFrom(backgroundColor: a.$3)),
          child: Text(a.$1, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        if (a.$2 == 'pickup') ...[
          const SizedBox(width: 6),
          OutlinedButton(
            onPressed: () => actions.notTravelling(w, k),
            style: small.merge(OutlinedButton.styleFrom(foregroundColor: const Color(0xFF475569), side: const BorderSide(color: MonitorColors.line))),
            child: const Text('Absent', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ],
      ]);
    }

    Widget who(dynamic k) => Row(children: [
          Initials(name: '${k['name'] ?? '?'}', size: 32, color: w.color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${k['name'] ?? 'Student'}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, height: 1.2)),
              if (store.noticeFor(k, w.key) != null)
                Text('Leave: ${store.noticeOf(k)?['summary'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: MonitorColors.byParent, fontWeight: FontWeight.w600))
              else
                Text(StatusStyle.label(store.eventOf(k, w.key), w.key), style: const TextStyle(fontSize: 12, color: MonitorColors.muted)),
            ]),
          ),
        ]);

    return [
      for (final k in s.kids)
        Padding(
          padding: const EdgeInsets.only(bottom: 8, right: 6),
          child: LayoutBuilder(builder: (context, c) {
            final hasTwo = _action(k, s, w)?.$2 == 'pickup';
            // Narrow: name on its own line, buttons under it - never "Muhamma…".
            if (c.maxWidth < (hasTwo ? 360 : 300)) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                who(k),
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: buttons(k)),
              ]);
            }
            return Row(children: [Expanded(child: who(k)), const SizedBox(width: 8), buttons(k)]);
          }),
        ),
    ];
  }

  /// The list's top card: how far the shift is, who is on the bus, and where the position comes from.
  Widget _summary(ShiftWindow w, List<_Stop> stops, Map<String, DateTime> etas) {
    final homes = stops.where((s) => !s.school && s.state != _St.leave).length;
    final doneHomes = stops.where((s) => !s.school && s.state == _St.done).length;
    final onBus = store.students.where((k) => store.stageOf(k, w.key) == Stage.onBus).length;
    final school = stops.where((s) => s.school).firstOrNull;
    final schoolAt = school == null ? null : etas[school.key];
    Widget stat(String v, String l) => Expanded(
          child: Column(children: [
            Text(v, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: w.color)),
            Text(l, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: MonitorColors.muted)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: MonitorColors.line)),
      child: Column(children: [
        Row(children: [
          stat('$doneHomes/$homes', 'stops done'),
          stat('$onBus', 'on the bus'),
          stat(schoolAt == null ? '--' : DateFormat('h:mm').format(schoolAt), w.isMorning ? 'at school' : 'school left'),
        ]),
        const Divider(height: 18, color: MonitorColors.line),
        Row(children: [
          _srcIcon(),
          const SizedBox(width: 6),
          Expanded(child: Text(_sourceLabel, style: const TextStyle(fontSize: 12, color: MonitorColors.muted, fontWeight: FontWeight.w600))),
        ]),
      ]),
    );
  }

  List<Widget> _compactStops(List<_Stop> stops, _Stop? next, ShiftWindow w, Map<String, DateTime> etas) => [
        for (final s in _ordered(stops))
          InkWell(
            onTap: () => _choose(s),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                SizedBox(width: 34, height: 34, child: _pin(s, next, w)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: s.key == next?.key ? FontWeight.w800 : FontWeight.w600)),
                    Text(
                      s.state == _St.leave
                          ? 'On leave - not on the route'
                          : [
                              s.kids.map((k) => '${k['name'] ?? ''}'.split(' ').first).join(', '),
                              if (s.state == _St.todo) _reach(etas, s),
                              if (_skipped.contains(s.key)) 'skipped',
                            ].where((t) => t.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: MonitorColors.muted),
                    ),
                  ]),
                ),
                if (s.state == _St.done) const Icon(Icons.check_rounded, color: MonitorColors.green, size: 20),
              ]),
            ),
          ),
      ];

  Widget _allDone(ShiftWindow w) => Row(children: [
        const Icon(Icons.task_alt_rounded, color: MonitorColors.green),
        const SizedBox(width: 10),
        Expanded(child: Text('${w.name} route complete - every child is accounted for.', style: const TextStyle(fontWeight: FontWeight.w700))),
      ]);
}
