import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// The order to visit the remaining stops in, and the line to draw.
class RoutePlan {
  /// Indexes into the stops passed in, in visiting order.
  final List<int> order;

  /// The route to draw: along the roads when [road] is true, straight lines between stops otherwise.
  final List<LatLng> line;

  /// Per leg, in visiting order: metres and seconds. Leg 0 is from the start to the first stop.
  final List<double> legMeters;
  final List<double> legSeconds;

  /// True when this came from the road routing service; false for the on-phone estimate.
  final bool road;

  const RoutePlan(this.order, this.line, this.legMeters, this.legSeconds, this.road);
}

/// Plans the shortest drive through the remaining stops.
///
/// First choice: the public OSRM routing service (the same one the parents' tracking map uses) - the
/// real shortest DRIVING order and a line that follows the roads. It is a free demonstration
/// service, so it is used gently: the route page asks for a plan only when something has changed (a
/// stop done, a different stop reached) or at most once a minute while driving, and gives up after
/// a few seconds. Whenever it does not answer, the plan is worked out on the phone instead from
/// straight-line distances, so the page never stops working.
class RoutePlanner {
  static const _base = 'https://router.project-osrm.org';
  static const _timeout = Duration(seconds: 6);
  static const _maxRoadStops = 40; // beyond this the URL gets long; plan on the phone instead

  static const _dist = Distance();
  static double meters(LatLng a, LatLng b) => _dist.as(LengthUnit.Meter, a, b);

  /// [start] is where the bus is now; [stops] the stops still to visit; [end], when given, must be
  /// last (the school, in the morning).
  static Future<RoutePlan> plan(LatLng start, List<LatLng> stops, {LatLng? end}) async {
    if (stops.isEmpty && end == null) return const RoutePlan([], [], [], [], false);
    if (stops.length <= _maxRoadStops) {
      try {
        final p = await _road(start, stops, end);
        if (p != null) return p;
      } catch (_) {
        // Offline, slow, or the service said no: fall through to the on-phone plan.
      }
    }
    return local(start, stops, end: end);
  }

  /// OSRM "trip": the optimised order. With a fixed end it is an open trip start -> ... -> end; without
  /// one OSRM only optimises round trips, so the return leg to the start is simply dropped.
  static Future<RoutePlan?> _road(LatLng start, List<LatLng> stops, LatLng? end) async {
    final pts = [start, ...stops, if (end != null) end];
    final coords = pts.map((p) => '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)}').join(';');
    final q = end != null ? 'roundtrip=false&source=first&destination=last' : 'roundtrip=true&source=first';
    final uri = Uri.parse('$_base/trip/v1/driving/$coords?$q&overview=full&geometries=geojson');
    final r = await http.get(uri, headers: {'User-Agent': 'SmartStepSchoolBus/1.1 (school transport app)'}).timeout(_timeout);
    if (r.statusCode != 200) return null;
    final data = jsonDecode(r.body);
    if (data is! Map || data['code'] != 'Ok') return null;
    final trips = data['trips'] as List?;
    final wps = data['waypoints'] as List?;
    if (trips == null || trips.isEmpty || wps == null || wps.length != pts.length) return null;

    // waypoints are in INPUT order; waypoint_index is each one's position in the trip.
    final pos = List<int>.generate(pts.length, (i) => (wps[i]['waypoint_index'] as num).toInt());
    final byTrip = List<int>.generate(pts.length, (i) => i)..sort((a, b) => pos[a].compareTo(pos[b]));
    // byTrip[0] is the start (input 0); stops are inputs 1..stops.length; the end, if any, is last.
    final order = <int>[
      for (final i in byTrip)
        if (i >= 1 && i <= stops.length) i - 1,
    ];

    final trip = trips[0];
    final legs = (trip['legs'] as List?) ?? const [];
    final legM = <double>[for (final l in legs) ((l['distance'] as num?) ?? 0).toDouble()];
    final legS = <double>[for (final l in legs) ((l['duration'] as num?) ?? 0).toDouble()];
    var line = <LatLng>[
      for (final c in (trip['geometry']?['coordinates'] as List? ?? const []))
        LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
    ];
    if (end == null && legM.length > order.length) {
      // Round trip: cut the line where the last stop is reached, and drop the leg home.
      final last = stops[order.last];
      var cut = line.length - 1;
      var best = double.infinity;
      for (var i = line.length ~/ 3; i < line.length; i++) {
        final d = meters(line[i], last);
        if (d < best) {
          best = d;
          cut = i;
        }
      }
      line = line.sublist(0, cut + 1);
      legM.removeLast();
      legS.removeLast();
    }
    return RoutePlan(order, line, legM, legS, true);
  }

