import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/app_errors.dart';
import '../services/push_service.dart';
import '../widgets/custom_loading.dart';

/// The family's notifications (the bell on the dashboard): picked up, dropped off, absent... newest first.
/// Opening the screen marks them all as read.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({Key? key}) : super(key: key);

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppErrors.screen = 'notifications';
    PushService.instance.addListener(_onPush);
    _load(markRead: true);
  }

  @override
  void dispose() {
    PushService.instance.removeListener(_onPush);
    super.dispose();
  }

  // A new one arrived while the list is open: show it.
  void _onPush() {
    if (mounted && PushService.instance.unread > 0) _load(markRead: true, quiet: true);
  }

  Future<void> _load({bool markRead = false, bool quiet = false}) async {
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final res = await ApiService.getNotifications();
      if (!mounted) return;
      if (res['success'] == true) {
        final list = (res['notifications'] as List? ?? []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        setState(() { _items = list; _loading = false; _error = null; });
        if (markRead && list.any((n) => n['read'] != true)) {
          await ApiService.postNotifications({'action': 'read', 'all': true});
          PushService.instance.markAllRead();
        }
      } else {
        setState(() { _loading = false; _error = '${res['error'] ?? 'Could not load notifications.'}'; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'No connection. Pull down to try again.'; });
    }
  }

  static const Map<String, List<dynamic>> _look = {
    'pickup': [Icons.directions_bus_rounded, Color(0xFF1565C0)],
    'dropoff': [Icons.where_to_vote_rounded, Color(0xFF2E7D32)],
    'absent': [Icons.person_off_rounded, Color(0xFFC62828)],
    'leave': [Icons.event_busy_rounded, Color(0xFF6A1B9A)],
    'by_parent': [Icons.family_restroom_rounded, Color(0xFF00838F)],
  };

  String _when(String raw) {
    final t = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (t == null) return raw;
    final now = DateTime.now();
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final time = DateFormat('h:mm a').format(t);
    if (day == today) return 'Today, $time';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday, $time';
    return '${DateFormat('d MMM').format(t)}, $time';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: _loading
          ? const CustomLoading(message: 'Loading notifications...')
          : RefreshIndicator(
              onRefresh: () => _load(markRead: true, quiet: true),
              child: _items.isEmpty ? _empty() : ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: _items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _tile(_items[i]),
              ),
            ),
    );
  }

  Widget _empty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(_error == null ? Icons.notifications_none_rounded : Icons.cloud_off_rounded, size: 64, color: const Color(0xFF90A4AE)),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Text(
            _error ?? 'No notifications yet.\nYou will be told here when your child is picked up or dropped off.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF546E7A), fontSize: 14.5, height: 1.45),
          ),
        ),
      ],
    );
  }

  Widget _tile(Map<String, dynamic> n) {
    final look = _look['${n['kind']}'] ?? const [Icons.notifications_rounded, Color(0xFF455A64)];
    final color = look[1] as Color;
    final unread = n['read'] != true;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: unread ? color.withValues(alpha: 0.45) : const Color(0xFFE3E8EE)),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(look[0] as IconData, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('${n['title'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Color(0xFF0D1B2A)))),
                    if (unread) Container(width: 9, height: 9, margin: const EdgeInsets.only(left: 8), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('${n['body'] ?? ''}', style: const TextStyle(fontSize: 13.5, color: Color(0xFF455A64), height: 1.4)),
                const SizedBox(height: 6),
                Text(_when('${n['created_at'] ?? ''}'), style: const TextStyle(fontSize: 12, color: Color(0xFF90A4AE), fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
