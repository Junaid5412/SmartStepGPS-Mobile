import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import '../../services/api_service.dart';
import '../../services/offline_map.dart';
import 'monitor_actions.dart';
import 'monitor_shift_view.dart';
import 'monitor_store.dart';
import 'monitor_widgets.dart';
import 'phone_location.dart';
import 'route_planner.dart';

/// The Shift tab - the ONE place attendance is marked. While a shift is open it shows the stops in
/// the best order, either on a live MAP or as a LIST (a switch at the top, remembered per phone);
/// both use the same stops, order and buttons. When no shift is open it shows the countdown.
///
/// WHERE THE BUS IS: the bus's own GPS tracker is the truth - it is in the bus. The monitor's phone
/// is shown too (a small blue dot) and takes over whenever the tracker has gone quiet (no signal),
/// so the page keeps working either way.
///
/// - The next stop is always the NEAREST unfinished one; the rest follow in the shortest order
///   (RoutePlanner), re-worked when a stop is done, when the nearest changes, or every minute.
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
  final _sheet = DraggableScrollableController();
  Widget? _tiles;
  bool _mapReady = false;
  bool _fitted = false;
  bool _listMode = false;
  bool _showDone = false;

  // ---- where the bus is ---------------------------------------------------------------------------
  bool _phoneOn = false;
  Timer? _trackerPoll;
  LatLng? _busPos; // the tracker
  DateTime? _busAt;
  LatLng? _phonePos; // the monitor's phone
  DateTime? _phoneAt;
  LatLng? _bestPrev;
  double _heading = 0;
  LatLng? _headAnchor; // where the current heading was measured from
  bool? _headFromTracker;
  final ValueNotifier<_Fix?> _shown = ValueNotifier(null); // the gliding bus arrow
  final ValueNotifier<LatLng?> _phoneDot = ValueNotifier(null);
  late final AnimationController _glide;
  LatLng? _glideFrom, _glideTo;
  double _headFrom = 0, _headTo = 0;
  DateTime _lastTarget = DateTime.now();
  bool _follow = true;

  // ---- the route ----------------------------------------------------------------------------------
  RoutePlan? _plan;
  List<String> _planKeys = [];
  final Map<String, double> _legSec = {}; // road time to each stop from the one before it
  double _leadStraight = 0; // straight-line metres from the bus to the next stop when planned
  List<LatLng>? _lineNow; // the planned line, with the part already driven cut off
  String _planSig = '';
  DateTime _planAt = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _planFrom;
  bool _planning = false;
  String? _activeKey; // the stop she is at, or chose
  final Set<String> _skipped = {};
  String? _banner;
  Timer? _bannerTimer;
  Timer? _clock; // arrival times move with the clock

  MonitorStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 950))..addListener(_onGlide);
    OfflineMap.load().then((m) {
      if (!mounted) return;
      setState(() => _tiles = VectorTileLayer(
            theme: m.theme,
            tileProviders: TileProviders({OfflineMap.sourceName: m.provider}),
            maximumTileSubstitutionDifference: 3,
            maximumZoom: 20,
          ));
    }).catchError((Object e) => debugPrint('Offline map failed to load: $e'));
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _listMode = p.getString(_prefMode) == 'list');
    });
    store.addListener(_onStore);
    _syncTracking();
  }

  @override
  void didUpdateWidget(MonitorRouteView old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _syncTracking();
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    _stopTracking();
    _glide.dispose();
    _shown.dispose();
    _phoneDot.dispose();
    _bannerTimer?.cancel();
    _sheet.dispose();
    super.dispose();
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
    if (want && _trackerPoll == null) {
      _startTracking();
    } else if (!want && _trackerPoll != null) {
      _stopTracking();
    }
  }

  void _startTracking() {
    // 1. The bus tracker - the real position of the bus - every 5 seconds.
    if (store.busDeviceId > 0) {
      _pollTracker();
      _trackerPoll = Timer.periodic(const Duration(seconds: 5), (_) => _pollTracker());
    } else {
      _trackerPoll = Timer.periodic(const Duration(hours: 1), (_) {}); // marks tracking as running
    }
    // 2. The monitor's phone - shown, and used whenever the tracker has no signal.
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

  Future<void> _pollTracker() async {
    try {
      final r = await ApiService.getBusLocation(store.busDeviceId);
      final loc = r['location'] ?? r['last_known_location'];
      if (loc is! Map || loc['lat'] == null || loc['lng'] == null) return;
      // The server may answer with this very phone's position (the parents' backup) - not the tracker.
      if (loc['source'] == 'monitor') return;
      final p = LatLng((loc['lat'] as num).toDouble(), (loc['lng'] as num).toDouble());
      // The fix's own time (Qatar time, like this phone) - so a tracker repeating an old position
      // while it has no signal is recognised as stale, not as a bus standing still.
      final at = DateTime.tryParse('${loc['updated_at'] ?? ''}'.replaceFirst(' ', 'T')) ?? DateTime.now();
      _busPos = p;
      _busAt = at;
      _onAnyFix();
    } catch (_) {/* next poll */}
  }

  void _stopTracking() {
    if (_phoneOn) PhoneLocation.instance.position.removeListener(_onPhone);
    _phoneOn = false;
    _trackerPoll?.cancel();
    _trackerPoll = null;
    _clock?.cancel();
    _clock = null;
  }

  bool get _trackerFresh => _busAt != null && DateTime.now().difference(_busAt!).inSeconds.abs() <= _trackerFreshSec;
  bool get _phoneFresh => _phoneAt != null && DateTime.now().difference(_phoneAt!).inSeconds <= _phoneFreshSec;

  /// The bus position to use: the tracker while it is reporting, otherwise the monitor's phone.
  LatLng? get _best {
    if (_trackerFresh) return _busPos;
    if (_phoneFresh) return _phonePos;
    return _busPos ?? _phonePos;
  }

  String get _sourceLabel {
    if (_trackerFresh) return 'Bus tracker · live';
    if (_phoneFresh) return 'Tracker offline · using your phone';
    if (_busPos != null) return 'Tracker last seen ${_busAt == null ? '' : DateFormat('h:mm a').format(_busAt!)}';
    return 'Finding the bus…';
  }

  void _onAnyFix() {
    if (!mounted) return;
    final p = _best;
    if (p == null) return;
    final prev = _bestPrev;
    if (prev != null && RoutePlanner.meters(prev, p) < 1) return; // nothing moved
    _bestPrev = p;
    // Direction of travel. GPS wanders a few metres even when the bus stands still, and the tracker
    // and the phone disagree by a few metres too - so measure only over a real move (15 m) and
    // start again, without turning, whenever the position switches between tracker and phone.
    final src = _trackerFresh;
    if (_headAnchor == null || _headFromTracker != src) {
      _headAnchor = p;
      _headFromTracker = src;
    } else if (RoutePlanner.meters(_headAnchor!, p) > 15) {
      _heading = RoutePlanner.bearing(_headAnchor!, p);
      _headAnchor = p;
    }

    // Glide over about the time since the last new position (tracker ~5 s, phone ~1 s).
    final gap = DateTime.now().difference(_lastTarget).inMilliseconds.clamp(600, 5000);
    _lastTarget = DateTime.now();
    final cur = _shown.value;
    _glideFrom = cur?.pos ?? p;
    _glideTo = p;
    _headFrom = cur?.heading ?? _heading;
    _headTo = _heading;
    _glide.duration = Duration(milliseconds: gap);
    _glide.forward(from: 0);

    _checkArrival(p);
    _maybePlan();
    final plan = _plan;
    if (plan != null && plan.line.length > 2) {
      setState(() => _lineNow = RoutePlanner.ahead(plan.line, p));
    } else if (prev == null) {
      setState(() {});
    }
  }

  void _onGlide() {
    final a = _glideFrom, b = _glideTo;
    if (a == null || b == null) return;
    final t = Curves.easeInOut.transform(_glide.value);
    final pos = LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
    var dh = (_headTo - _headFrom) % 360;
    if (dh > 180) dh -= 360;
    final head = (_headFrom + dh * t) % 360;
    _shown.value = _Fix(pos, head);
    if (_follow && _mapReady && !_listMode) _map.move(pos, _map.camera.zoom);
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
        st = onBus.isNotEmpty ? _St.todo : (allLeave ? _St.leave : _St.done);
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

  /// The stop to deal with now: the one she is at or chose, else the nearest.
  _Stop? _next(List<_Stop> stops, ShiftWindow w) {
    final todo = {for (final s in stops) if (s.state == _St.todo) s.key: s};
    if (_activeKey != null && todo.containsKey(_activeKey)) return todo[_activeKey];
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
    if (!_listMode && _sheet.isAttached && _sheet.size < 0.3) {
      _sheet.animateTo(0.48, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _say(String text) {
    _bannerTimer?.cancel();
    setState(() => _banner = text);
    _bannerTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _banner = null);
    });
  }

  // ---------------------------------------------------------------------------------------- planning

  Future<void> _maybePlan() async {
    final w = _shift;
    if (w == null || _planning) return;
    final start = _best ?? (store.schoolLat != null ? LatLng(store.schoolLat!, store.schoolLng!) : null);
    if (start == null) return;
    final stops = _stops(w);
    final todo = stops.where((s) => s.state == _St.todo && s.point != null).toList();
    final first = _next(stops, w);
    final sig = '${w.key}|${todo.map((s) => s.key).join(',')}|${first?.key}';
    final moved = _planFrom == null ? 1e9 : RoutePlanner.meters(_planFrom!, start);
    final age = DateTime.now().difference(_planAt);
    // Re-plan when the stops or the next stop change, or every minute while the bus is moving -
    // but never more than every 15 seconds, to stay gentle with the free routing service.
    final changed = sig != _planSig;
    final drifting = age > const Duration(seconds: 60) && moved > 300;
    if (!changed && !drifting) return;
    if (_planSig.isNotEmpty && age < Duration(seconds: changed ? 3 : 15)) return;

    _planning = true;
    try {
      // The nearest stop first, then the shortest drive through the rest; the morning ends at school.
      final lead = <_Stop>[if (first != null && first.point != null) first];
      final schoolStop = todo.where((s) => s.school).firstOrNull;
      final end = (w.isMorning && schoolStop != null && first != schoolStop) ? schoolStop : null;
      final rest = todo.where((s) => !lead.contains(s) && s != end).toList();
      final from = lead.isNotEmpty ? lead.last.point! : start;

      final plan = await RoutePlanner.plan(from, [for (final s in rest) s.point!], end: end?.point);
      if (!mounted) return;
      final keys = [...lead.map((s) => s.key), for (final i in plan.order) rest[i].key, if (end != null) end.key];
      final byKey = {for (final s in todo) s.key: s};
      final ordered = [for (final k in keys) byKey[k]!.point!];

      // The whole way along the roads - from the bus to the next stop, and on through the rest. The
      // order above only says WHICH stop comes next; drawing just the stops after the next one by
      // road left the most important leg, bus -> next stop, as a straight line across the map.
      final full = await RoutePlanner.roadPath([start, ...ordered]);
      if (!mounted) return;
      _legSec.clear();
      List<LatLng> line;
      bool road;
      if (full != null) {
        for (var i = 0; i < keys.length && i < full.legSeconds.length; i++) {
          _legSec[keys[i]] = full.legSeconds[i];
        }
        line = full.line;
        road = true;
      } else {
        for (var i = 0; i < plan.order.length && i < plan.legSeconds.length; i++) {
          _legSec[rest[plan.order[i]].key] = plan.legSeconds[i];
        }
        if (end != null && plan.legSeconds.length > plan.order.length) _legSec[end.key] = plan.legSeconds[plan.order.length];
        line = [start, for (final s in lead) s.point!, ...plan.line];
        road = false;
      }
      _leadStraight = ordered.isEmpty ? 0 : RoutePlanner.meters(start, ordered.first);
      setState(() {
        _plan = RoutePlan(plan.order, line, plan.legMeters, plan.legSeconds, road);
        _lineNow = RoutePlanner.ahead(line, start);
        _planKeys = keys;
        _planSig = sig;
        _planAt = DateTime.now();
        _planFrom = start;
      });
    } finally {
      _planning = false;
    }
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
            child: Row(children: [
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
          ),
        ),
      );

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
          _map.fitCamera(CameraFit.coordinates(
            coordinates: pts,
            maxZoom: 17,
            padding: EdgeInsets.fromLTRB(40, 70, 70, MediaQuery.of(context).size.height * 0.25),
          ));
        });
      }
    }
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: center,
          initialZoom: 16,
          // The map has street detail up to zoom 15 and is drawn larger up to 18; closer than
          // that it would go blank, and Qatar fits in zoom 8.
          minZoom: 8,
          maxZoom: 18,
          // North always up: no two-finger rotating, which left the map turned with no way back.
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          onMapReady: () => setState(() => _mapReady = true),
          onPositionChanged: (camera, hasGesture) {
            if (hasGesture && _follow) setState(() => _follow = false);
          },
        ),
        children: [
          _tiles ?? const ColoredBox(color: Color(0xFFF2F0EB), child: SizedBox.expand()),
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
          const Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Text('© OpenStreetMap', style: TextStyle(fontSize: 9, color: Color(0xFF64748B))),
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
            Icon(_trackerFresh ? Icons.directions_bus_rounded : Icons.smartphone_rounded, size: 15,
                color: _trackerFresh ? MonitorColors.green : MonitorColors.amber),
            const SizedBox(width: 6),
            Flexible(child: Text(_sourceLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
            if (_plan != null && !_plan!.road) ...[
              const SizedBox(width: 8),
              const Text('· estimated route', style: TextStyle(fontSize: 11.5, color: MonitorColors.muted)),
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
            if (f != null && _mapReady) _map.moveAndRotate(f.pos, math.max(_map.camera.zoom, 16), 0);
          }, on: _follow),
          const SizedBox(height: 10),
          _fab(Icons.format_list_numbered_rounded, 'All stops', () {
            if (_sheet.isAttached) _sheet.animateTo(0.85, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
          }),
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
      DraggableScrollableSheet(
        controller: _sheet,
        initialChildSize: 0.22,
        minChildSize: 0.14,
        maxChildSize: 0.88,
        snap: true,
        snapSizes: const [0.22, 0.48],
        builder: (context, scroll) => DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, -2))],
          ),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
            children: [
              Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: MonitorColors.line, borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 8),
              if (next == null) _allDone(w) else ...[
                _stopHeader(next, w, etas),
                const SizedBox(height: 8),
                _chips(next, w),
                const SizedBox(height: 12),
                _stopTools(next),
                const Divider(height: 24, color: MonitorColors.line),
                ..._kidRows(next, w),
              ],
              const SizedBox(height: 14),
              const SectionTitle('All stops'),
              const SizedBox(height: 6),
              ..._compactStops(stops, next, w, etas),
            ],
          ),
        ),
      ),
    ]);
  }

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
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  Icon(_trackerFresh ? Icons.directions_bus_rounded : Icons.smartphone_rounded, size: 15,
                      color: _trackerFresh ? MonitorColors.green : MonitorColors.amber),
                  const SizedBox(width: 6),
                  Expanded(child: Text(_sourceLabel, style: const TextStyle(fontSize: 12, color: MonitorColors.muted, fontWeight: FontWeight.w600))),
                ]),
              ),
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
    if (!_listMode && _sheet.isAttached) _sheet.animateTo(0.48, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  Widget _stopHeader(_Stop s, ShiftWindow w, Map<String, DateTime> etas) {
    final idx = _planKeys.indexOf(s.key);
    final reach = _reach(etas, s);
    return Row(children: [
      Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: w.color, shape: BoxShape.circle),
        child: s.school
            ? const Icon(Icons.school_rounded, size: 17, color: Colors.white)
            : Text(idx >= 0 ? '${idx + 1}' : '•', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          Text(s.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: MonitorColors.muted)),
        ]),
      ),
      const SizedBox(width: 8),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (reach.isNotEmpty) Text(reach, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: w.color)),
        Text(_away(s), style: const TextStyle(fontSize: 12, color: MonitorColors.muted)),
      ]),
    ]);
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

  Widget _chips(_Stop s, ShiftWindow w) {
    final actions = MonitorActions(context, store);
    if (s.kids.isEmpty) return const Text('Nobody to mark here.', style: TextStyle(color: MonitorColors.muted));
    final main = _mainKids(s, w);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final k in s.kids)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Builder(builder: (_) {
              final a = _action(k, s, w);
              final first = '${k['name'] ?? ''}'.split(' ').first;
              if (a == null) {
                final ev = store.eventOf(k, w.key);
                return StatusPill(text: '$first · ${StatusStyle.label(ev, w.key)}', color: StatusStyle.color(ev), icon: StatusStyle.icon(ev));
              }
              return ActionChip(
                onPressed: () => actions.mark(w, k, a.$2),
                backgroundColor: a.$3,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                avatar: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                label: Text(a.$2 == 'leave' || a.$2 == 'by_parent' ? '$first · leave' : first,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              );
            }),
          ),
        if (main.length >= 2)
          ActionChip(
            onPressed: () => actions.markMany(w, main, _mainType(s, w), _mainTitle(s, w)),
            backgroundColor: MonitorColors.green,
            side: BorderSide.none,
            shape: const StadiumBorder(),
            avatar: const Icon(Icons.done_all_rounded, size: 16, color: Colors.white),
            label: Text('All ${main.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }

  Widget _stopTools(_Stop s) {
    final actions = MonitorActions(context, store);
    final f = s.family;
    Widget tool(IconData i, String t, VoidCallback? onTap) => Expanded(
          child: OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(i, size: 17),
            label: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(
              foregroundColor: MonitorColors.navy,
              side: const BorderSide(color: MonitorColors.line),
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
    return [
      for (final k in s.kids)
        Padding(
          padding: const EdgeInsets.only(bottom: 8, right: 6),
          child: Row(children: [
            Initials(name: '${k['name'] ?? '?'}', size: 34, color: w.color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${k['name'] ?? 'Student'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                if (store.noticeFor(k, w.key) != null)
                  Text('Leave: ${store.noticeOf(k)?['summary'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: MonitorColors.byParent, fontWeight: FontWeight.w600))
                else
                  Text(StatusStyle.label(store.eventOf(k, w.key), w.key), style: const TextStyle(fontSize: 12, color: MonitorColors.muted)),
              ]),
            ),
            Builder(builder: (_) {
              final a = _action(k, s, w);
              if (a == null) return Icon(StatusStyle.icon(store.eventOf(k, w.key)), color: StatusStyle.color(store.eventOf(k, w.key)));
              return Row(mainAxisSize: MainAxisSize.min, children: [
                FilledButton(
                  onPressed: () => actions.mark(w, k, a.$2),
                  style: FilledButton.styleFrom(backgroundColor: a.$3, visualDensity: VisualDensity.compact),
                  child: Text(a.$1),
                ),
                if (a.$2 == 'pickup') ...[
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: () => actions.notTravelling(w, k),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: const Color(0xFF475569)),
                    child: const Text('Absent'),
                  ),
                ],
              ]);
            }),
          ]),
        ),
    ];
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
