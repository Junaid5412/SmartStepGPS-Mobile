import 'package:flutter/material.dart';
import '../services/module_watcher.dart';

/// Wraps one module's screen. While the school has the module switched on it is just [child]; the moment
/// the school switches it off on the portal - even with the screen open - [child] is removed (its timers and
/// requests stop) and a clear message takes its place, then the app returns to the dashboard.
class ModuleGate extends StatefulWidget {
  final String moduleKey;
  final String title;
  final Widget child;

  const ModuleGate({Key? key, required this.moduleKey, required this.title, required this.child}) : super(key: key);

  @override
  State<ModuleGate> createState() => _ModuleGateState();
}

class _ModuleGateState extends State<ModuleGate> {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    ModuleWatcher.instance.addListener(_changed);
  }

  @override
  void dispose() {
    ModuleWatcher.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final on = ModuleWatcher.instance.isOn(widget.moduleKey);
    setState(() {});
    if (!on && !_closing) {
      _closing = true;
      // Leave the explanation on screen for a moment, then go back to the dashboard.
      Future.delayed(const Duration(milliseconds: 2200), () {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (!ModuleWatcher.instance.isOn(widget.moduleKey) && route != null && route.isCurrent) {
          Navigator.of(context).maybePop();
        }
      });
    }
    if (on) _closing = false;
  }

  @override
  Widget build(BuildContext context) {
    if (ModuleWatcher.instance.isOn(widget.moduleKey)) return widget.child;
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF1E3C72),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(color: Color(0xFFF1F5F9), shape: BoxShape.circle),
                child: const Icon(Icons.lock_outline_rounded, size: 34, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
              Text(
                '${widget.title} is not available',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
              ),
              const SizedBox(height: 6),
              const Text(
                'The school has turned this feature off.\nPlease contact the school for details.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B), height: 1.4),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1E3C72)),
                child: const Text('Back to home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
