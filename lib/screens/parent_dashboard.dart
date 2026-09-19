import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../widgets/custom_loading.dart';
import 'map_screen.dart';
import 'login_screen.dart';
import 'attendance_screen.dart';
import 'leave_screen.dart';
import 'announcements_screen.dart';
import 'parent_profile_screen.dart';
import 'terms_screen.dart';
import 'privacy_screen.dart';
import 'about_screen.dart';

class ParentDashboard extends StatefulWidget {
  const ParentDashboard({Key? key}) : super(key: key);

  @override
  _ParentDashboardState createState() => _ParentDashboardState();
}

class _ParentDashboardState extends State<ParentDashboard> {
  List<dynamic> _students = [];
  bool _isLoading = true;
  String _userName = 'Parent';
  String _companyName = 'Smart Step GPS';
  String _companyTagline = 'Safe & Smart School Transit';
  String _logoUrl = '';
  List<dynamic> _banners = [];
  Map<String, bool> _modules = {'attendance': true, 'bus_tracking': true, 'announcements': true, 'leave': true};

  late PageController _pageController;
  int _currentBannerPage = 0;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.93);
    _startBannerTimer();
    _loadProfile();
    _loadSettings();
    _fetchStudents();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startBannerTimer() {
    _bannerTimer?.cancel();
    _bannerTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_pageController.hasClients) {
        final count = _displayBanners.length;
        if (count > 1) {
          int nextPage = (_currentBannerPage + 1) % count;
          _pageController.animateToPage(
            nextPage,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOutCubic,
          );
        }
      }
    });
  }

  List<Map<String, dynamic>> get _displayBanners {
    if (_banners.isNotEmpty) {
      return _banners.map((b) => Map<String, dynamic>.from(b as Map)).toList();
    }
    return [
      {
        'title': 'Live Bus Tracking',
        'subtitle': 'Watch your child\'s school bus travel in real-time with live speed and ETA',
        'badge': 'REAL-TIME GPS',
        'icon': 'gps_fixed',
        'gradient': ['#1565C0', '#1E88E5'],
      },
      // Describes only what the app actually does. This card used to advertise RFID boarding
      // verification and instant arrival alerts. Neither exists: boarding is recorded by the bus
      // monitor by hand, there is no RFID hardware, and push is not implemented at all (no
      // firebase_messaging, no google-services.json). Both Google Play and Apple reject apps that
      // advertise features they do not have, and a parent trusting an arrival alert that never
      // comes is worse off than one who knows to check the screen.
      {
        'title': 'Boarding Record',
        'subtitle': 'Every pick-up and drop-off, recorded by the bus monitor and visible to you',
        'badge': 'STUDENT SAFETY',
        'icon': 'security',
        'gradient': ['#00897B', '#26A69A'],
      },
      {
        'title': 'Easy Leave Notices',
        'subtitle': 'Inform the school bus driver and monitor in advance with 1-tap requests',
        'badge': 'ATTENDANCE',
        'icon': 'event_available',
        'gradient': ['#5E35B1', '#7E57C2'],
      },
    ];
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _userName = prefs.getString('user_name') ?? 'Parent');
    
    // Silently sync the latest name from the server in case it was changed by admin on the website
    try {
      final res = await ApiService.getProfile();
      if (res['success'] == true && res['profile'] != null) {
        final dName = res['profile']['display_name'];
        if (dName != null && dName.toString().isNotEmpty) {
          setState(() => _userName = dName);
          await prefs.setString('user_name', dName);
        }
      }
    } catch (e) { debugPrint('Parent dashboard: profile load failed: $e'); }
  }

  Future<void> _loadSettings() async {
    try {
      final res = await ApiService.getSettings();
      if (res['success'] == true) {
        setState(() {
          _companyName = res['company_name'] ?? res['app_name'] ?? _companyName;
          _companyTagline = res['company_tagline'] ?? _companyTagline;
          _logoUrl = res['logo'] ?? _logoUrl;
          if (res['banners'] != null && (res['banners'] as List).isNotEmpty) {
            _banners = res['banners'];
          }
          if (res['modules'] != null) {
            _modules = {
              'attendance': res['modules']['attendance'] ?? true,
              'bus_tracking': res['modules']['bus_tracking'] ?? true,
              'announcements': res['modules']['announcements'] ?? true,
              'leave': res['modules']['leave'] ?? true,
            };
          }
        });
      }
    } catch (e) { debugPrint('Parent dashboard: settings load failed: $e'); }
  }

  Future<void> _fetchStudents() async {
    try {
      final res = await ApiService.getParentStudents();
      if (res['success'] == true) {
        setState(() => _students = res['students'] ?? []);
      } else if (res['error'] == 'Invalid token' || res['error'] == 'No token provided') {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
        await ApiService.clearToken();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
        return;
      }
    } catch (e) {
      debugPrint('Error: $e');
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await ApiService.clearToken();
    // Clearing storage is a few awaits; if the screen went away in that window, navigating from a
    // dead context throws. The session is already cleared either way, which is what matters.
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Color _parseHexColor(dynamic hexStr, Color fallback) {
    if (hexStr == null) return fallback;
    try {
      String clean = hexStr.toString().replaceAll('#', '').trim();
      if (clean.length == 6) {
        return Color(int.parse('0xFF$clean'));
      } else if (clean.length == 8) {
        return Color(int.parse('0x$clean'));
      }
    } catch (_) { /* malformed colour from the server - the caller's fallback colour is used */ }
    return fallback;
  }

  IconData _resolveIcon(dynamic iconName) {
    switch (iconName?.toString()) {
      case 'security':
        return Icons.verified_user_rounded;
      case 'event_available':
        return Icons.event_available_rounded;
      case 'announcement':
      case 'campaign':
        return Icons.campaign_rounded;
      case 'directions_bus':
        return Icons.directions_bus_rounded;
      case 'gps_fixed':
      default:
        return Icons.gps_fixed_rounded;
    }
  }

  Widget _buildBannerCarousel() {
    final banners = _displayBanners;
    if (banners.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        SizedBox(
          height: 155,
          child: PageView.builder(
            controller: _pageController,
            itemCount: banners.length,
            onPageChanged: (index) {
              setState(() => _currentBannerPage = index);
            },
            itemBuilder: (context, index) {
              final item = banners[index];
              final title = item['title'] ?? 'Smart Step GPS';
              final subtitle = item['subtitle'] ?? '';
              final badge = item['badge'] ?? 'FEATURED';
              final icon = _resolveIcon(item['icon']);

              List<dynamic> gradList = item['gradient'] is List ? item['gradient'] : ['#1565C0', '#1E88E5'];
              Color c1 = _parseHexColor(gradList.isNotEmpty ? gradList[0] : null, const Color(0xFF1565C0));
              Color c2 = _parseHexColor(gradList.length > 1 ? gradList[1] : null, const Color(0xFF1E88E5));

              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [c1, c2],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: c1.withOpacity(0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    children: [
                      // Translucent background decorative icon
                      Positioned(
                        right: -15,
                        bottom: -15,
                        child: Icon(
                          icon,
                          size: 110,
                          color: Colors.white.withOpacity(0.12),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Badge pill
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.22),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                badge.toString().toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Banner Title
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.3,
                              ),
                            ),
                            const SizedBox(height: 4),
                            // Banner Subtitle
                            Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 12,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        // Dots indicator
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(banners.length, (idx) {
            final isActive = idx == _currentBannerPage;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: isActive ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: isActive ? const Color(0xFF1565C0) : Colors.grey[350],
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildCompanyHeader() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1565C0), Color(0xFF0D47A1), Color(0xFF1A237E)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Color(0x331565C0),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Company Brand Badge & Name Row (Below Menu)
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(4),
                child: ClipOval(
                  child: Image.asset(
                    'assets/images/logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.directions_bus_rounded,
                      color: Color(0xFF1565C0),
                      size: 30,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _companyName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _companyTagline,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 12,
                        letterSpacing: 0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            height: 1,
            color: Colors.white.withOpacity(0.15),
          ),
          const SizedBox(height: 14),
          // Parent Greeting Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome back,',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _userName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.3)),
                ),
                child: Text(
                  '${_students.length} ${_students.length == 1 ? 'Child' : 'Children'} Enrolled',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: 'Menu',
            icon: const Icon(Icons.menu_rounded, color: Colors.white, size: 26),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Text(
          _companyName,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
            letterSpacing: 0.5,
          ),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            onPressed: () {
              _loadProfile();
              _fetchStudents();
              _loadSettings();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const CustomLoading(message: 'Loading your dashboard...')
          : RefreshIndicator(
              onRefresh: () async {
                await _loadProfile();
                await _fetchStudents();
                await _loadSettings();
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Company Brand & Welcome Header (Positioned Below Sidebar Menu)
                    _buildCompanyHeader(),
                    const SizedBox(height: 18),

                    // Slideshow Banners
                    _buildBannerCarousel(),
                    const SizedBox(height: 20),

                    // Module Grid & Children
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildModuleGrid(),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Container(
                                width: 4,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1565C0),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'My Children',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1A237E),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_students.isEmpty)
                            _buildEmptyState()
                          else
                            ..._students.map((s) => _buildStudentCard(s)).toList(),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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
          final student = _students.first;
          if (student['device_id'] != null) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => MapScreen(student: student)));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No GPS device linked.')));
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No children found.')));
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
    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceScreen(students: _students)));
      },
      child: Container(
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
                child: Center(
                  child: Text(
                    (student['name'] ?? '?')[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ),
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
              const Icon(Icons.chevron_right_rounded, color: Colors.grey, size: 24),
            ],
          ),
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
            padding: const EdgeInsets.fromLTRB(24, 70, 24, 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0D47A1), Color(0xFF1976D2)],
              ),
              image: DecorationImage(
                image: AssetImage('assets/images/pattern.png'), // Optional subtle pattern if available
                fit: BoxFit.cover,
                opacity: 0.1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withOpacity(0.8), width: 2),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 10, offset: const Offset(0, 4))
                        ]
                      ),
                      child: const CircleAvatar(
                        radius: 32,
                        backgroundColor: Colors.white24,
                        child: Icon(Icons.person, size: 36, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(_userName, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(12)),
                  child: Text('$_companyName • Parent Portal', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                )
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: const Color(0xFFF8FAFC),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10),
                children: [
                  _drawerItem(Icons.dashboard_rounded, 'Dashboard', () => Navigator.pop(context)),
                  _drawerItem(Icons.manage_accounts_rounded, 'Profile & Settings', () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const ParentProfileScreen())).then((_) => _loadProfile());
                  }),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 20), child: Divider(height: 24, color: Color(0xFFE2E8F0))),
                  _drawerSectionTitle('Legal & Info'),
                  _drawerItem(Icons.gavel_rounded, 'Terms & Conditions', () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsScreen()));
                  }),
                  _drawerItem(Icons.privacy_tip_rounded, 'Privacy Policy', () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyScreen()));
                  }),
                  _drawerItem(Icons.business_rounded, 'About Us', () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen()));
                  }),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 20), child: Divider(height: 24, color: Color(0xFFE2E8F0))),
                  _drawerItem(Icons.logout_rounded, 'Sign Out', _logout, isDestructive: true),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _drawerSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, top: 8, bottom: 8),
      child: Text(title, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
    );
  }

  Widget _drawerItem(IconData icon, String title, VoidCallback onTap, {bool isDestructive = false}) {
    return ListTile(
      leading: Icon(icon, color: isDestructive ? Colors.redAccent : const Color(0xFF475569), size: 24),
      title: Text(title, style: TextStyle(color: isDestructive ? Colors.redAccent : const Color(0xFF1E293B), fontWeight: FontWeight.w600, fontSize: 15)),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      visualDensity: VisualDensity.compact,
    );
  }
}
