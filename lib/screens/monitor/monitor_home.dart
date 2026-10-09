import 'package:flutter/material.dart';

import 'monitor_notices_screen.dart';
import 'monitor_store.dart';
import 'monitor_widgets.dart';

/// The monitor's home: today at a glance. No student list here - children are marked inside a
/// shift, and only while that shift is open.
class MonitorHome extends StatelessWidget {
  final MonitorStore store;
  final void Function(String shiftKey) onOpenShift;
  final void Function(String phone) onCall;

  const MonitorHome({super.key, required this.store, required this.onOpenShift, required this.onCall});

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final focus = store.focus;
    return RefreshIndicator(
      onRefresh: () => store.load(silent: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _header(context)),
          SliverToBoxAdapter(
            child: PageWidth(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (store.error != null && !store.loaded) ErrorNote(text: store.error!, onRetry: store.load),
                    if (focus != null) _hero(context, focus),
                    const SizedBox(height: 14),
                    _notices(context),
                    const SizedBox(height: 18),
                    const SectionTitle('Today\'s shifts'),
                    const SizedBox(height: 10),
                    _shiftCards(),
                    if (focus != null) ...[
                      const SizedBox(height: 18),
                      SectionTitle('${focus.name} summary'),
                      const SizedBox(height: 10),
                      _summary(focus),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final hasDriver = store.driverName.isNotEmpty && store.driverName != 'Not Assigned';
    return GradientHeader(
      colors: const [MonitorColors.navyDeep, MonitorColors.navy],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_greeting, style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13.5)),
                    const SizedBox(height: 2),
                    Text(store.staffName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Initials(name: store.staffName, size: 46, dark: true),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              HeaderChip(icon: Icons.directions_bus_rounded, text: store.busName),
              HeaderChip(icon: Icons.badge_rounded, text: store.staffRole),
            ],
          ),
          if (hasDriver) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_pin_rounded, color: Colors.white70, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Driver', style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 11)),
                        Text(store.driverName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                      ],
                    ),
                  ),
                  if (store.driverPhone.isNotEmpty)
                    FilledButton.icon(
                      onPressed: () => onCall(store.driverPhone),
                      icon: const Icon(Icons.call_rounded, size: 16),
                      label: const Text('Call'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hero(BuildContext context, ShiftWindow w) {
    final c = store.counts(w.key);
    final open = w.isOpen;
    final (String stateText, IconData stateIcon) = switch (w.state) {
      'open' => ('Open · closes ${fmtTime(w.closesAt)}', Icons.radio_button_checked_rounded),
      'upcoming' => ('Opens ${fmtTime(w.opensAt)} · in ${fmtDuration(w.opensIn)}', Icons.lock_clock_rounded),
      _ => ('Closed at ${fmtTime(w.closesAt)}', Icons.lock_rounded),
    };

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: open ? [w.color, w.accent] : [Colors.white, Colors.white],
        ),
        borderRadius: BorderRadius.circular(22),
        border: open ? null : Border.all(color: MonitorColors.line),
        boxShadow: [
          BoxShadow(
            color: (open ? w.color : Colors.black).withValues(alpha: open ? 0.16 : 0.04),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconTile(icon: w.icon, color: open ? Colors.white : w.color, onDark: open),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${open ? 'Current shift' : (w.state == 'upcoming' ? 'Next shift' : 'Last shift')} · ${w.route}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: open ? Colors.white70 : MonitorColors.muted)),
                    Text('${w.name} shift',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: open ? Colors.white : MonitorColors.ink)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              ProgressRing(
                value: c.progress,
                label: '${c.done}/${c.total}',
                caption: 'done',
                color: open ? Colors.white : w.color,
                track: open ? Colors.white24 : MonitorColors.line,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _heroStat('Waiting', c.waiting, open),
                    _heroStat(w.isMorning ? 'On bus' : 'Boarded', c.onBus, open),
                    _heroStat(w.isMorning ? 'At school' : 'Home', c.dropped, open),
                    _heroStat('Not travelling', c.notTravelling, open),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(stateIcon, size: 15, color: open ? Colors.white : MonitorColors.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(stateText,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: open ? Colors.white : MonitorColors.muted)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: open
                ? FilledButton.icon(
                    onPressed: () => onOpenShift(w.key),
                    icon: const Icon(Icons.how_to_reg_rounded),
                    label: const Text('Continue attendance', style: TextStyle(fontWeight: FontWeight.w700)),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: w.color,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  )
                : OutlinedButton.icon(
                    onPressed: () => onOpenShift(w.key),
                    icon: Icon(w.state == 'upcoming' ? Icons.visibility_rounded : Icons.summarize_rounded),
                    label: Text(w.state == 'upcoming' ? 'View shift' : 'View summary'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: w.color,
                      side: const BorderSide(color: MonitorColors.line),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// "Not on Bus": what parents have told the bus - today, and the coming days - so the monitor
  /// knows before she sets off. Always shown, so she always knows where to look.
  Widget _notices(BuildContext context) {
    final today = store.noticedStudents;
    final later = store.upcoming;
    Widget line(String name, String summary) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$name  ', style: const TextStyle(fontWeight: FontWeight.w700, color: MonitorColors.ink)),
              TextSpan(text: summary, style: const TextStyle(color: MonitorColors.muted)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        );
    String day(String ymd) {
      final d = DateTime.tryParse(ymd);
      if (d == null) return ymd;
      final now = DateTime.now();
      final diff = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
      if (diff == 1) return 'Tomorrow';
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return '${names[d.weekday - 1]} ${d.day}/${d.month}';
    }

    return SurfaceCard(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MonitorNoticesScreen(store: store))),
      borderColor: (today.isNotEmpty || later.isNotEmpty) ? MonitorColors.byParent.withValues(alpha: 0.4) : null,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const IconTile(icon: Icons.no_transfer_rounded, color: MonitorColors.byParent, size: 34),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Not on Bus',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: MonitorColors.ink)),
            ),
            if (today.isNotEmpty) StatusPill(text: 'Today ${today.length}', color: MonitorColors.byParent),
            if (later.isNotEmpty) ...[
              const SizedBox(width: 6),
              StatusPill(text: 'Coming ${later.length}', color: MonitorColors.muted),
            ],
            const Icon(Icons.chevron_right_rounded, color: MonitorColors.muted),
          ]),
          if (today.isEmpty && later.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No notices from parents. Every child rides as usual.',
                  style: TextStyle(fontSize: 13, color: MonitorColors.muted)),
            ),
          if (today.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('TODAY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: MonitorColors.byParent, letterSpacing: .6)),
            for (final s in today.take(3)) line('${s['name'] ?? 'Student'}', '${(s['notice'] as Map)['summary'] ?? ''}'),
            if (today.length > 3) line('+ ${today.length - 3} more', ''),
          ],
          if (later.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text('COMING UP', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: MonitorColors.muted, letterSpacing: .6)),
            for (final n in later.take(3)) line('${day('${n['date']}')} · ${n['student_name'] ?? 'Student'}', '${n['summary'] ?? ''}'),
            if (later.length > 3) line('+ ${later.length - 3} more', ''),
          ],
        ],
      ),
    );
  }

  Widget _heroStat(String label, int n, bool onDark) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: onDark ? Colors.white70 : MonitorColors.muted)),
            ),
            Text('$n',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w800, color: onDark ? Colors.white : MonitorColors.ink)),
          ],
        ),
      );

  Widget _shiftCards() {
    final cards = [
      for (final w in [store.morning, store.evening])
        if (w != null) _shiftCard(w),
    ];
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 330) {
        return Column(children: [for (final c in cards) Padding(padding: const EdgeInsets.only(bottom: 10), child: c)]);
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: cards[i]),
            ],
          ],
        ),
      );
    });
  }

  Widget _shiftCard(ShiftWindow w) {
    final c = store.counts(w.key);
    final open = w.isOpen;
    final (String state, Color stateColor, IconData stateIcon) = switch (w.state) {
      'open' => ('Open now', MonitorColors.green, Icons.lock_open_rounded),
      'upcoming' => ('Opens ${fmtTime(w.opensAt)}', MonitorColors.muted, Icons.lock_rounded),
      _ => ('Closed', MonitorColors.muted, Icons.lock_rounded),
    };
    return SurfaceCard(
      onTap: () => onOpenShift(w.key),
      borderColor: open ? w.color.withValues(alpha: 0.45) : null,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: w.icon, color: w.color, size: 38),
              const Spacer(),
              Icon(stateIcon, size: 16, color: stateColor),
            ],
          ),
          const SizedBox(height: 12),
          Text(w.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: MonitorColors.ink)),
          const SizedBox(height: 2),
          Text(w.timeRange,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: MonitorColors.muted)),
          const SizedBox(height: 10),
          Text(state,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: stateColor)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: c.progress,
              minHeight: 5,
              backgroundColor: MonitorColors.line,
              valueColor: AlwaysStoppedAnimation(w.color),
            ),
          ),
          const SizedBox(height: 6),
          Text('${c.done} of ${c.total} done', style: const TextStyle(fontSize: 11.5, color: MonitorColors.muted)),
        ],
      ),
    );
  }

  Widget _summary(ShiftWindow w) {
    final c = store.counts(w.key);
    final tiles = [
      StatTile(label: 'Waiting', value: c.waiting, icon: Icons.schedule_rounded, color: MonitorColors.muted),
      StatTile(
          label: w.isMorning ? 'On bus' : 'Boarded',
          value: c.onBus,
          icon: Icons.directions_bus_rounded,
          color: const Color(0xFF1D4ED8)),
      StatTile(
          label: w.isMorning ? 'At school' : 'Home',
          value: c.dropped,
          icon: w.isMorning ? Icons.school_rounded : Icons.home_rounded,
          color: MonitorColors.green),
      StatTile(
          label: 'Not travelling', value: c.notTravelling, icon: Icons.event_busy_rounded, color: MonitorColors.amber),
    ];
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 560 ? 4 : 2;
      const gap = 12.0;
      final w = (box.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }
}
