import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import '../../services/api_service.dart';
import '../../services/offline_map.dart';
import 'monitor_actions.dart';
import 'monitor_store.dart';
import 'monitor_widgets.dart';
import 'route_planner.dart';

/// The Route tab: a live map of the shift - where the bus is, every stop in the best order, the next
/// one highlighted - and a small panel at the bottom to mark the children at the stop she is at.
///
/// - Stops whose children are all on leave for this trip are greyed out and left off the route.
/// - The order is the shortest drive (RoutePlanner), and is re-worked when a stop is done, when she
///   goes to a different stop than planned, or every minute while driving.
/// - Arriving within [_arriveM] of any stop opens it, so she can go in whatever order she likes.
/// - The bus arrow glides between GPS fixes at the screen's refresh rate; only that layer redraws.
/// - GPS runs only while this tab is showing and a shift is open.
class MonitorRouteView extends StatefulWidget {
  final MonitorStore store;
  final bool active;
  const MonitorRouteView({super.key, required this.store, required this.active});

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
  static const _doha = LatLng(25.2854, 51.5310);

  final _map = MapController();
  final _sheet = DraggableScrollableController();
  Widget? _tiles;
  bool _mapReady = false;
  bool _fitted = false; // the whole route shown once, before the first GPS fix arrives

  // ---- position -----------------------------------------------------------------------------------
  StreamSubscription<Position>? _gps;
  Timer? _trackerPoll;
  LatLng? _pos; // latest real fix
  double _heading = 0;
  bool _usingTracker = false;
  String? _gpsProblem;
  final ValueNotifier<_Fix?> _shown = ValueNotifier(null); // the animated arrow
  late final AnimationController _glide;
  LatLng? _glideFrom, _glideTo;
  double _headFrom = 0, _headTo = 0;
  bool _follow = true;

  // ---- route --------------------------------------------------------------------------------------
  RoutePlan? _plan;
  List<String> _planKeys = []; // stop keys in planned order
  String _planSig = '';
  DateTime _planAt = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _planFrom;
  bool _planning = false;
  String? _activeKey; // the stop she is at, or chose
  final Set<String> _skipped = {};
  String? _banner;
  Timer? _bannerTimer;

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

  // ---------------------------------------------------------------------------------------- tracking

  void _syncTracking() {
    final want = widget.active && _shift != null;
    if (want && _gps == null && _trackerPoll == null) {
      _startTracking();
    } else if (!want && (_gps != null || _trackerPoll != null)) {
      _stopTracking();
    }
  }

