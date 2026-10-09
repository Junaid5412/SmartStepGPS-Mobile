import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/api_service.dart';

/// Brand colours for the monitor screens.
class MonitorColors {
  static const navy = Color(0xFF1E3C72);
  static const navyDeep = Color(0xFF14284D);
  static const morning = Color(0xFF1E3C72);
  static const morningAccent = Color(0xFF2A5298);
  static const evening = Color(0xFF4338CA);
  static const eveningAccent = Color(0xFF6D28D9);
  static const page = Color(0xFFF1F5F9);
  static const ink = Color(0xFF0F172A);
  static const muted = Color(0xFF64748B);
  static const line = Color(0xFFE2E8F0);
  static const green = Color(0xFF15803D);
  static const amber = Color(0xFFB45309);
  static const red = Color(0xFFDC2626);
  static const byParent = Color(0xFF7C3AED);
}

/// When one shift accepts attendance, as reported by roster.php.
///
/// The server decides; the app only counts down from the seconds it was given, so a phone with a
/// wrong clock still shows the right state. attendance.php refuses anything outside the window
/// anyway, so this is about showing the monitor the truth, not about enforcing it.
class ShiftWindow {
  final String key; // 'morning' | 'afternoon' (the API name; people see "Evening")
  final String start, end, opensAt, closesAt; // HH:mm
  final int _opensIn, _closesIn; // seconds, at the moment the roster was fetched
  final DateTime _fetchedAt;

  ShiftWindow._(this.key, this.start, this.end, this.opensAt, this.closesAt, this._opensIn,
      this._closesIn, this._fetchedAt);

  factory ShiftWindow.fromJson(String key, Map<String, dynamic> j, DateTime fetchedAt) {
    int n(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return ShiftWindow._(key, '${j['start']}', '${j['end']}', '${j['opens_at']}',
        '${j['closes_at']}', n(j['opens_in']), n(j['closes_in']), fetchedAt);
  }

  /// For a server that predates shift windows: work it out from the school times and this phone's
  /// clock, with the same 15 minute grace the server uses.
  factory ShiftWindow.fromTimes(String key, String start, String end, DateTime now) {
    DateTime at(String hm) {
      final p = hm.split(':');
      return DateTime(now.year, now.month, now.day, int.tryParse(p[0]) ?? 0,
          p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0);
    }

    final open = at(start).subtract(const Duration(minutes: MonitorStore.graceMin));
    final close = at(end).add(const Duration(minutes: MonitorStore.graceMin));
    String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    int secs(DateTime d) => d.difference(now).inSeconds.clamp(0, 1 << 30);
    return ShiftWindow._(key, start.substring(0, 5), end.substring(0, 5), hm(open), hm(close),
        secs(open), secs(close), now);
  }

  int get _elapsed => DateTime.now().difference(_fetchedAt).inSeconds;
  Duration get opensIn => Duration(seconds: (_opensIn - _elapsed).clamp(0, 1 << 30));
  Duration get closesIn => Duration(seconds: (_closesIn - _elapsed).clamp(0, 1 << 30));

  /// upcoming | open | closed, right now.
  String get state {
    if (_opensIn - _elapsed > 0) return 'upcoming';
    if (_closesIn - _elapsed > 0) return 'open';
    return 'closed';
  }

  bool get isOpen => state == 'open';
  bool get isMorning => key == 'morning';
  String get name => isMorning ? 'Morning' : 'Evening';
  String get route => isMorning ? 'Home to School' : 'School to Home';
  IconData get icon => isMorning ? Icons.wb_sunny_rounded : Icons.nights_stay_rounded;
  Color get color => isMorning ? MonitorColors.morning : MonitorColors.evening;
  Color get accent => isMorning ? MonitorColors.morningAccent : MonitorColors.eveningAccent;

  String get timeRange => '${fmtTime(start)} – ${fmtTime(end)}';
}

/// "13:05" -> "1:05 PM".
String fmtTime(String hm) {
  final p = hm.split(':');
  if (p.length < 2) return hm;
  final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
  if (h == null || m == null) return hm;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${m.toString().padLeft(2, '0')} ${h >= 12 ? 'PM' : 'AM'}';
}

/// "3h 52m", "12m", "45s".
String fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// Children who share a parent (or, failing that, a phone number) get off at the same stop.
class FamilyGroup {
  final String key;
  final String parentName;
  final String phone;
  final String address;
  final dynamic stopLat;
  final dynamic stopLng;
  final List<dynamic> students;

