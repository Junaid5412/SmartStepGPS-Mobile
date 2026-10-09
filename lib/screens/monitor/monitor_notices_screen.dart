import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'monitor_store.dart';
import 'monitor_widgets.dart';

/// Every "Not on Bus" notice parents have sent for the monitor's children: today, then each of the
/// coming days (two weeks ahead), so she knows before she sets off - not at the stop.
/// Today's notices are also on each child's card in the shift, where she confirms them.
class MonitorNoticesScreen extends StatelessWidget {
  final MonitorStore store;
  const MonitorNoticesScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonitorColors.page,
      appBar: AppBar(
        title: const Text('Not on Bus', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
        backgroundColor: MonitorColors.navy,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final groups = <String, List<Map<String, dynamic>>>{};
          final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
          for (final s in store.noticedStudents) {
            final n = Map<String, dynamic>.from(s['notice'] as Map);
            groups.putIfAbsent(today, () => []).add({...n, 'student_name': s['name']});
          }
          for (final n in store.upcoming) {
            groups.putIfAbsent('${n['date']}', () => []).add(n);
          }
          return RefreshIndicator(
            onRefresh: () => store.load(silent: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: [
                PageWidth(
                  max: 640,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (groups.isEmpty)
                        const SurfaceCard(
                          child: Row(children: [
                            Icon(Icons.directions_bus_rounded, color: MonitorColors.muted),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text('No notices from parents for the next two weeks. Every child rides as usual.',
                                  style: TextStyle(color: MonitorColors.muted)),
                            ),
                          ]),
                        ),
                      for (final e in groups.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 6, 2, 8),
                          child: Text('${_dayLabel(e.key)}  ·  ${e.value.length}',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: MonitorColors.ink)),
                        ),
                        for (final n in e.value)
                          Padding(padding: const EdgeInsets.only(bottom: 10), child: NoticeCard(notice: n)),
                        const SizedBox(height: 6),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _dayLabel(String ymd) {
    final d = DateTime.tryParse(ymd);
    if (d == null) return ymd;
    final now = DateTime.now();
    final diff = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    final pretty = DateFormat('EEE d MMM').format(d);
    if (diff == 0) return 'Today, $pretty';
    if (diff == 1) return 'Tomorrow, $pretty';
    return pretty;
  }
}

/// One child's notice: name, what happens on each trip, the reason and the parent's note.
class NoticeCard extends StatelessWidget {
  final Map<String, dynamic> notice;
  const NoticeCard({super.key, required this.notice});

  Widget _trip(String label, String choice, bool morning) {
    final (String text, Color c) = switch (choice) {
      'parent' => (morning ? 'Parent drops' : 'Parent picks up', MonitorColors.byParent),
      'absent' => ('Not coming', MonitorColors.red),
      _ => ('By bus', MonitorColors.muted),
    };
    return StatusPill(text: '$label: $text', color: c);
  }

  @override
  Widget build(BuildContext context) {
    final reason = '${notice['reason'] ?? ''}';
    final note = '${notice['comment'] ?? ''}'.trim();
    return SurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Initials(name: '${notice['student_name'] ?? '?'}', size: 34, color: MonitorColors.byParent),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${notice['student_name'] ?? 'Student'}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: MonitorColors.ink)),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _trip('Morning', '${notice['morning'] ?? 'bus'}', true),
            _trip('Evening', '${notice['evening'] ?? 'bus'}', false),
          ]),
          if ((reason.isNotEmpty && reason != 'Parent') || note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text([if (reason.isNotEmpty && reason != 'Parent') reason, if (note.isNotEmpty) '"$note"'].join('  ·  '),
                style: const TextStyle(fontSize: 13, color: MonitorColors.muted)),
          ],
        ],
      ),
    );
  }
}
