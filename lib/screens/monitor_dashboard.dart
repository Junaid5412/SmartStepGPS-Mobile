import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../widgets/custom_loading.dart';
import 'about_screen.dart';
import 'announcements_screen.dart';
import 'login_screen.dart';
import 'monitor/monitor_actions.dart';
import 'monitor/monitor_home.dart';
import 'monitor/monitor_profile.dart';
import 'monitor/monitor_route_view.dart';
import 'monitor/monitor_store.dart';
import 'monitor/phone_location.dart';
import 'terms_screen.dart';

/// The bus monitor's app: Home (today at a glance), Attendance (one shift at a time, unlocked only
/// during that shift), Notices and Profile. Phones get a bottom bar; tablets and landscape a side rail.
class MonitorDashboard extends StatefulWidget {
  const MonitorDashboard({Key? key, this.store}) : super(key: key);

  /// Pre-filled roster, for tests and previews; the app always loads its own.
  @visibleForTesting
  final MonitorStore? store;

  @override
  State<MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends State<MonitorDashboard> {
  late final MonitorStore _store = widget.store ?? MonitorStore();
  int _tab = 0;
  String? _shiftKey; // shift shown on the Attendance tab; follows the current shift until chosen

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
    SharedPreferences.getInstance().then((p) {
      final name = p.getString('user_name');
      if (name != null && !_store.loaded) _store.staffName = name;
    });
    if (widget.store == null) _store.load();
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    PhoneLocation.instance.stop();
    _store.dispose();
    super.dispose();
  }

  void _onStore() {
    // While a shift is open: the phone's position for the map, and the bus's backup position for parents.
    if (_store.loaded) PhoneLocation.instance.sync(_store);
    if (_store.unauthorized) {
      _store.unauthorized = false;
      _logout();
    }
  }

  void _openShift(String key) => setState(() {
        _shiftKey = key;
        _tab = 1; // Shift
      });

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await ApiService.clearToken();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need your username and password to sign in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MonitorColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok == true) _logout();
  }

  /// Raises a real deletion request for the school administrator to review.
  Future<void> _requestAccountDeletion() async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account', style: TextStyle(color: Colors.red)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your request will be sent to your school administrator for review.\n\n'
                'Once approved, your staff account and personal details are permanently deleted '
                'and you will be signed out.\n\n'
                'Attendance records you submitted are kept by the school as safeguarding records.',
                style: TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: reasonCtrl,
                maxLength: 255,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Request Deletion', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    Map<String, dynamic> res;
    try {
      res = await ApiService.requestAccountDeletion(reason: reasonCtrl.text.trim());
    } catch (e) {
      res = {'success': false, 'message': 'Could not reach the server. Please try again.'};
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // the spinner

    final ok = res['success'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text((res['message'] as String?) ??
          (ok
              ? 'Your deletion request has been submitted for review.'
              : 'Could not submit your request. Please contact your school.')),
      backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
      duration: const Duration(seconds: 5),
    ));
  }

  static const _destinations = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.route_outlined, Icons.route_rounded, 'Shift'),
    (Icons.campaign_outlined, Icons.campaign_rounded, 'Notices'),
    (Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final actions = MonitorActions(context, _store);
        final Widget body;
        if (_store.loading && !_store.loaded) {
          body = const CustomLoading(message: 'Loading your bus...', primaryColor: MonitorColors.navy);
        } else {
          final shiftKey = _shiftKey ?? _store.focus?.key ?? 'morning';
          body = IndexedStack(
            index: _tab,
            children: [
              MonitorHome(store: _store, onOpenShift: _openShift, onCall: actions.call),
              // The one place attendance is marked: map or list while a shift is open, the
              // countdown when it is not. Location is followed only while this tab is showing.
              MonitorRouteView(
                store: _store,
                active: _tab == 1,
                shiftKey: shiftKey,
                onSwitchShift: (k) => setState(() => _shiftKey = k),
              ),
              const AnnouncementsScreen(),
              MonitorProfile(
                store: _store,
                onCall: actions.call,
                onRefresh: () {
                  _store.load();
                  setState(() => _tab = 0);
                },
                onTerms: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsScreen())),
                onPrivacy: () => launchUrl(Uri.parse('https://smartstepgps.cloud/privacy.html')),
                onAbout: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen())),
                onDeleteAccount: _requestAccountDeletion,
                onSignOut: _confirmLogout,
              ),
            ],
          );
        }

        return LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= 840;
          return Scaffold(
            backgroundColor: MonitorColors.page,
            body: wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _tab,
                        onDestinationSelected: (i) => setState(() => _tab = i),
                        labelType: NavigationRailLabelType.all,
                        backgroundColor: Colors.white,
                        indicatorColor: MonitorColors.navy.withValues(alpha: 0.12),
                        leading: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Image.asset('assets/images/logo.png',
                              width: 40,
                              height: 40,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.directions_bus_rounded, color: MonitorColors.navy, size: 32)),
                        ),
                        destinations: [
                          for (final (icon, sel, label) in _destinations)
                            NavigationRailDestination(icon: Icon(icon), selectedIcon: Icon(sel), label: Text(label)),
                        ],
                      ),
                      const VerticalDivider(width: 1, color: MonitorColors.line),
                      Expanded(child: body),
                    ],
                  )
                : body,
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    backgroundColor: Colors.white,
                    indicatorColor: MonitorColors.navy.withValues(alpha: 0.12),
                    height: 66,
                    // Five tabs on a narrow phone: labels only under the selected one, so none wrap.
                    labelBehavior: box.maxWidth < 380
                        ? NavigationDestinationLabelBehavior.onlyShowSelected
                        : NavigationDestinationLabelBehavior.alwaysShow,
                    destinations: [
                      for (final (icon, sel, label) in _destinations)
                        NavigationDestination(icon: Icon(icon), selectedIcon: Icon(sel), label: label),
                    ],
                  ),
          );
        });
      },
    );
  }
}
