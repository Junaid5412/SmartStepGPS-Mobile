import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';

/// "Not on Bus" - the parent tells the bus, ahead of time, that a child will not ride it: dropped or
/// collected by the parent, or not coming at all. There is no approval; the bus monitor sees it on the
/// child's card straight away. Replaces the old Leave screen.
class NotOnBusScreen extends StatefulWidget {
  final List<dynamic> students;

  /// Opened from a child's card: that child is already selected.
  final int? initialStudentId;

  const NotOnBusScreen({super.key, required this.students, this.initialStudentId});

  @override
  State<NotOnBusScreen> createState() => _NotOnBusScreenState();
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

class _NotOnBusScreenState extends State<NotOnBusScreen> {
  final Set<int> _kids = {};
  DateTime _from = DateTime.now();
  DateTime _to = DateTime.now();
  String _dayChoice = 'today'; // today | tomorrow | range
  String _morning = 'bus';
  String _evening = 'bus';
  String? _reason;
  final _note = TextEditingController();
  bool _sending = false;
  String? _formError;

  List<dynamic> _notices = [];
  bool _loadingList = true;

  static const _reasons = ['Sick', 'Absent', 'Travel', 'Other'];

  @override
  void initState() {
    super.initState();
    final ids = widget.students.map((s) => int.tryParse('${s['id']}') ?? 0).where((i) => i > 0).toList();
    if (widget.initialStudentId != null) {
      _kids.add(widget.initialStudentId!);
    } else if (ids.length == 1) {
      _kids.add(ids.first);
    }
    _loadNotices();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadNotices() async {
    try {
      final r = await ApiService.getLeaveRequests();
      if (!mounted) return;
      setState(() {
        _notices = (r['requests'] as List?) ?? [];
        _loadingList = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  bool get _needsReason => _morning == 'absent' || _evening == 'absent';

  void _setMorning(String v) => setState(() {
        _morning = v;
        _formError = null;
        // A child who is not at school in the morning cannot catch the bus home from school.
        if (v == 'absent' && _evening == 'bus') _evening = 'absent';
      });

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 60)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      helpText: 'Which days?',
    );
    if (picked == null) return;
    if (picked.end.difference(picked.start).inDays >= 14) {
      setState(() => _formError = 'Choose at most 14 days at a time.');
      return;
    }
    setState(() {
      _from = picked.start;
      _to = picked.end;
      _dayChoice = 'range';
      _formError = null;
    });
  }

  Future<void> _send() async {
    String? err;
    if (_kids.isEmpty) {
      err = 'Choose your child.';
    } else if (_morning == 'bus' && _evening == 'bus') {
      err = 'Change the morning or the evening trip.';
    } else if (_needsReason && _reason == null) {
      err = 'Choose a reason.';
    }
    if (err != null) {
      setState(() => _formError = err);
      return;
    }
    setState(() {
      _sending = true;
      _formError = null;
    });
    Map<String, dynamic> r;
    try {
      r = await ApiService.submitNotOnBus(
        studentIds: _kids.toList(),
        dateFrom: _ymd(_from),
        dateTo: _ymd(_to),
        morning: _morning,
        evening: _evening,
        reason: _needsReason ? (_reason ?? '') : '',
        comment: _note.text.trim(),
      );
    } catch (_) {
      r = {'success': false, 'error': 'No connection. Please try again.'};
    }
    if (!mounted) return;
    setState(() => _sending = false);
    if (r['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text((r['message'] ?? 'Sent. The bus monitor can see it now.').toString()),
        backgroundColor: _C.green,
      ));
      setState(() {
        _morning = 'bus';
        _evening = 'bus';
        _reason = null;
        _note.clear();
      });
      _loadNotices();
    } else {
      setState(() => _formError = (r['error'] ?? 'Could not send. Please try again.').toString());
    }
  }

  Future<void> _cancel(dynamic n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this notice?'),
        content: Text('${n['student_name']} will be back on the bus list for ${_dayLabel(n['leave_date'])}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _C.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel notice'),
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
      content: Text((r['message'] ?? r['error'] ?? '').toString()),
      backgroundColor: r['success'] == true ? _C.green : _C.red,
    ));
    _loadNotices();
  }

  String _dayLabel(dynamic ymd) {
    final d = DateTime.tryParse('$ymd');
    if (d == null) return '$ymd';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return DateFormat('EEE d MMM').format(d);
  }