  /// The road route through [pts] in exactly this order (OSRM "route"): the line along the roads and
  /// each leg's metres and seconds. Null when the service does not answer. Used once the order is
  /// known, so the whole way - from the bus to the next stop, and on - follows the roads.
  static Future<RoutePlan?> roadPath(List<LatLng> pts) async {
    if (pts.length < 2 || pts.length > _maxRoadStops + 2) return null;
    try {
      final coords = pts.map((p) => '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)}').join(';');
      final uri = Uri.parse('$_base/route/v1/driving/$coords?overview=full&geometries=geojson');
      final r = await http.get(uri, headers: {'User-Agent': 'SmartStepSchoolBus/1.1 (school transport app)'}).timeout(_timeout);
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body);
      if (data is! Map || data['code'] != 'Ok') return null;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;
      final route = routes[0];
      final legs = (route['legs'] as List?) ?? const [];
      if (legs.length != pts.length - 1) return null;
      return RoutePlan(
        List<int>.generate(pts.length - 1, (i) => i),
        [
          for (final c in (route['geometry']?['coordinates'] as List? ?? const []))
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
        ],
        [for (final l in legs) ((l['distance'] as num?) ?? 0).toDouble()],
        [for (final l in legs) ((l['duration'] as num?) ?? 0).toDouble()],
        true,
      );
    } catch (_) {
      return null;
    }
  }

  /// The part of [line] still ahead of [at]: everything before the point of the line nearest to the
  /// bus is cut off, and the line starts at the bus. Only the first stretch is searched, so a route
  /// that later passes the same place again is not cut short.
  static List<LatLng> ahead(List<LatLng> line, LatLng at) {
    if (line.length < 3) return line;
    final searchTo = math.min(line.length - 1, math.max(40, line.length ~/ 3));
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < searchTo; i++) {
      final d = meters(line[i], at);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (bestD > 250) return line; // the bus is off the planned line - keep it until the next re-plan
    return [at, ...line.sublist(best + 1)];
  }

  /// On-phone plan: nearest stop next, then 2-opt to untangle crossings. Good to a few percent on
  /// school-bus sized routes, instant, and works with no signal.
  static RoutePlan local(LatLng start, List<LatLng> stops, {LatLng? end}) {
    final n = stops.length;
    final left = List<int>.generate(n, (i) => i);
    final order = <int>[];
    var at = start;
    while (left.isNotEmpty) {
      left.sort((a, b) => meters(at, stops[a]).compareTo(meters(at, stops[b])));
      final next = left.removeAt(0);
      order.add(next);
      at = stops[next];
    }

    double pathLen(List<int> o) {
      var d = 0.0;
      var p = start;
      for (final i in o) {
        d += meters(p, stops[i]);
        p = stops[i];
      }
      if (end != null) d += meters(p, end);
      return d;
    }

    // 2-opt: reverse any stretch whose reversal shortens the whole path.
    var improved = true;
    var guard = 0;
    while (improved && guard++ < 50) {
      improved = false;
      for (var i = 0; i < n - 1; i++) {
        for (var k = i + 1; k < n; k++) {
          final cand = [...order.sublist(0, i), ...order.sublist(i, k + 1).reversed, ...order.sublist(k + 1)];
          if (pathLen(cand) + 1 < pathLen(order)) {
            order
              ..clear()
              ..addAll(cand);
            improved = true;
          }
        }
      }
    }

    // Straight lines, with a road-ish allowance: real driving is ~30% longer, at ~28 km/h in town.
    final line = <LatLng>[start, for (final i in order) stops[i], if (end != null) end];
    final legM = <double>[];
    for (var i = 1; i < line.length; i++) {
      legM.add(meters(line[i - 1], line[i]) * 1.3);
    }
    final legS = [for (final m in legM) m / (28 / 3.6)];
    return RoutePlan(order, line, legM, legS, false);
  }

  /// Compass bearing from a to b, degrees clockwise from north.
  static double bearing(LatLng a, LatLng b) {
    final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
    final dLo = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dLo) * math.cos(la2);
    final x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dLo);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}
