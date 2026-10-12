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

/// Plans the drive through the remaining stops.
///
/// The ORDER: the shortest ONE-WAY drive that starts where the bus is now - so the nearby stops come
/// first and the far ones last. The bus never has to come back to where it started, so the order is
/// not judged by a return leg. (It used to ask the routing service for a ROUND trip and drop the way
/// back; a round trip is just as short driven either way round, so it often went out to the farthest
/// stop first and came back through the near ones.)
///
/// The cost of each leg is the real DRIVING time between the two points, from the public OSRM
/// routing service (one "table" request for all of them), so a stop across a highway is not taken
/// for "near". The order itself is worked out on the phone (nearest first, then 2-opt and moving
/// single stops until nothing improves - exact enough for school-bus sized routes, and instant).
/// Without network the same is done with straight-line distances, so the page never stops working.
/// The school is not part of the order: it is first in the evening and last in the morning anyway.
class RoutePlanner {
  static const _base = 'https://router.project-osrm.org';
  static const _timeout = Duration(seconds: 6);
  static const _maxRoadStops = 40; // beyond this the URL gets long; plan on the phone instead

  static const _dist = Distance();
  static double meters(LatLng a, LatLng b) => _dist.as(LengthUnit.Meter, a, b);

  /// [start] is where the bus is now; [stops] the stops still to visit. [end] (the school in the
  /// morning) only adds its leg to the times - it does not change the order.
  /// [road] false: straight lines only, no network - an instant first answer (the road plan follows).
  static Future<RoutePlan> plan(LatLng start, List<LatLng> stops, {LatLng? end, bool road = true}) async {
    if (stops.isEmpty && end == null) return const RoutePlan([], [], [], [], false);
    final pts = [start, ...stops, if (end != null) end];
    _Matrix? m;
    if (road && stops.length > 1 && pts.length <= _maxRoadStops + 2) {
      try {
        m = await _table(pts);
      } catch (_) {
        // Offline, slow, or the service said no: straight lines below.
      }
    }
    final roadTimes = m != null;
    m ??= _straight(pts);
    final order = _solve(m.sec, stops.length);
    final seq = [0, for (final i in order) i + 1, if (end != null) pts.length - 1];
    final legM = <double>[for (var i = 1; i < seq.length; i++) m.m[seq[i - 1]][seq[i]]];
    final legS = <double>[for (var i = 1; i < seq.length; i++) m.sec[seq[i - 1]][seq[i]]];
    return RoutePlan(order, [for (final i in seq) pts[i]], legM, legS, roadTimes);
  }

  /// Driving seconds and metres between every pair of points (OSRM "table"). A pair the service
  /// cannot route falls back to the straight-line estimate.
  static Future<_Matrix?> _table(List<LatLng> pts) async {
    final coords = pts.map((p) => '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)}').join(';');
    final uri = Uri.parse('$_base/table/v1/driving/$coords?annotations=duration,distance');
    final r = await http.get(uri, headers: {'User-Agent': 'SmartStepSchoolBus/1.1 (school transport app)'}).timeout(_timeout);
    if (r.statusCode != 200) return null;
    final data = jsonDecode(r.body);
    if (data is! Map || data['code'] != 'Ok') return null;
    final dur = data['durations'] as List?;
    final dis = data['distances'] as List?;
    if (dur == null || dur.length != pts.length) return null;
    final est = _straight(pts);
    final sec = List.generate(pts.length, (i) => List<double>.filled(pts.length, 0));
    final mm = List.generate(pts.length, (i) => List<double>.filled(pts.length, 0));
    for (var i = 0; i < pts.length; i++) {
      for (var j = 0; j < pts.length; j++) {
        final s = (dur[i] as List?)?[j];
        final d = dis == null ? null : (dis[i] as List?)?[j];
        sec[i][j] = s is num ? s.toDouble() : est.sec[i][j];
        mm[i][j] = d is num ? d.toDouble() : est.m[i][j];
      }
    }
    return _Matrix(sec, mm);
  }

  /// Straight lines with a road-ish allowance: real driving is ~30% longer, at ~28 km/h in town.
  static _Matrix _straight(List<LatLng> pts) {
    final mm = List.generate(pts.length, (i) => List.generate(pts.length, (j) => meters(pts[i], pts[j]) * 1.3));
    final sec = [for (final row in mm) [for (final v in row) v / (28 / 3.6)]];
    return _Matrix(sec, mm);
  }