  // ---------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.page,
      appBar: AppBar(
        title: const Text('Not on Bus', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
        backgroundColor: _C.navy,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _loadNotices,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _form(),
                    const SizedBox(height: 22),
                    const Text('My notices', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _C.ink)),
                    const SizedBox(height: 10),
                    ..._list(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _C.line),
        ),
        child: child,
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _C.muted)),
      );

  Widget _chip(String text, bool on, VoidCallback onTap, {IconData? icon}) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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

  Widget _tripPicker(String title, String value, ValueChanged<String> onChanged, bool morning) {
    final opts = [
      ('bus', Icons.directions_bus_rounded, 'By bus', _C.navy),
      ('parent', Icons.directions_car_rounded, morning ? "I'll drop" : "I'll pick up", _C.violet),
      ('absent', Icons.block_rounded, 'Not going', _C.red),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(title),
        Row(
          children: [
            for (var i = 0; i < opts.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () => onChanged(opts[i].$1),
                  borderRadius: BorderRadius.circular(14),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                    decoration: BoxDecoration(
                      color: value == opts[i].$1 ? opts[i].$4.withValues(alpha: 0.10) : Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: value == opts[i].$1 ? opts[i].$4 : _C.line, width: value == opts[i].$1 ? 1.6 : 1),
                    ),
                    child: Column(children: [
                      Icon(opts[i].$2, color: value == opts[i].$1 ? opts[i].$4 : _C.muted, size: 22),
                      const SizedBox(height: 4),
                      Text(opts[i].$3,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: value == opts[i].$1 ? FontWeight.w700 : FontWeight.w500,
                              color: value == opts[i].$1 ? opts[i].$4 : _C.ink)),
                    ]),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _form() {
    final now = DateTime.now();
    final rangeText = _dayChoice == 'range'
        ? (_from == _to
            ? DateFormat('EEE d MMM').format(_from)
            : '${DateFormat('d MMM').format(_from)} – ${DateFormat('d MMM').format(_to)}')
        : 'Choose dates';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Tell the bus', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _C.ink)),
          const SizedBox(height: 2),
          const Text('No approval needed - the bus monitor sees it straight away.',
              style: TextStyle(fontSize: 12.5, color: _C.muted)),
          const SizedBox(height: 16),

          if (widget.students.length > 1) ...[
            _label('Child'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in widget.students)
                _chip(s['name']?.toString() ?? 'Child', _kids.contains(int.tryParse('${s['id']}')), () {
                  final id = int.tryParse('${s['id']}') ?? 0;
                  setState(() {
                    _kids.contains(id) ? _kids.remove(id) : _kids.add(id);
                    _formError = null;
                  });
                }, icon: Icons.person_rounded),
            ]),
            const SizedBox(height: 16),
          ] else if (widget.students.isNotEmpty) ...[
            _label('Child'),
            Text(widget.students.first['name']?.toString() ?? 'Child',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _C.ink)),
            const SizedBox(height: 16),
          ],

          _label('Day'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _chip('Today', _dayChoice == 'today', () => setState(() {
                  _dayChoice = 'today';
                  _from = _to = now;
                })),
            _chip('Tomorrow', _dayChoice == 'tomorrow', () => setState(() {
                  _dayChoice = 'tomorrow';
                  _from = _to = now.add(const Duration(days: 1));
                })),
            _chip(rangeText, _dayChoice == 'range', _pickRange, icon: Icons.calendar_month_rounded),
          ]),
          const SizedBox(height: 16),

          _tripPicker('Morning - to school', _morning, _setMorning, true),
          const SizedBox(height: 14),
          _tripPicker('Evening - from school', _evening, (v) => setState(() {
                _evening = v;
                _formError = null;
              }), false),

          if (_needsReason) ...[
            const SizedBox(height: 16),
            _label('Reason'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in _reasons) _chip(r, _reason == r, () => setState(() {
                    _reason = r;
                    _formError = null;
                  })),
            ]),
          ],

          const SizedBox(height: 16),
          _label('Note for the monitor (optional)'),
          TextField(
            controller: _note,
            maxLength: 200,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'Dentist at 8, I will bring him',
              isDense: true,
              counterText: '',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),

          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(_formError!, style: const TextStyle(color: _C.red, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded),
              label: Text(_sending ? 'Sending…' : 'Send to the bus', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              style: FilledButton.styleFrom(
                backgroundColor: _C.navy,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _list() {
    if (_loadingList) {
      return [const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))];
    }
    if (_notices.isEmpty) {
      return [
        _card(
          child: const Row(children: [
            Icon(Icons.directions_bus_rounded, color: _C.muted),
            SizedBox(width: 12),
            Expanded(child: Text('No notices. Your children are on the bus as usual.', style: TextStyle(color: _C.muted))),
          ]),
        ),
      ];
    }
    return [
      for (final n in _notices)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: _noticeCard(n)),
    ];
  }

  Widget _tripTag(String trip, String choice) {
    final morning = trip == 'AM';
    final (String text, Color c) = switch (choice) {
      'parent' => (morning ? 'Parent drops' : 'Parent picks up', _C.violet),
      'absent' => ('Not going', _C.red),
      _ => ('By bus', _C.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
      child: Text('$trip: $text', style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }

  Widget _noticeCard(dynamic n) {
    final state = (n['state'] ?? (n['status'] == 'rejected' ? 'cancelled' : 'active')).toString();
    final (String stText, Color stColor) = switch (state) {
      'cancelled' => ('Cancelled', _C.muted),
      'past' => ('Past', _C.muted),
      _ => ('Sent', _C.green),
    };
    final reason = (n['reason'] ?? '').toString();
    final note = (n['comment'] ?? '').toString();
    return Opacity(
      opacity: state == 'active' ? 1 : 0.6,
      child: _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('${n['student_name'] ?? ''} · ${_dayLabel(n['leave_date'])}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: _C.ink)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: stColor.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
                child: Text(stText, style: TextStyle(color: stColor, fontSize: 11.5, fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _tripTag('AM', (n['morning'] ?? 'absent').toString()),
              _tripTag('PM', (n['evening'] ?? 'absent').toString()),
            ]),
            if ((reason.isNotEmpty && reason != 'Parent') || note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                [if (reason.isNotEmpty && reason != 'Parent') reason, if (note.isNotEmpty) '"$note"'].join(' · '),
                style: const TextStyle(color: _C.muted, fontSize: 13),
              ),
            ],
            if (n['can_cancel'] == true) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _cancel(n),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Cancel'),
                  style: TextButton.styleFrom(foregroundColor: _C.red),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
