import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import 'map_screen.dart';
import 'login_screen.dart';
import 'attendance_screen.dart';
import 'leave_screen.dart';
import 'announcements_screen.dart';
import 'parent_profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ParentDashboard extends StatefulWidget {
  const ParentDashboard({Key? key}) : super(key: key);

  @override
  _ParentDashboardState createState() => _ParentDashboardState();
}

class _ParentDashboardState extends State<ParentDashboard> {
  List<dynamic> _students = [];
  bool _isLoading = true;
  String _userName = 'Parent';
  Map<String, bool> _modules = {'attendance': true, 'bus_tracking': true, 'announcements': true, 'leave': true};

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadSettings();
    _fetchStudents();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _userName = prefs.getString('user_name') ?? 'Parent');
  }

  Future<void> _loadSettings() async {
    try {
      final res = await ApiService.getSettings();
      if (res['success'] == true && res['modules'] != null) {
        setState(() {
          _modules = {
            'attendance': res['modules']['attendance'] ?? true,
            'bus_tracking': res['modules']['bus_tracking'] ?? true,
            'announcements': res['modules']['announcements'] ?? true,
            'leave': res['modules']['leave'] ?? true,
          };
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchStudents() async {
    try {
      final res = await ApiService.getParentStudents();
      if (res['success'] == true) {
        setState(() => _students = res['students'] ?? []);
      } else if (res['error'] == 'Invalid token' || res['error'] == 'No token provided') {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
        return;
      }
    } catch (e) {
      debugPrint('Error: $e');
    }
    setState(() => _isLoading = false);
  }

  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  void _showStudentPicker(String title, Function(Map<String, dynamic>) onSelect) {
    if (_students.length == 1) { onSelect(Map<String, dynamic>.from(_students[0])); return; }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
          Padding(padding: const EdgeInsets.all(16), child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          ..._students.map((s) => ListTile(
            leading: CircleAvatar(backgroundColor: const Color(0xFFE3F2FD), child: Text((s['name'] ?? '?')[0].toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1565C0)))),
            title: Text(s['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('Grade: ${s['grade'] ?? 'N/A'}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () { Navigator.pop(ctx); onSelect(Map<String, dynamic>.from(s)); },
          )).toList(),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      body: _isLoading
        ? const Center(child: CircularProgressIndicator(color: Color(0xFF1565C0)))
        : CustomScrollView(
            slivers: [
              // Gradient AppBar
              SliverAppBar(
                expandedHeight: 180,
                floating: false,
                pinned: true,
                backgroundColor: const Color(0xFF1565C0),
                iconTheme: const IconThemeData(color: Colors.white),
                actions: [
                  IconButton(icon: const Icon(Icons.refresh, color: Colors.white), onPressed: () { _fetchStudents(); _loadSettings(); }),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1565C0), Color(0xFF0D47A1), Color(0xFF1A237E)]),
                    ),
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(56, 16, 20, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text('Welcome back,', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14)),
                            const SizedBox(height: 4),
                            Text(_userName, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(20)),
                              child: Text('${_students.length} ${_students.length == 1 ? 'Child' : 'Children'} Enrolled', style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Body
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Module Grid
                      _buildModuleGrid(),
                      const SizedBox(height: 24),

                      // Students
                      Row(
                        children: [
                          Container(width: 4, height: 20, decoration: BoxDecoration(color: const Color(0xFF1565C0), borderRadius: BorderRadius.circular(2))),
                          const SizedBox(width: 8),
                          const Text('My Children', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF1A237E))),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_students.isEmpty)
                        _buildEmptyState()
                      else
                        ..._students.map((s) => _buildStudentCard(s)).toList(),
                    ],
                  ),
                ),
              ),
            ],
          ),
      drawer: _buildDrawer(),
    );
  }

  Widget _buildModuleGrid() {
    final modules = <Widget>[];
    if (_modules['attendance'] == true) {
      modules.add(_buildModuleCard('Attendance', Icons.fact_check_rounded, const [Color(0xFFFF9800), Color(0xFFF57C00)], () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceScreen(students: _students)));
      }));
    }
    if (_modules['bus_tracking'] == true) {
      modules.add(_buildModuleCard('Bus Tracking', Icons.gps_fixed_rounded, const [Color(0xFF4CAF50), Color(0xFF2E7D32)], () {
        if (_students.isNotEmpty) {
          _showStudentPicker('Select Child to Track', (student) {
            if (student['device_id'] != null) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => MapScreen(student: student)));
            } else {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No GPS device linked.')));
            }
          });
        }
      }));
    }
    if (_modules['announcements'] == true) {
      modules.add(_buildModuleCard('Notices', Icons.campaign_rounded, const [Color(0xFF2196F3), Color(0xFF1565C0)], () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const AnnouncementsScreen()));
      }));
    }
    if (_modules['leave'] == true) {
      modules.add(_buildModuleCard('Leave', Icons.event_busy_rounded, const [Color(0xFFE53935), Color(0xFFC62828)], () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => LeaveScreen(students: _students)));
      }));
    }

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      childAspectRatio: 1.5,
      children: modules,
    );
  }

  Widget _buildModuleCard(String title, IconData icon, List<Color> gradient, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: gradient),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: gradient[0].withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 6))],
        ),
        child: Stack(
          children: [
            Positioned(right: -10, bottom: -10, child: Icon(icon, size: 70, color: Colors.white.withOpacity(0.15))),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 28, color: Colors.white),
                  const SizedBox(height: 8),
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStudentCard(dynamic student) {
    final lastEvent = student['latest_event'];
    String statusText = 'No updates';
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.info_outline;

    if (lastEvent != null && lastEvent is Map) {
      String type = lastEvent['event_type']?.toString() ?? '';
      if (type == 'pickup') { statusText = 'Picked up'; statusColor = const Color(0xFF2196F3); statusIcon = Icons.arrow_upward; }
      if (type == 'dropoff') { statusText = 'Dropped off'; statusColor = const Color(0xFF4CAF50); statusIcon = Icons.arrow_downward; }
      if (type == 'absent') { statusText = 'Absent'; statusColor = const Color(0xFFE53935); statusIcon = Icons.close; }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF1A237E)]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(child: Text((student['name'] ?? '?')[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold))),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(student['name'] ?? 'Unknown', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text('Grade ${student['grade'] ?? 'N/A'}  |  ${student['bus_name'] ?? 'No Bus'}', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: statusColor.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(statusIcon, size: 13, color: statusColor),
                const SizedBox(width: 4),
                Text(statusText, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(40),
      child: Column(children: [
        Icon(Icons.school_outlined, size: 60, color: Colors.grey[300]),
        const SizedBox(height: 12),
        Text('No students assigned', style: TextStyle(fontSize: 16, color: Colors.grey[400], fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1565C0), Color(0xFF1A237E)]),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.5), width: 2)),
                  child: const CircleAvatar(radius: 30, backgroundColor: Colors.white24, child: Icon(Icons.person, size: 36, color: Colors.white)),
                ),
                const SizedBox(height: 14),
                Text(_userName, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Parent Account', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _drawerItem(Icons.home_rounded, 'Home', () => Navigator.pop(context)),
                _drawerItem(Icons.person_outline_rounded, 'My Profile & Settings', () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ParentProfileScreen())).then((_) => _loadProfile());
                }),
                _drawerItem(Icons.info_rounded, 'About Us', () { Navigator.pop(context); launchUrl(Uri.parse('https://gps.khanhub.site/about.html')); }),
                _drawerItem(Icons.privacy_tip_rounded, 'Privacy Policy', () { Navigator.pop(context); launchUrl(Uri.parse('https://gps.khanhub.site/privacy.html')); }),
                _drawerItem(Icons.description_rounded, 'Terms & Conditions', () { Navigator.pop(context); launchUrl(Uri.parse('https://gps.khanhub.site/terms.html')); }),
                const Divider(height: 1),
                _drawerItem(Icons.logout_rounded, 'Logout', _logout, isDestructive: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _drawerItem(IconData icon, String title, VoidCallback onTap, {bool isDestructive = false}) {
    return ListTile(
      leading: Icon(icon, color: isDestructive ? Colors.redAccent : const Color(0xFF546E7A), size: 22),
      title: Text(title, style: TextStyle(color: isDestructive ? Colors.redAccent : Colors.black87, fontWeight: FontWeight.w500)),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    );
  }
}
