import 'dart:async';

import 'package:flutter/material.dart';

import 'monitor_actions.dart';
import 'monitor_store.dart';
import 'monitor_widgets.dart';

/// One shift's attendance. Children move through three tabs - waiting, on the bus, done - and each
/// card offers the one next step for that child. Outside the shift's window the page is locked.
class MonitorShiftView extends StatefulWidget {
  final MonitorStore store;
  final String shiftKey;
  final ValueChanged<String> onSwitchShift;

  const MonitorShiftView({super.key, required this.store, required this.shiftKey, required this.onSwitchShift});

  @override
  State<MonitorShiftView> createState() => _MonitorShiftViewState();
}

class _MonitorShiftViewState extends State<MonitorShiftView> {
  Stage _stage = Stage.waiting;

  /// Families whose card the monitor has opened or closed by hand. The next stop starts open.
  final Set<String> _toggled = {};

  MonitorStore get store => widget.store;

  @override
  void didUpdateWidget(MonitorShiftView old) {
    super.didUpdateWidget(old);
    if (old.shiftKey != widget.shiftKey) {
      _stage = Stage.waiting;
      _toggled.clear();
    }
  }

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
        Expanded(child: w.isOpen ? _openBody(w, c) : _lockedBody(w, c)),
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

  // ---- open -------------------------------------------------------------------------------------------