  FamilyGroup({
    required this.key,
    required this.parentName,
    required this.phone,
    required this.address,
    this.stopLat,
    this.stopLng,
    required this.students,
  });

  bool get hasCoords => stopLat != null && stopLng != null;
  List<String> get names => students.map((s) => s['name']?.toString() ?? 'Student').toList();
}

/// Where a child is in one shift.
enum Stage { waiting, onBus, done }

/// The roster and today's attendance, shared by every monitor screen.
class MonitorStore extends ChangeNotifier {
  static const graceMin = 15;

  List<dynamic> students = [];

  /// "Not on Bus" notices for the coming days (today's are on each child, under 'notice').
  List<Map<String, dynamic>> upcoming = [];
  bool loading = true;
  bool loaded = false;
  String? error;
  bool unauthorized = false;

  String staffName = 'Staff Member';
  String staffRole = 'Bus Monitor';
  String busName = 'Unassigned';
  String driverName = 'Not Assigned';
  String driverPhone = '';

  ShiftWindow? morning;
  ShiftWindow? evening;

  Timer? _ticker;
  String _lastStates = '';
  DateTime _loadedDay = DateTime.now();

  MonitorStore() {
    // Re-check the windows every 20 s: redraw when one opens or closes, and fetch a fresh roster
    // then (and after midnight) so the countdowns and statuses never go stale on a screen left open.
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) {
      final states = _states;
      final now = DateTime.now();
      if (states != _lastStates || now.day != _loadedDay.day) {
        load(silent: true);
      } else {
        notifyListeners(); // countdown text
      }
    });
  }

  String get _states => '${morning?.state}/${evening?.state}';

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  ShiftWindow? window(String key) => key == 'morning' ? morning : evening;

  /// The shift open now, or else the next one to open today, or else the evening (the day's last).
  ShiftWindow? get focus {
    for (final w in [morning, evening]) {
      if (w != null && w.isOpen) return w;
    }
    for (final w in [morning, evening]) {
      if (w != null && w.state == 'upcoming') return w;
    }
    return evening ?? morning;
  }

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      loading = true;
      notifyListeners();
    }
    try {
      final r = await ApiService.getRoster();
      if (r['success'] == true) {
        final now = DateTime.now();
        students = (r['data'] as List?) ?? [];
        upcoming = [
          for (final n in (r['upcoming_notices'] as List?) ?? const [])
            if (n is Map) Map<String, dynamic>.from(n),
        ];
        final s = r['staff'];
        if (s is Map) {
          staffName = s['name']?.toString() ?? staffName;
          staffRole = s['role']?.toString() ?? staffRole;
          busName = s['bus_name']?.toString() ?? busName;
          driverName = s['driver_name']?.toString() ?? driverName;
          driverPhone = s['driver_phone']?.toString() ?? driverPhone;
        }
        final sh = r['shifts'];
        if (sh is Map && sh['morning'] is Map && sh['afternoon'] is Map) {
          morning = ShiftWindow.fromJson('morning', Map<String, dynamic>.from(sh['morning']), now);
          evening = ShiftWindow.fromJson('afternoon', Map<String, dynamic>.from(sh['afternoon']), now);
        } else {
          final t = r['timings'] is Map ? r['timings'] as Map : const {};
          morning = ShiftWindow.fromTimes('morning', '${t['morning_start'] ?? '05:30:00'}',
              '${t['morning_end'] ?? '07:30:00'}', now);
          evening = ShiftWindow.fromTimes('afternoon', '${t['afternoon_start'] ?? '13:00:00'}',
              '${t['afternoon_end'] ?? '16:00:00'}', now);
        }
        _lastStates = _states;
        _loadedDay = now;
        error = null;
        loaded = true;
      } else {
        final err = (r['error'] ?? 'Failed to load the student list').toString();
        unauthorized = err.contains('Unauthorized') || err.contains('token');
        error = err;
      }
    } catch (e) {
      error = 'No connection. Pull down to try again.';
    }
    loading = false;
    notifyListeners();
  }

  // ---- per-shift views of the roster --------------------------------------------------------------

  Map<String, dynamic>? statusOf(dynamic student, String shift) {
    final s = student[shift == 'morning' ? 'morning_status' : 'afternoon_status'];
    return s is Map ? Map<String, dynamic>.from(s) : null;
  }

  String? eventOf(dynamic student, String shift) => statusOf(student, shift)?['event_type']?.toString();

  Stage stageOf(dynamic student, String shift) {
    final e = eventOf(student, shift);
    if (e == null) return Stage.waiting;
    if (e == 'pickup') return Stage.onBus;
    return Stage.done;
  }

  /// The parent's "Not on Bus" choice for this child on this shift: 'parent' (the parent drops or
  /// collects) or 'absent' (not coming), or null when the child rides as usual.
  String? noticeFor(dynamic student, String shift) {
    final n = student['notice'];
    if (n is! Map) return null;
    final c = '${n[shift == 'morning' ? 'morning' : 'evening']}';
    return (c == 'parent' || c == 'absent') ? c : null;
  }

  /// The notice itself (reason, note, summary) for the card.
  Map<String, dynamic>? noticeOf(dynamic student) {
    final n = student['notice'];
    return n is Map ? Map<String, dynamic>.from(n) : null;
  }

  /// Children whose leave TODAY still matters: a trip it covers whose shift has not closed yet and
  /// that the monitor has not marked. Once the evening shift is over (or every such child has been
  /// confirmed) today's leave drops off the Home line and the list instead of lingering all night.
  List<dynamic> get noticedStudents => students.where(_leavePending).toList();

  bool _leavePending(dynamic s) {
    if (s['notice'] is! Map) return false;
    for (final shift in const ['morning', 'afternoon']) {
      if (noticeFor(s, shift) == null) continue;
      final w = window(shift);
      if (w != null && w.state == 'closed') continue;
      if (stageOf(s, shift) != Stage.waiting) continue;
      return true;
    }
    return false;
  }

  ShiftCounts counts(String shift) {
    final c = ShiftCounts();
    for (final s in students) {
      switch (eventOf(s, shift)) {
        case null:
          c.waiting++;
        case 'pickup':
          c.onBus++;
        case 'dropoff':
          c.dropped++;
        case 'absent':
          c.absent++;
        case 'leave':
          c.leave++;
        case 'by_parent':
          c.byParent++;
      }
    }
    c.total = students.length;
    return c;
  }

  /// Families in roster order, each keeping only the children at [stage] for [shift] (all if null).
  List<FamilyGroup> families(String shift, [Stage? stage]) {
    final groups = <String, List<dynamic>>{};
    final first = <String, dynamic>{};
    for (final s in students) {
      if (stage != null && stageOf(s, shift) != stage) continue;
      final pid = s['parent_id'];
      final phone = s['phone']?.toString().trim() ?? '';
      final key = (pid != null && pid != 0 && pid != '0')
          ? 'p$pid'
          : phone.isNotEmpty
              ? 't$phone'
              : 's${s['id']}';
      groups.putIfAbsent(key, () => []).add(s);
      first.putIfAbsent(key, () => s);
    }
    return groups.entries.map((e) {
      final s = first[e.key];
      return FamilyGroup(
        key: e.key,
        parentName: s['parent_name']?.toString() ?? 'Family',
        phone: s['phone']?.toString() ?? '',
        address: s['address']?.toString() ?? 'School bus stop',
        stopLat: s['stop_lat'],
        stopLng: s['stop_lng'],
        students: e.value,
      );
    }).toList();
  }

  int get familyCount => families('morning').length;
}

