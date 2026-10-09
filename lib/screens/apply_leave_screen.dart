import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';

/// Apply for Leave - the parent tells the bus a child will not ride it. Four plain choices cover the
/// real cases: Absent, I'll drop (morning), I'll pick up (evening), No bus today. The bus monitor sees
/// it straight away: today on the child's card, later days in her Leave list.
class ApplyLeaveScreen extends StatefulWidget {
  final List<dynamic> students;

  /// Opened from a child's card: that child is already chosen.
  final int? initialStudentId;

  const ApplyLeaveScreen({super.key, required this.students, this.initialStudentId});

  @override
  State<ApplyLeaveScreen> createState() => _ApplyLeaveScreenState();
}

class _C {
  static const navy = Color(0xFF1E3C72);
  static const ink = Color(0xFF0F172A);
  static const muted = Color(0xFF64748B);
  static const line = Color(0xFFE2E8F0);
  static const page = Color(0xFFF1F5F9);
  static const violet = Color(0xFF6D28D9);
  static const red = Color(0xFFDC2626);
  static const green = Color(0xFF15803D);
}

/// One of the four choices, and what it means for each trip.
class _Choice {
  final String key, title, sub, morning, evening;
  final IconData icon;
  final Color color;
  const _Choice(this.key, this.title, this.sub, this.icon, this.color, this.morning, this.evening);
}

const _choices = [
  _Choice('absent', 'Absent', 'Not coming', Icons.sick_rounded, _C.red, 'absent', 'absent'),
  _Choice('drop', "I'll drop", 'Morning only', Icons.directions_car_rounded, _C.violet, 'parent', 'bus'),
  _Choice('pickup', "I'll pick up", 'Evening only', Icons.home_rounded, _C.violet, 'bus', 'parent'),
  _Choice('nobus', 'No bus today', 'I drop and pick up', Icons.no_transfer_rounded, _C.navy, 'parent', 'parent'),
];

class _ApplyLeaveScreenState extends State<ApplyLeaveScreen> {
  final Set<int> _kids = {};
  DateTime _from = DateTime.now();
  DateTime _to = DateTime.now();
  String _day = 'today'; // today | tomorrow | range
  _Choice? _choice;
  String? _reason;
  bool _showNote = false;
  final _note = TextEditingController();
  bool _sending = false;
  String? _error;

  List<dynamic> _leaves = [];
  bool _loading = true;

  static const _reasons = ['Sick', 'Travel', 'Other'];

  @override
  void initState() {
    super.initState();
    final ids = widget.students.map((s) => int.tryParse('${s['id']}') ?? 0).where((i) => i > 0).toList();
    if (widget.initialStudentId != null) {
      _kids.add(widget.initialStudentId!);
    } else if (ids.length == 1) {
      _kids.add(ids.first);
    }
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ApiService.getLeaveRequests();
      if (!mounted) return;
      setState(() {
        _leaves = ((r['requests'] as List?) ?? []).where((n) => n is Map && n['state'] == 'active').toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  String _dayLabel(dynamic ymd) {
    final d = DateTime.tryParse('$ymd');
    if (d == null) return '$ymd';
    final now = DateTime.now();
    final diff = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return DateFormat('EEE d MMM').format(d);
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 60)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      helpText: 'Leave dates',
    );
    if (picked == null) return;
    if (picked.end.difference(picked.start).inDays >= 14) {
      setState(() => _error = 'Choose at most 14 days at a time.');
      return;
    }
    setState(() {
      _from = picked.start;
      _to = picked.end;
      _day = 'range';
      _error = null;
    });
  }

  Future<void> _apply() async {
    String? err;
    if (_kids.isEmpty) {
      err = 'Choose your child.';
    } else if (_choice == null) {
      err = 'Choose what is happening.';
    } else if (_choice!.key == 'absent' && _reason == null) {
      err = 'Choose a reason.';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    Map<String, dynamic> r;
    try {
      r = await ApiService.submitNotOnBus(
        studentIds: _kids.toList(),
        dateFrom: _ymd(_from),
        dateTo: _ymd(_to),
        morning: _choice!.morning,
        evening: _choice!.evening,
        reason: _choice!.key == 'absent' ? (_reason ?? '') : '',
        comment: _note.text.trim(),
      );
    } catch (_) {
      r = {'success': false, 'error': 'No connection. Please try again.'};
    }
    if (!mounted) return;
    setState(() => _sending = false);
    if (r['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Leave applied. The bus monitor can see it now.'),
        backgroundColor: _C.green,
      ));
      setState(() {
        _choice = null;
        _reason = null;
        _note.clear();
        _showNote = false;
      });
      _load();
    } else {
      setState(() => _error = (r['error'] ?? 'Could not apply. Please try again.').toString());
    }
  }

