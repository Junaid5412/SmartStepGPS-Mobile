import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_service.dart';
import 'monitor_store.dart';

/// Everything a monitor can do to a child or a family, shared by the shift screen's cards.
class MonitorActions {
  final BuildContext context;
  final MonitorStore store;
  MonitorActions(this.context, this.store);

  void _snack(String text, Color color, {int seconds = 2}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), backgroundColor: color, duration: Duration(seconds: seconds)));
  }

  /// Ask, then record. Refuses straight away when the shift is not open: the server would refuse
  /// it too, but the monitor should not have to wait for a round trip to learn that.
  Future<void> mark(ShiftWindow w, dynamic student, String type) async {
    if (!w.isOpen) {
      _snack(_closedText(w), MonitorColors.ink, seconds: 3);
      return;
    }
    final id = student['id'] is int ? student['id'] as int : int.tryParse('${student['id']}') ?? 0;
    final name = student['name']?.toString() ?? 'Student';
    final ok = await _confirm(w, name, type);
    if (ok != true || !context.mounted) return;

    final pos = await _currentPosition();
    if (!context.mounted) return;
    Map<String, dynamic> res;
    try {
      res = await ApiService.markAttendance(id, type, pos?.latitude, pos?.longitude, shift: w.key);
    } catch (_) {
      res = {'success': false, 'error': 'No connection. Nothing was recorded - please try again.'};
    }
    if (!context.mounted) return;

    if (res['success'] == true) {
      _snack(
        pos == null
            ? '$name · ${StatusStyle.label(type, w.key)} (no GPS stamp - location unavailable)'
            : '$name · ${StatusStyle.label(type, w.key)}',
        pos == null ? Colors.orange.shade800 : StatusStyle.color(type),
        seconds: pos == null ? 3 : 1,
      );
      await store.load(silent: true);
    } else {
      _snack((res['error'] ?? 'Could not record attendance').toString(), MonitorColors.red, seconds: 4);
      // The shift closed while the screen was open, or someone else already marked this child.
      if (res['shift_closed'] == true || res['error'].toString().contains('already')) {
        await store.load(silent: true);
      }
    }
  }

  /// Several children at once - "All picked up" at a stop, "Everyone at school". One confirmation
  /// that NAMES every child, so a tap cannot quietly mark someone who is not there.
  Future<void> markMany(ShiftWindow w, List<dynamic> students, String type, String title) async {
    if (students.isEmpty) return;
    if (!w.isOpen) {
      _snack(_closedText(w), MonitorColors.ink, seconds: 3);
      return;
    }
    final names = students.map((s) => s['name']?.toString() ?? 'Student').toList();
    final color = StatusStyle.color(type);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final n in names)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Icon(Icons.check_circle_rounded, size: 18, color: color),
                  const SizedBox(width: 8),
                  Expanded(child: Text(n, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                ]),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: color),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Confirm ${names.length}'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final pos = await _currentPosition();
    var done = 0;
    String? err;
    for (final s in students) {
      final id = s['id'] is int ? s['id'] as int : int.tryParse('${s['id']}') ?? 0;
      try {
        final r = await ApiService.markAttendance(id, type, pos?.latitude, pos?.longitude, shift: w.key);
        if (r['success'] == true) {
          done++;
        } else {
          err ??= (r['error'] ?? 'Could not record').toString();
        }
      } catch (_) {
        err ??= 'No connection for some children - please try them again.';
      }
    }
    if (!context.mounted) return;
    _snack(
      err == null ? '$done marked · ${StatusStyle.label(type, w.key)}' : '$done of ${students.length} marked. $err',
      err == null ? color : MonitorColors.red,
      seconds: err == null ? 2 : 5,
    );
    await store.load(silent: true);
  }

  String _closedText(ShiftWindow w) => w.state == 'upcoming'
      ? '${w.name} attendance opens at ${fmtTime(w.opensAt)}.'
      : '${w.name} attendance closed at ${fmtTime(w.closesAt)}.';

  Future<bool?> _confirm(ShiftWindow w, String name, String type) {
    final m = w.isMorning;
    final (String title, String desc) = switch (type) {
      'pickup' => m
          ? ('Picked up', 'Picked up from home and on the bus.')
          : ('Boarded at school', 'On the bus, leaving school.'),
      'dropoff' => m
          ? ('Dropped at school', 'Safely dropped off at school.')
          : ('Dropped at home', 'Safely dropped off at home.'),
      'absent' => ('Absent', 'Not at the stop and not coming today.'),
      'leave' => ('Not coming', 'The parent said this child is not coming today.'),
      'by_parent' => m
          ? ('Parent taking to school', 'A parent is taking the child to school. Counts as present.')
          : ('Parent collecting', 'A parent is collecting the child from school. Counts as present.'),
      _ => (type, ''),
    };
    final color = StatusStyle.color(type);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 6),
        title: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(StatusStyle.icon(type), color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
            const SizedBox(height: 2),
            Text('${w.name} shift', style: const TextStyle(color: MonitorColors.muted, fontSize: 13)),
            const SizedBox(height: 10),
            Text(desc, style: const TextStyle(fontSize: 14)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: color),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  /// Absent / leave / parent are the exceptions, so they live behind one button instead of three.
  void notTravelling(ShiftWindow w, dynamic student) {
    final name = student['name']?.toString() ?? 'Student';
    final options = [
      ('absent', 'Absent', 'Not at the stop, not coming today'),
      ('leave', 'On leave', 'The parent said in advance'),
      ('by_parent', w.isMorning ? 'Parent taking to school' : 'Parent collecting from school',
          'Counts as present, just not on the bus'),
    ];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('${w.name} shift · why is this child not on the bus?',
                  style: const TextStyle(fontSize: 13, color: MonitorColors.muted)),
              const SizedBox(height: 8),
              for (final (type, title, sub) in options)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: CircleAvatar(
                    backgroundColor: StatusStyle.color(type).withValues(alpha: 0.12),
                    child: Icon(StatusStyle.icon(type), color: StatusStyle.color(type)),
                  ),
                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.pop(sheet);
                    mark(w, student, type);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Where the monitor is standing when they mark a child.
  ///
  /// Returns null rather than a placeholder if no fix can be had, and never blocks the marking: a
  /// monitor with no signal must still be able to record that a child boarded. The stamp is
  /// evidence, not a precondition.
  Future<Position?> _currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high)
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('Attendance GPS stamp unavailable: $e');
      return null;
    }
  }

  Future<void> call(String phone) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    if (!await launchUrl(Uri.parse('tel:$clean')) && context.mounted) {
      _snack('Could not open the phone dialer', MonitorColors.ink);
    }
  }

  Future<void> whatsApp(FamilyGroup f) async {
    final clean = f.phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.isEmpty) return;
    final msg = Uri.encodeComponent('Hello, regarding ${f.names.join(', ')} - Smart Step School Bus: ');
    if (!await launchUrl(Uri.parse('https://wa.me/$clean?text=$msg'), mode: LaunchMode.externalApplication) &&
        context.mounted) {
      _snack('Could not open WhatsApp', MonitorColors.ink);
    }
  }

  Future<void> directions(FamilyGroup f) async {
    if (!f.hasCoords) {
      _snack('No location saved for this stop.', MonitorColors.ink);
      return;
    }
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${f.stopLat},${f.stopLng}');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && context.mounted) {
      _snack('Could not open Maps', MonitorColors.ink);
    }
  }
}