  Widget _openBody(ShiftWindow w, ShiftCounts c) {
    final m = w.isMorning;
    final tabs = [
      (Stage.waiting, m ? 'To pick up' : 'To board', c.waiting),
      (Stage.onBus, 'On bus', c.onBus),
      (Stage.done, m ? 'Done' : 'Home', c.done),
    ];
    final families = store.families(w.key, _stage);
    final actions = MonitorActions(context, store);

    return Column(
      children: [
        PageWidth(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: MonitorColors.line),
              ),
              child: Row(
                children: [
                  for (final (stage, label, n) in tabs)
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => _stage = stage),
                        borderRadius: BorderRadius.circular(11),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                          decoration: BoxDecoration(
                            color: _stage == stage ? w.color : Colors.transparent,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(label,
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: _stage == stage ? Colors.white : MonitorColors.muted)),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: _stage == stage ? Colors.white24 : MonitorColors.page,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text('$n',
                                      style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w800,
                                          color: _stage == stage ? Colors.white : MonitorColors.ink)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => store.load(silent: true),
            child: families.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [_empty(w, c)],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    itemCount: families.length,
                    itemBuilder: (context, i) => PageWidth(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _familyCard(w, families[i], i, actions),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _empty(ShiftWindow w, ShiftCounts c) {
    final (IconData icon, String title, String sub) = switch (_stage) {
      Stage.waiting => c.total == 0
          ? (Icons.groups_rounded, 'No students on this bus', 'Ask the school office to assign students to your bus.')
          : (Icons.task_alt_rounded, 'Everyone is accounted for', 'No one is left to ${w.isMorning ? 'pick up' : 'board'}.'),
      Stage.onBus => (Icons.directions_bus_rounded, 'No one on the bus', 'Children appear here once picked up.'),
      Stage.done => (Icons.hourglass_empty_rounded, 'Nothing finished yet', 'Dropped and not-travelling children appear here.'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 56, 32, 32),
      child: Column(
        children: [
          Icon(icon, size: 52, color: MonitorColors.muted.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: MonitorColors.ink)),
          const SizedBox(height: 4),
          Text(sub, textAlign: TextAlign.center, style: const TextStyle(color: MonitorColors.muted, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _familyCard(ShiftWindow w, FamilyGroup f, int index, MonitorActions actions) {
    final isNext = _stage == Stage.waiting && index == 0;
    // Cards still to visit collapse to one line, except the next stop; the others are short anyway.
    final expanded = _stage != Stage.waiting || (isNext != _toggled.contains(f.key));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isNext ? w.color.withValues(alpha: 0.5) : MonitorColors.line, width: isNext ? 1.5 : 1),
        boxShadow: isNext
            ? [BoxShadow(color: w.color.withValues(alpha: 0.12), blurRadius: 14, offset: const Offset(0, 4))]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _stage == Stage.waiting
                ? () => setState(() => _toggled.contains(f.key) ? _toggled.remove(f.key) : _toggled.add(f.key))
                : null,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isNext ? w.color : w.color.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: Text('${index + 1}',
                        style: TextStyle(
                            color: isNext ? Colors.white : w.color, fontWeight: FontWeight.w800, fontSize: 13.5)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isNext)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text('NEXT STOP',
                                style: TextStyle(
                                    color: w.color, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                          ),
                        Text(f.parentName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: MonitorColors.ink)),
                        const SizedBox(height: 1),
                        Text(expanded ? f.address : f.names.join(', '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, color: MonitorColors.muted)),
                      ],
                    ),
                  ),
                  if (f.phone.isNotEmpty) ...[
                    _roundIcon(Icons.call_rounded, const Color(0xFF1D4ED8), 'Call parent', () => actions.call(f.phone)),
                    _roundIcon(Icons.chat_rounded, const Color(0xFF16A34A), 'WhatsApp parent', () => actions.whatsApp(f)),
                  ],
                  if (f.hasCoords)
                    _roundIcon(Icons.navigation_rounded, MonitorColors.byParent, 'Directions', () => actions.directions(f)),
                  if (_stage == Stage.waiting)
                    Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: MonitorColors.muted),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1, color: MonitorColors.line),
            for (var i = 0; i < f.students.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 14, endIndent: 14, color: MonitorColors.line),
              _studentRow(w, f.students[i], actions),
            ],
          ],
        ],
      ),
    );
  }

  Widget _roundIcon(IconData icon, Color color, String tip, VoidCallback onTap) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, color: color, size: 20),
      );

  Widget _studentRow(ShiftWindow w, dynamic s, MonitorActions actions) {
    final name = s['name']?.toString() ?? 'Student';
    final status = store.statusOf(s, w.key);
    final type = status?['event_type']?.toString();
    final at = _clock(status?['created_at']);
    final m = w.isMorning;
    // A parent's "Not on Bus" notice for this trip, while the child is still to be dealt with.
    final notice = _stage == Stage.waiting ? store.noticeFor(s, w.key) : null;
    final banner = notice == null ? null : _noticeBanner(w, s, notice);

    final info = Row(
      children: [
        Initials(name: name, size: 36, color: w.color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: MonitorColors.ink)),
              Text(
                  [
                    if ((s['grade']?.toString() ?? '').isNotEmpty) 'Grade ${s['grade']}',
                    if (type == 'pickup' && at.isNotEmpty) '${m ? 'Picked up' : 'Boarded'} $at',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: MonitorColors.muted)),
            ],
          ),
        ),
      ],
    );

    Widget buttons;
    switch (_stage) {
      case Stage.waiting when notice != null:
        // The parent said so in advance: confirming records it - "by parent" for a drop or pick-up,
        // "on leave" for a child who is not coming. If the child turns up anyway, pick them up.
        buttons = Row(
          children: [
            Expanded(
              child: _primary(
                w,
                notice == 'parent' ? Icons.family_restroom_rounded : Icons.event_busy_rounded,
                notice == 'parent' ? (m ? 'Confirm - parent drops' : 'Confirm - parent picks up') : 'Confirm - not coming',
                () => actions.mark(w, s, notice == 'parent' ? 'by_parent' : 'leave'),
                color: notice == 'parent' ? MonitorColors.byParent : MonitorColors.red,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 46,
              child: OutlinedButton(
                onPressed: () => actions.mark(w, s, 'pickup'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF475569),
                  side: const BorderSide(color: MonitorColors.line, width: 1.5),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(m ? 'Picked up' : 'Boarded', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        );
      case Stage.waiting:
        buttons = Row(
          children: [
            Expanded(
              child: _primary(
                w,
                m ? Icons.home_rounded : Icons.school_rounded,
                m ? 'Picked up' : 'Boarded',
                () => actions.mark(w, s, 'pickup'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 46,
              child: OutlinedButton(
                onPressed: () => actions.notTravelling(w, s),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF475569),
                  side: const BorderSide(color: MonitorColors.line, width: 1.5),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Not travelling', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        );
      case Stage.onBus:
        buttons = _primary(
          w,
          m ? Icons.school_rounded : Icons.home_rounded,
          m ? 'Dropped at school' : 'Dropped at home',
          () => actions.mark(w, s, 'dropoff'),
          color: MonitorColors.green,
        );
      case Stage.done:
        buttons = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusPill(text: StatusStyle.label(type, w.key), color: StatusStyle.color(type), icon: StatusStyle.icon(type)),
            if (at.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(at, style: const TextStyle(fontSize: 12, color: MonitorColors.muted)),
            ],
          ],
        );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: LayoutBuilder(builder: (context, box) {
        // Done rows and wide screens: one line. Phones: the buttons go full width under the name,
        // where a thumb can hit them on a moving bus.
        if (_stage == Stage.done || box.maxWidth >= 520) {
          final row = Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 12),
              if (_stage == Stage.done) buttons else SizedBox(width: _stage == Stage.waiting ? 330 : 220, child: buttons),
            ],
          );
          if (banner == null) return row;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [row, const SizedBox(height: 10), banner]);
        }
        // Phones: the parent's message sits between the name and the buttons, so it is read first.
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          info,
          if (banner != null) ...[const SizedBox(height: 10), banner],
          const SizedBox(height: 10),
          buttons,
        ]);
      }),
    );
  }

  /// The parent's message on the child's card: what happens on this trip, why, and their note.
  Widget _noticeBanner(ShiftWindow w, dynamic s, String notice) {
    final n = store.noticeOf(s) ?? const {};
    final parent = notice == 'parent';
    final color = parent ? MonitorColors.byParent : MonitorColors.red;
    final reason = '${n['reason'] ?? ''}';
    final note = '${n['comment'] ?? ''}'.trim();
    final text = parent
        ? (w.isMorning ? 'Parent will drop at school this morning' : 'Parent will pick up from school')
        : 'Not coming${reason.isNotEmpty && reason != 'Parent' ? ' - $reason' : ''}';
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.no_transfer_rounded, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Not on Bus: $text', style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
                if (note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('"$note"', style: const TextStyle(color: MonitorColors.ink, fontSize: 12.5)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _primary(ShiftWindow w, IconData icon, String label, VoidCallback onTap, {Color? color}) => SizedBox(
        height: 46,
        child: FilledButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          style: FilledButton.styleFrom(
            backgroundColor: color ?? w.color,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );

  /// "2026-10-09 06:12:33" -> "6:12 AM".
  String _clock(dynamic createdAt) {
    final s = createdAt?.toString() ?? '';
    final t = s.contains(' ') ? s.split(' ').last : s;
    return t.length >= 5 ? fmtTime(t.substring(0, 5)) : '';
  }
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