  Future<void> _startTracking() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'Location is turned off';
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw 'Location permission denied';
      if (!mounted || !widget.active) return;
      _gps = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 2),
      ).listen((p) {
        final speed = p.speed; // m/s
        final heading = (speed > 1.2 && p.heading >= 0) ? p.heading : null;
        _onFix(LatLng(p.latitude, p.longitude), heading);
      }, onError: (Object e) => _useTracker('$e'));
      setState(() => _gpsProblem = null);
    } catch (e) {
      _useTracker('$e');
    }
  }

  /// No phone GPS: show the bus's own tracker instead, every 10 seconds.
  void _useTracker(String why) {
    _gps?.cancel();
    _gps = null;
    if (!mounted) return;
    setState(() {
      _gpsProblem = why;
      _usingTracker = true;
    });
    if (store.busDeviceId <= 0 || _trackerPoll != null) return;
    Future<void> poll() async {
      try {
        final r = await ApiService.getBusLocation(store.busDeviceId);
        final loc = r['location'] ?? r['last_known_location'];
        if (loc is Map && loc['lat'] != null && loc['lng'] != null) {
          _onFix(LatLng((loc['lat'] as num).toDouble(), (loc['lng'] as num).toDouble()), null);
        }
      } catch (_) {/* try again next tick */}
    }

    poll();
    _trackerPoll = Timer.periodic(const Duration(seconds: 10), (_) => poll());
  }

  void _stopTracking() {
    _gps?.cancel();
    _gps = null;
    _trackerPoll?.cancel();
    _trackerPoll = null;
  }

  void _onFix(LatLng p, double? heading) {
    if (!mounted) return;
    final prev = _pos;
    _pos = p;
    if (heading != null) {
      _heading = heading;
    } else if (prev != null && RoutePlanner.meters(prev, p) > 8) {
      _heading = RoutePlanner.bearing(prev, p);
    }
    // Glide from where the arrow is drawn now to the new fix over about the time until the next one.
    final cur = _shown.value;
    _glideFrom = cur?.pos ?? p;
    _glideTo = p;
    _headFrom = cur?.heading ?? _heading;
    _headTo = _heading;
    _glide.forward(from: 0);

    _checkArrival(p);
    _maybePlan();
    if (prev == null && mounted) setState(() {}); // first fix: distances appear
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
    if (_follow && _mapReady) {
      // Heading up, a little ahead of the bus, at whatever zoom she chose.
      _map.moveAndRotate(pos, _map.camera.zoom, -head);
    }
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
      out.add(_Stop('school', store.schoolName, needs.isEmpty ? 'Everyone has boarded' : '${needs.length} to board',
          sp, null, atSchool, needs.isEmpty ? _St.done : _St.todo, school: true));
    }

    for (final f in store.families(shift)) {
      final waiting = f.students.where((s) => store.stageOf(s, shift) == Stage.waiting).toList();
      final onBus = f.students.where((s) => store.stageOf(s, shift) == Stage.onBus).toList();
      // Every child here is on leave for this trip and nobody has been marked: not a stop at all.
      final allLeave = f.students.every((s) => _hasNotice(s, shift) && store.stageOf(s, shift) == Stage.waiting);
      final _St st;
      if (morning) {
        // A stop to make while a child is still to be picked up (leave children are not).
        final need = waiting.where((s) => !_hasNotice(s, shift)).length;
        st = need > 0 ? _St.todo : (allLeave ? _St.leave : _St.done);
      } else {
        // In the evening, a stop to make while a child is on the bus to be dropped there.
        st = onBus.isNotEmpty ? _St.todo : (allLeave ? _St.leave : _St.done);
      }
      final pt = f.hasCoords ? LatLng(double.parse('${f.stopLat}'), double.parse('${f.stopLng}')) : null;
      out.add(_Stop(f.key, f.parentName, f.address, pt, f, f.students, st));
    }

    // Morning: everyone gets off at school, last.
    if (morning) {
      final onBus = store.students.where((s) => store.stageOf(s, shift) == Stage.onBus).toList();
      final homesLeft = out.any((s) => s.state == _St.todo);
      out.add(_Stop('school', store.schoolName, onBus.isEmpty ? (homesLeft ? 'Drop everyone here' : 'Everyone is at school') : '${onBus.length} on the bus',
          sp, null, onBus, (onBus.isEmpty && !homesLeft) ? _St.done : _St.todo, school: true));
    }
    return out;
  }

  /// The stop to deal with now: the one she is at or chose, else the first in the planned order.
  _Stop? _next(List<_Stop> stops) {
    final todo = {for (final s in stops) if (s.state == _St.todo) s.key: s};
    if (_activeKey != null && todo.containsKey(_activeKey)) return todo[_activeKey];
    for (final k in _planKeys) {
      if (todo.containsKey(k) && !_skipped.contains(k)) return todo[k];
    }
    for (final k in _planKeys) {
      if (todo.containsKey(k)) return todo[k];
    }
    // Not planned yet (or no location): the morning school stop only once homes are done.
    final homes = todo.values.where((s) => !s.school).toList();
    if (homes.isNotEmpty) return homes.first;
    return todo.values.isEmpty ? null : todo.values.first;
  }

  void _checkArrival(LatLng p) {
    final w = _shift;
    if (w == null) return;
    final stops = _stops(w).where((s) => s.state == _St.todo && s.point != null).toList();
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
    final planned = _next(_stops(w));
    setState(() => _activeKey = hit!.key);
    if (planned != null && planned.key != hit.key) {
      _say('Route updated - you are at ${hit.title}.');
      _planSig = ''; // re-plan from here
    }
    if (_sheet.isAttached && _sheet.size < 0.3) {
      _sheet.animateTo(0.42, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
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
    final start = _pos ?? (store.schoolLat != null ? LatLng(store.schoolLat!, store.schoolLng!) : null);
    if (start == null) return;
    final stops = _stops(w);
    final todo = stops.where((s) => s.state == _St.todo && s.point != null).toList();
    final sig = '${w.key}|${todo.map((s) => s.key).join(',')}|$_activeKey';
    final moved = _planFrom == null ? 1e9 : RoutePlanner.meters(_planFrom!, start);
    final age = DateTime.now().difference(_planAt);
    final stale = sig != _planSig || (age > const Duration(seconds: 60) && moved > 300);
    if (!stale || (sig == _planSig && age < const Duration(seconds: 15))) return;

    _planning = true;
    try {
      // The morning ends at school; the evening starts there, so a waiting school stop goes first.
      final schoolStop = todo.where((s) => s.school).toList();
      final homes = todo.where((s) => !s.school).toList();
      final first = _activeKey == null ? null : homes.where((s) => s.key == _activeKey).firstOrNull;
      final rest = homes.where((s) => s != first).toList();
      LatLng from = start;
      final lead = <_Stop>[];
      if (!w.isMorning && schoolStop.isNotEmpty) lead.add(schoolStop.first);
      if (first != null) lead.add(first);
      if (lead.isNotEmpty) from = lead.last.point!;
      final end = w.isMorning && schoolStop.isNotEmpty ? schoolStop.first.point : null;

      final plan = await RoutePlanner.plan(from, [for (final s in rest) s.point!], end: end);
      if (!mounted) return;
      final keys = [...lead.map((s) => s.key), for (final i in plan.order) rest[i].key, if (end != null) schoolStop.first.key];
      final line = [start, for (final s in lead) s.point!, ...plan.line];
      setState(() {
        _plan = RoutePlan(plan.order, line, plan.legMeters, plan.legSeconds, plan.road);
        _planKeys = keys;
        _planSig = sig;
        _planAt = DateTime.now();
        _planFrom = start;
      });
    } finally {
      _planning = false;
    }
  }

  // ---------------------------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final w = _shift;
    if (w == null) return _closed();
    final stops = _stops(w);
    final next = _next(stops);
    if (_planSig.isEmpty || !stops.any((s) => s.key == next?.key)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybePlan());
    }
    final done = stops.where((s) => !s.school && s.state == _St.done).length;
    final homes = stops.where((s) => !s.school && s.state != _St.leave).length;
    final center = _pos ?? stops.firstWhere((s) => s.point != null, orElse: () => _Stop('', '', '', _doha, null, const [], _St.todo)).point!;
    // Until the bus's position is known, show the whole route rather than one stop.
    if (!_fitted && _pos == null && _mapReady) {
      final pts = [for (final s in stops) if (s.point != null && s.state != _St.done) s.point!];
      if (pts.length > 1) {
        _fitted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _map.fitCamera(CameraFit.coordinates(
            coordinates: pts,
            padding: EdgeInsets.fromLTRB(40, MediaQuery.of(context).padding.top + 70, 70, MediaQuery.of(context).size.height * 0.25),
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
          onMapReady: () => setState(() => _mapReady = true),
          onPositionChanged: (camera, hasGesture) {
            if (hasGesture && _follow) setState(() => _follow = false);
          },
        ),
        children: [
          _tiles ?? const ColoredBox(color: Color(0xFFF2F0EB), child: SizedBox.expand()),
          if (_plan != null && _plan!.line.length > 1)
            PolylineLayer(polylines: [
              Polyline(points: _plan!.line, strokeWidth: 6, color: w.color.withValues(alpha: 0.85), borderStrokeWidth: 2, borderColor: Colors.white),
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
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.fromLTRB(8, 56, 8, 8),
              child: Text('© OpenStreetMap', style: TextStyle(fontSize: 9, color: Color(0xFF64748B))),
            ),
          ),
        ],
      ),

      // Top: the shift and progress, and the clock.
      Positioned(
        top: MediaQuery.of(context).padding.top + 10,
        left: 12,
        right: 12,
        child: Row(children: [
          _glass(Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(w.icon, size: 16, color: w.color),
            const SizedBox(width: 6),
            Text('${w.name} · $done of $homes stops', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ])),
          const Spacer(),
          if (_plan != null && !_plan!.road)
            _glass(const Text('Estimated route', style: TextStyle(fontSize: 11.5, color: MonitorColors.muted))),
        ]),
      ),
      Positioned(
        right: 12,
        top: MediaQuery.of(context).padding.top + 58,
        child: Column(children: [
          _fab(_follow ? Icons.navigation_rounded : Icons.navigation_outlined, _follow ? 'Following' : 'Follow the bus', () {
            setState(() => _follow = true);
            final f = _shown.value;
            if (f != null && _mapReady) _map.moveAndRotate(f.pos, math.max(_map.camera.zoom, 16), -f.heading);
          }, on: _follow),
          const SizedBox(height: 10),
          _fab(Icons.format_list_numbered_rounded, 'All stops', () {
            if (_sheet.isAttached) _sheet.animateTo(0.85, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
          }),
        ]),
      ),
      if (_banner != null || _gpsProblem != null)
        Positioned(
          top: MediaQuery.of(context).padding.top + 58,
          left: 12,
          right: 64,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: MonitorColors.navy, borderRadius: BorderRadius.circular(12)),
            child: Text(
              _banner ?? (_usingTracker ? 'Phone location is off - showing the bus tracker instead.' : 'Waiting for location…'),
              style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ),

      DraggableScrollableSheet(
        controller: _sheet,
        initialChildSize: 0.2,
        minChildSize: 0.13,
        maxChildSize: 0.88,
        snap: true,
        snapSizes: const [0.2, 0.45],
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
              Center(
                child: Container(width: 38, height: 4, decoration: BoxDecoration(color: MonitorColors.line, borderRadius: BorderRadius.circular(4))),
              ),
              const SizedBox(height: 8),
              if (next == null) _allDone(w) else ...[
                _stopHeader(next, w, stops),
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
              ..._allStops(stops, next),
            ],
          ),
        ),
      ),
    ]);
  }

  // ---------------------------------------------------------------------------------------- pieces

  Widget _closed() {
    final f = store.focus;
    final text = f == null
        ? 'The route opens with the shift.'
        : f.state == 'upcoming'
            ? 'The ${f.name.toLowerCase()} route opens at ${fmtTime(f.opensAt)}.'
            : 'Today\'s shifts are over. See you tomorrow.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const IconTile(icon: Icons.route_rounded, color: MonitorColors.navy, size: 64),
          const SizedBox(height: 14),
          const Text('Route', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: MonitorColors.muted)),
        ]),
      ),
    );
  }

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
    if (_sheet.isAttached) _sheet.animateTo(0.45, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  String _away(_Stop s) {
    if (s.point == null) return 'No location saved';
    final p = _pos;
    if (p == null) return '';
    final m = RoutePlanner.meters(p, s.point!);
    if (m < _arriveM) return 'You are here';
    // Road distance is roughly 1.3 x straight; town speed from the plan when there is one.
    final road = m * 1.3;
    double mps = 28 / 3.6;
    if (_plan != null && _plan!.legMeters.isNotEmpty && _plan!.legSeconds.first > 0) {
      mps = (_plan!.legMeters.first / _plan!.legSeconds.first).clamp(4.0, 20.0);
    }
    final min = (road / mps / 60).ceil();
    final dist = road < 1000 ? '${(road / 10).round() * 10} m' : '${(road / 1000).toStringAsFixed(1)} km';
    return '$dist · $min min';
  }

  Widget _stopHeader(_Stop s, ShiftWindow w, List<_Stop> stops) {
    final idx = _planKeys.indexOf(s.key);
    return Row(children: [
      Container(
        width: 30,
        height: 30,
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
      Text(_away(s), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: w.color)),
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

  Widget _chips(_Stop s, ShiftWindow w) {
    final actions = MonitorActions(context, store);
    final kids = s.kids;
    if (kids.isEmpty) return const Text('Nobody to mark here.', style: TextStyle(color: MonitorColors.muted));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final k in kids)
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
                _say('${s.title} skipped for now - it stays in the list.');
              })),
    ]);
  }

  List<Widget> _kidRows(_Stop s, ShiftWindow w) {
    final actions = MonitorActions(context, store);
    return [
      for (final k in s.kids)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
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
              if (a == null) return const Icon(Icons.check_circle_rounded, color: MonitorColors.green);
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

  List<Widget> _allStops(List<_Stop> stops, _Stop? next) {
    final ordered = [
      for (final k in _planKeys) ...stops.where((s) => s.key == k),
      ...stops.where((s) => !_planKeys.contains(s.key) && s.state == _St.todo),
      ...stops.where((s) => !_planKeys.contains(s.key) && s.state != _St.todo),
    ];
    return [
      for (final s in ordered)
        InkWell(
          onTap: () => _choose(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              SizedBox(width: 34, height: 34, child: _pin(s, next, _shift!)),
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
                            if (s.state == _St.todo) _away(s),
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
  }

  Widget _allDone(ShiftWindow w) => Row(children: [
        const Icon(Icons.task_alt_rounded, color: MonitorColors.green),
        const SizedBox(width: 10),
        Expanded(
          child: Text('${w.name} route complete - every child is accounted for.',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ]);
}