  Future<void> _cancel(dynamic n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this leave?'),
        content: Text('${n['student_name']} will be back on the bus for ${_dayLabel(n['leave_date']).toLowerCase()}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _C.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel leave'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    Map<String, dynamic> r;
    try {
      r = await ApiService.cancelNotOnBus(int.tryParse('${n['id']}') ?? 0);
    } catch (_) {
      r = {'success': false, 'error': 'No connection. Please try again.'};
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r['success'] == true ? 'Leave cancelled.' : (r['error'] ?? 'Could not cancel.').toString()),
      backgroundColor: r['success'] == true ? _C.green : _C.red,
    ));
    _load();
  }

  // ---------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final oneChild = widget.students.length == 1;
    final childName = oneChild ? '${widget.students.first['name'] ?? ''}' : null;
    return Scaffold(
      backgroundColor: _C.page,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Apply for Leave', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white, fontSize: 18)),
            if (childName != null && childName.isNotEmpty)
              Text(childName, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
          ],
        ),
        backgroundColor: _C.navy,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!oneChild) ...[_childPicker(), const SizedBox(height: 14)],
                    _dayPicker(),
                    const SizedBox(height: 18),
                    const Text("What's happening?",
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _C.ink)),
                    const SizedBox(height: 10),
                    _choiceGrid(),
                    if (_choice?.key == 'absent') ...[
                      const SizedBox(height: 14),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final r in _reasons)
                          _chip(r, _reason == r, () => setState(() {
                                _reason = r;
                                _error = null;
                              })),
                      ]),
                    ],
                    const SizedBox(height: 12),
                    if (_showNote)
                      TextField(
                        controller: _note,
                        maxLength: 200,
                        minLines: 1,
                        maxLines: 3,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Note for the monitor',
                          isDense: true,
                          counterText: '',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      )
                    else
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() => _showNote = true),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add note'),
                          style: TextButton.styleFrom(foregroundColor: _C.muted, padding: EdgeInsets.zero),
                        ),
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 6),
                      Text(_error!, style: const TextStyle(color: _C.red, fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _sending ? null : _apply,
                        style: FilledButton.styleFrom(
                          backgroundColor: _C.navy,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _sending
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Apply leave', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                      ),
                    ),
                    const SizedBox(height: 26),
                    ..._leaveList(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, bool on, VoidCallback onTap, {IconData? icon}) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFE8EEFB) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: on ? _C.navy : _C.line, width: on ? 1.5 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 16, color: on ? _C.navy : _C.muted), const SizedBox(width: 6)],
            Flexible(
              child: Text(text,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? _C.navy : _C.ink)),
            ),
          ]),
        ),
      );

  Widget _childPicker() => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in widget.students)
          _chip('${s['name'] ?? 'Child'}', _kids.contains(int.tryParse('${s['id']}')), () {
            final id = int.tryParse('${s['id']}') ?? 0;
            setState(() {
              _kids.contains(id) ? _kids.remove(id) : _kids.add(id);
              _error = null;
            });
          }, icon: Icons.person_rounded),
      ]);

  Widget _dayPicker() {
    final now = DateTime.now();
    final range = _day == 'range'
        ? (_from == _to ? DateFormat('EEE d MMM').format(_from) : '${DateFormat('d MMM').format(_from)} – ${DateFormat('d MMM').format(_to)}')
        : 'Dates';
    return Wrap(spacing: 8, runSpacing: 8, children: [
      _chip('Today', _day == 'today', () => setState(() {
            _day = 'today';
            _from = _to = now;
          })),
      _chip('Tomorrow', _day == 'tomorrow', () => setState(() {
            _day = 'tomorrow';
            _from = _to = now.add(const Duration(days: 1));
          })),
      _chip(range, _day == 'range', _pickDates, icon: Icons.calendar_month_rounded),
    ]);
  }

  Widget _choiceGrid() => LayoutBuilder(builder: (context, box) {
        const gap = 10.0;
        final w = (box.maxWidth - gap) / 2;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final c in _choices)
            SizedBox(
              width: w,
              child: InkWell(
                onTap: () => setState(() {
                  _choice = c;
                  _error = null;
                  if (c.key != 'absent') _reason = null;
                }),
                borderRadius: BorderRadius.circular(16),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _choice == c ? c.color.withValues(alpha: 0.08) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _choice == c ? c.color : _C.line, width: _choice == c ? 1.8 : 1),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(c.icon, color: _choice == c ? c.color : _C.muted, size: 26),
                    const SizedBox(height: 8),
                    Text(c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _choice == c ? c.color : _C.ink)),
                    const SizedBox(height: 2),
                    Text(c.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: _C.muted)),
                  ]),
                ),
              ),
            ),
        ]);
      });

  /// What a saved leave was, in the same words as the four choices.
  (String, Color) _leaveText(dynamic n) {
    final m = '${n['morning']}', e = '${n['evening']}';
    final why = '${n['reason'] ?? ''}';
    if (m == 'absent' && e == 'absent') return ('Absent${why.isNotEmpty && why != 'Absent' && why != 'Parent' ? ' · $why' : ''}', _C.red);
    if (m == 'parent' && e == 'bus') return ("I'll drop", _C.violet);
    if (m == 'bus' && e == 'parent') return ("I'll pick up", _C.violet);
    if (m == 'parent' && e == 'parent') return ('No bus', _C.navy);
    return ('${n['summary'] ?? 'Leave'}', _C.violet);
  }

  List<Widget> _leaveList() {
    if (_loading) return [const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))];
    if (_leaves.isEmpty) return [];
    final showNames = widget.students.length > 1;
    return [
      const Text('Applied leave', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _C.ink)),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.line)),
        child: Column(children: [
          for (var i = 0; i < _leaves.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: _C.line),
            Builder(builder: (_) {
              final n = _leaves[i];
              final (text, color) = _leaveText(n);
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(showNames ? '${_dayLabel(n['leave_date'])} · ${n['student_name']}' : _dayLabel(n['leave_date']),
                          style: const TextStyle(fontWeight: FontWeight.w700, color: _C.ink, fontSize: 14)),
                      const SizedBox(height: 3),
                      Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
                    ]),
                  ),
                  if (n['can_cancel'] == true)
                    IconButton(
                      tooltip: 'Cancel leave',
                      onPressed: () => _cancel(n),
                      icon: const Icon(Icons.close_rounded, color: _C.red),
                    ),
                ]),
              );
            }),
          ],
        ]),
      ),
    ];
  }
}
