import 'dart:async';

import 'package:flutter/material.dart';

import 'monitor_store.dart';
import 'monitor_widgets.dart';

/// A shift that is not open: the countdown until it opens, or - once it has closed - how it went and
/// who was never marked. While a shift is open the Shift tab shows the map / list instead
/// (MonitorRouteView), which is the one place attendance is marked.
class MonitorShiftView extends StatefulWidget {
  final MonitorStore store;
  final String shiftKey;
  final ValueChanged<String> onSwitchShift;

  const MonitorShiftView({super.key, required this.store, required this.shiftKey, required this.onSwitchShift});

  @override
  State<MonitorShiftView> createState() => _MonitorShiftViewState();
}

class _MonitorShiftViewState extends State<MonitorShiftView> {
  MonitorStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final w = store.window(widget.shiftKey);
    if (w == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final c = store.counts(w.key);
    return Column(
      children: [
        _header(w, c),
        Expanded(child: _lockedBody(w, c)),
      ],
    );
  }

  // ---- header -----------------------------------------------------------------------------------------

  Widget _header(ShiftWindow w, ShiftCounts c) {
    final (String stateText, IconData stateIcon) = switch (w.state) {
      'open' => ('Open · closes ${fmtTime(w.closesAt)}', Icons.radio_button_checked_rounded),
      'upcoming' => ('Locked · opens ${fmtTime(w.opensAt)}', Icons.lock_rounded),
      _ => ('Closed at ${fmtTime(w.closesAt)}', Icons.lock_rounded),
    };
    return GradientHeader(
      colors: [w.color, w.accent],
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _switcher(w),
          const SizedBox(height: 14),
          Row(
            children: [
              IconTile(icon: w.icon, color: Colors.white, onDark: true, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${w.name} shift',
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                    Text('${w.route} · ${w.timeRange}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: w.isOpen ? const Color(0xFF22C55E) : Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(stateIcon, size: 13, color: Colors.white),
                    const SizedBox(width: 5),
                    Text(stateText,
                        style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const Spacer(),
              Text('${c.done}/${c.total} done',
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: c.progress,
              minHeight: 6,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switcher(ShiftWindow current) {
    Widget seg(ShiftWindow? w) {
      if (w == null) return const SizedBox.shrink();
      final sel = w.key == current.key;
      return Expanded(
        child: InkWell(
          onTap: sel ? null : () => widget.onSwitchShift(w.key),
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: sel ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(w.isOpen ? w.icon : Icons.lock_rounded, size: 15, color: sel ? w.color : Colors.white70),
                const SizedBox(width: 6),
                Text(w.name,
                    style: TextStyle(
                        color: sel ? w.color : Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(15)),
      child: Row(children: [seg(store.morning), const SizedBox(width: 4), seg(store.evening)]),
    );
  }

  // ---- locked -----------------------------------------------------------------------------------------

  Widget _lockedBody(ShiftWindow w, ShiftCounts c) {
    final upcoming = w.state == 'upcoming';
    final unmarked = store.students.where((s) => store.stageOf(s, w.key) == Stage.waiting).toList();
    return RefreshIndicator(
      onRefresh: () => store.load(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        children: [
          PageWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SurfaceCard(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
                  child: Column(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(color: w.color.withValues(alpha: 0.10), shape: BoxShape.circle),
                        child: Icon(upcoming ? Icons.lock_clock_rounded : Icons.lock_rounded, color: w.color, size: 30),
                      ),
                      const SizedBox(height: 14),
                      Text(upcoming ? 'Attendance opens at ${fmtTime(w.opensAt)}' : '${w.name} shift is closed',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: MonitorColors.ink)),
                      const SizedBox(height: 6),
                      if (upcoming) ...[
                        _Countdown(window: w),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        'Attendance can be marked from ${fmtTime(w.opensAt)} to ${fmtTime(w.closesAt)} '
                        '(${MonitorStore.graceMin} minutes either side of the shift).',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13, color: MonitorColors.muted, height: 1.35),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SectionTitle(upcoming ? 'Expected today' : 'How it went'),
                const SizedBox(height: 10),
                _lockedStats(w, c, upcoming),
                if (!upcoming && unmarked.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  SectionTitle('Not marked (${unmarked.length})'),
                  const SizedBox(height: 10),
                  SurfaceCard(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      children: [
                        for (final s in unmarked)
                          ListTile(
                            dense: true,
                            leading: Initials(name: s['name']?.toString() ?? '?', size: 32, color: w.color),
                            title: Text(s['name']?.toString() ?? 'Student',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(s['parent_name']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _lockedStats(ShiftWindow w, ShiftCounts c, bool upcoming) {
    final tiles = upcoming
        ? [
            StatTile(label: 'Students', value: c.total, icon: Icons.groups_rounded, color: w.color),
            StatTile(label: 'Stops', value: store.familyCount, icon: Icons.place_rounded, color: w.color),
            if (c.notTravelling > 0)
              StatTile(
                  label: 'Not travelling', value: c.notTravelling, icon: Icons.event_busy_rounded, color: MonitorColors.amber),
          ]
        : [
            StatTile(
                label: w.isMorning ? 'At school' : 'Home',
                value: c.dropped,
                icon: Icons.check_circle_rounded,
                color: MonitorColors.green),
            StatTile(
                label: 'Still on bus',
                value: c.onBus,
                icon: Icons.directions_bus_rounded,
                color: const Color(0xFF1D4ED8)),
            StatTile(label: 'Absent / leave', value: c.absent + c.leave, icon: Icons.event_busy_rounded, color: MonitorColors.amber),
            StatTile(label: 'By parent', value: c.byParent, icon: Icons.family_restroom_rounded, color: MonitorColors.byParent),
          ];
    return _grid(tiles);
  }

  Widget _grid(List<Widget> tiles) => LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth >= 560 ? 4 : 2;
        const gap = 12.0;
        final width = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final t in tiles) SizedBox(width: width, child: t)]);
      });

}

/// Live "opens in 3:52:10" for a locked shift.
class _Countdown extends StatefulWidget {
  final ShiftWindow window;
  const _Countdown({required this.window});

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  late final Timer _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.window.opensIn;
    String two(int n) => n.toString().padLeft(2, '0');
    final text = '${d.inHours}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
    return Column(
      children: [
        Text(text,
            style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: widget.window.color,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const Text('until it opens', style: TextStyle(fontSize: 12, color: MonitorColors.muted)),
      ],
    );
  }
}