class ShiftCounts {
  int total = 0, waiting = 0, onBus = 0, dropped = 0, absent = 0, leave = 0, byParent = 0;
  int get notTravelling => absent + leave + byParent;
  int get done => dropped + notTravelling;
  double get progress => total == 0 ? 0 : done / total;
}

/// What each status is called and how it looks, per shift.
class StatusStyle {
  static String label(String? type, String shift) {
    final m = shift == 'morning';
    switch (type) {
      case 'pickup':
        return m ? 'On bus' : 'Boarded';
      case 'dropoff':
        return m ? 'At school' : 'Home';
      case 'absent':
        return 'Absent';
      case 'leave':
        return 'On leave';
      case 'by_parent':
        return 'By parent';
    }
    return 'Waiting';
  }

  static Color color(String? type) {
    switch (type) {
      case 'pickup':
        return const Color(0xFF1D4ED8);
      case 'dropoff':
        return MonitorColors.green;
      case 'absent':
        return MonitorColors.red;
      case 'leave':
        return MonitorColors.amber;
      case 'by_parent':
        return MonitorColors.byParent;
    }
    return MonitorColors.muted;
  }

  static IconData icon(String? type) {
    switch (type) {
      case 'pickup':
        return Icons.directions_bus_rounded;
      case 'dropoff':
        return Icons.check_circle_rounded;
      case 'absent':
        return Icons.cancel_rounded;
      case 'leave':
        return Icons.event_busy_rounded;
      case 'by_parent':
        return Icons.family_restroom_rounded;
    }
    return Icons.schedule_rounded;
  }
}