  /// The shortest open path 0 -> every stop (1..n), in any order, ending anywhere.
  static List<int> _solve(List<List<double>> c, int n) {
    if (n == 0) return [];
    double cost(List<int> o) {
      var t = 0.0, p = 0;
      for (final i in o) {
        t += c[p][i + 1];
        p = i + 1;
      }
      return t;
    }

    // Nearest first.
    final left = List<int>.generate(n, (i) => i);
    final order = <int>[];
    var at = 0;
    while (left.isNotEmpty) {
      left.sort((a, b) => c[at][a + 1].compareTo(c[at][b + 1]));
      final next = left.removeAt(0);
      order.add(next);
      at = next + 1;
    }
    // Improve: reverse a stretch (2-opt), or move one stop elsewhere (or-opt), while it shortens the drive.
    var best = cost(order);
    var improved = true;
    var guard = 0;
    while (improved && guard++ < 60) {
      improved = false;
      for (var i = 0; i < n - 1; i++) {
        for (var k = i + 1; k < n; k++) {
          final cand = [...order.sublist(0, i), ...order.sublist(i, k + 1).reversed, ...order.sublist(k + 1)];
          final cc = cost(cand);
          if (cc + 0.5 < best) {
            order
              ..clear()
              ..addAll(cand);
            best = cc;
            improved = true;
          }
        }
      }
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          if (i == j) continue;
          final cand = [...order];
          final v = cand.removeAt(i);
          cand.insert(j, v);
          final cc = cost(cand);
          if (cc + 0.5 < best) {
            order
              ..clear()
              ..addAll(cand);
            best = cc;
            improved = true;
          }
        }
      }
    }
    return order;
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

  /// Compass bearing from a to b, degrees clockwise from north.
  static double bearing(LatLng a, LatLng b) {
    final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
    final dLo = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dLo) * math.cos(la2);
    final x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dLo);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}

class _Matrix {
  final List<List<double>> sec; // driving seconds [from][to]
  final List<List<double>> m; // driving metres [from][to]
  const _Matrix(this.sec, this.m);
}

/// Where along the route a point is: metres from the start of the line, and how far it is off it.
class RouteSpot {
  final double along;
  final double off;
  final LatLng point; // the nearest point ON the line
  const RouteSpot(this.along, this.off, this.point);
}

/// The planned road line, measured, so the bus can be put ON it and followed along it - the way
/// navigation apps show a vehicle: the bus moves along the road, the part already driven disappears,
/// and leaving the road is noticed (to plan again from where the bus really is).
class RouteLine {
  final List<LatLng> pts;
  late final List<double> _cum; // metres from the start to each point

  RouteLine(this.pts) {
    _cum = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      _cum[i] = _cum[i - 1] + RoutePlanner.meters(pts[i - 1], pts[i]);
    }
  }

  double get length => pts.isEmpty ? 0 : _cum.last;

  /// The nearest point of the line to [p]. Searched first just ahead of [near] (where the bus was a
  /// moment ago - a route that passes the same road twice is not confused), then everywhere if that
  /// finds nothing close.
  RouteSpot? locate(LatLng p, {double? near}) {
    if (pts.length < 2) return null;
    RouteSpot? best;
    void scan(double from, double to) {
      for (var i = 0; i < pts.length - 1; i++) {
        if (_cum[i + 1] < from || _cum[i] > to) continue;
        final s = _onSegment(i, p);
        if (best == null || s.off < best!.off) best = s;
      }
    }

    if (near != null) {
      scan(near - 60, near + 3000);
      if (best != null && best!.off <= 60) return best;
    }
    final local = best;
    best = null;
    scan(-1, double.infinity);
    if (local != null && best != null && local.off <= best!.off + 15) return local;
    return best;
  }

  RouteSpot _onSegment(int i, LatLng p) {
    final a = pts[i], b = pts[i + 1];
    // Flat metres around p - exact enough over one road segment.
    final kx = 111320.0 * math.cos(p.latitude * math.pi / 180), ky = 110540.0;
    final ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky;
    final bx = (b.longitude - p.longitude) * kx, by = (b.latitude - p.latitude) * ky;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 <= 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final px = ax + dx * t, py = ay + dy * t;
    final segLen = _cum[i + 1] - _cum[i];
    return RouteSpot(_cum[i] + segLen * t, math.sqrt(px * px + py * py),
        LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t));
  }

  int _segAt(double along) {
    var lo = 0, hi = pts.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_cum[mid] <= along) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The point [along] metres from the start of the line.
  LatLng at(double along) {
    if (pts.length < 2) return pts.first;
    final d = along.clamp(0.0, length);
    final i = _segAt(d);
    final segLen = _cum[i + 1] - _cum[i];
    final t = segLen <= 0 ? 0.0 : (d - _cum[i]) / segLen;
    final a = pts[i], b = pts[i + 1];
    return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
  }

  /// The road's direction [along] metres in (looked at over the next ~20 m, so a tiny kink does not
  /// swing the bus).
  double headingAt(double along) {
    final a = at(along), b = at(math.min(length, along + 20));
    if (RoutePlanner.meters(a, b) < 2) return RoutePlanner.bearing(at(math.max(0.0, along - 20)), a);
    return RoutePlanner.bearing(a, b);
  }

  /// The line still to drive, from [along] on.
  List<LatLng> from(double along) {
    if (pts.length < 2) return pts;
    final d = along.clamp(0.0, length);
    final i = _segAt(d);
    return [at(d), ...pts.sublist(i + 1)];
  }
}
