import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import 'login_screen.dart';
import 'terms_screen.dart';
import '../widgets/custom_loading.dart';

class MonitorDashboard extends StatefulWidget {
  const MonitorDashboard({Key? key}) : super(key: key);

  @override
  _MonitorDashboardState createState() => _MonitorDashboardState();
}

class FamilyGroup {
  final dynamic parentId;
  final String parentName;
  final String phone;
  final String address;
  final dynamic stopLat;
  final dynamic stopLng;
  final List<dynamic> students;

  FamilyGroup({
    required this.parentId,
    required this.parentName,
    required this.phone,
    required this.address,
    this.stopLat,
    this.stopLng,
    required this.students,
  });
}

class _MonitorDashboardState extends State<MonitorDashboard> {
  List<dynamic> _students = [];
  bool _isLoading = true;
  String _staffName = 'Staff Member';
  String _staffRole = 'Bus Monitor';
  String _busName = 'Unassigned';
  String _driverName = 'Not Assigned';
  String _driverPhone = '';
  String _filter = 'all'; // all, pending, pickup, dropoff, absent, leave
  String _activeShift = 'morning'; // 'morning' or 'afternoon'
  Map<String, dynamic>? _shiftTimings;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadRoster();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _staffName = prefs.getString('user_name') ?? 'Staff Member';
    });
  }

  Future<void> _loadRoster() async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiService.getRoster();
      // Guard once, here, rather than before each setState and each ScaffoldMessenger below: this
      // is the only await, so after it either the screen is still alive for all of them or none.
      if (!mounted) return;
      if (response['success'] == true) {
        setState(() {
          _students = response['data'] ?? [];
          if (_shiftTimings == null && response['timings'] != null) {
            _activeShift = response['timings']['current_shift'] ?? 'morning';
          }
          _shiftTimings = response['timings'];
          if (response['staff'] != null) {
            _staffName = response['staff']['name'] ?? _staffName;
            _staffRole = response['staff']['role'] ?? _staffRole;
            _busName = response['staff']['bus_name'] ?? _busName;
            _driverName = response['staff']['driver_name'] ?? _driverName;
            _driverPhone = response['staff']['driver_phone'] ?? _driverPhone;
          }
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
        final err = response['error'] ?? 'Failed to load student list';
        if (err.toString().contains('Unauthorized') || err.toString().contains('token')) {
          _logout();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(err),
            backgroundColor: Colors.redAccent,
          ));
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Network error: $e'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  Future<void> _confirmAndMarkAttendance(int studentId, String studentName, String type) async {
    String actionLabel = '';
    Color actionColor = Colors.blue;
    String actionDesc = '';

    if (type == 'pickup') {
      actionLabel = 'PICK UP';
      actionColor = const Color(0xFF1565C0);
      actionDesc = _activeShift == 'morning'
          ? 'Mark child as picked up from Home and boarded the bus.'
          : 'Mark child as boarded the bus at School.';
    } else if (type == 'dropoff') {
      actionLabel = 'DROP OFF';
      actionColor = const Color(0xFF2E7D32);
      actionDesc = _activeShift == 'morning'
          ? 'Mark child as safely dropped off at School.'
          : 'Mark child as safely dropped off at Home.';
    } else if (type == 'absent') {
      actionLabel = 'ABSENT';
      actionColor = Colors.redAccent;
      actionDesc = 'Mark child as absent today.';
    } else if (type == 'leave') {
      actionLabel = 'ON LEAVE';
      actionColor = Colors.orange;
      actionDesc = 'Mark child as on approved leave today.';
    } else if (type == 'by_parent') {
      actionLabel = 'BY PARENTS (BP)';
      actionColor = const Color(0xFF7C3AED);
      actionDesc = _activeShift == 'morning'
          ? 'Child is being taken to School by their own parent this morning. Counts as PRESENT - not an absence.'
          : 'Child is being collected from School by their own parent this evening. Counts as PRESENT - not an absence.';
    }

    final shiftLabel = '$_shiftName shift';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(_getStatusIcon(type), color: actionColor),
            const SizedBox(width: 8),
            Text('Confirm $actionLabel', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Student: $studentName', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 4),
            Text('Shift: $shiftLabel', style: TextStyle(color: Colors.grey[700], fontSize: 13)),
            const SizedBox(height: 10),
            Text(actionDesc, style: const TextStyle(fontSize: 13.5)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: actionColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _executeMarkAttendance(studentId, type);
    }
  }

  /// Where the monitor is standing when they mark a child.
  ///
  /// Returns null rather than a placeholder if the fix cannot be obtained. The previous code passed
  /// a hardcoded 0.0, 0.0 on every single call, so every attendance row was stamped with the middle
  /// of the Atlantic and the portal - correctly - reported "No GPS Stamp" for all of them.
  ///
  /// Never blocks the marking itself: a monitor with no signal must still be able to record that a
  /// child boarded. The stamp is evidence, not a precondition.
  Future<Position?> _currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;

      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('Attendance GPS stamp unavailable: $e');
      return null;   // mark attendance anyway
    }
  }

  Future<void> _executeMarkAttendance(int studentId, String type) async {
    final pos = await _currentPosition();
    if (!mounted) return;

    final response = await ApiService.markAttendance(
      studentId, type, pos?.latitude, pos?.longitude, shift: _activeShift);
    if (!mounted) return;

    if (response['success'] == true) {
      final shiftLabel = _shiftName;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(pos == null
            ? 'Attendance recorded for $shiftLabel shift (no GPS stamp — location unavailable)'
            : 'Attendance recorded for $shiftLabel shift!'),
        backgroundColor: pos == null
            ? Colors.orange.shade800
            : (type == 'dropoff' ? Colors.green : (type == 'pickup' ? Colors.blue : Colors.orange)),
        duration: Duration(seconds: pos == null ? 3 : 1),
      ));
      _loadRoster();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(response['error'] ?? 'Action failed'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  /// Raises a real deletion request. This previously showed a green "request submitted" message
  /// without calling anything, so no request ever reached the school.
  Future<void> _requestAccountDeletion() async {
    final reasonCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account', style: TextStyle(color: Colors.red)),
        content: Column(
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
    Navigator.of(context).pop(); // dismiss the spinner

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

  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await ApiService.clearToken();
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  void _callPhone(String phone) async {
    if (phone.isEmpty) return;
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri.parse('tel:$cleanPhone');
    if (!await launchUrl(uri)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open phone dialer')));
    }
  }

  void _openWhatsApp(String phone, List<String> studentNames) async {
    if (phone.isEmpty) return;
    String cleanPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    final namesStr = studentNames.join(', ');
    final msg = Uri.encodeComponent('Hello, regarding student(s) $namesStr for Smart Step School Bus: ');
    final uri = Uri.parse('https://wa.me/$cleanPhone?text=$msg');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open WhatsApp')));
    }
  }

  void _openLocationOnMap(dynamic lat, dynamic lng, String address) async {
    if (lat == null || lng == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No coordinates saved for this address.')));
      return;
    }
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open Maps')));
    }
  }

  // Groups all loaded students into Family/Sibling groups
  List<FamilyGroup> get _familyGroups {
    final Map<String, List<dynamic>> grouped = {};
    final Map<String, dynamic> metadata = {};

    for (var s in _students) {
      String key;
      if (s['parent_id'] != null && s['parent_id'] != 0) {
        key = 'pid_${s['parent_id']}';
      } else if (s['phone'] != null && s['phone'].toString().trim().isNotEmpty) {
        key = 'phone_${s['phone'].toString().trim()}';
      } else {
        key = 'sid_${s['id']}';
      }

      if (!grouped.containsKey(key)) {
        grouped[key] = [];
        metadata[key] = s;
      }
      grouped[key]!.add(s);
    }

    return grouped.entries.map((entry) {
      final sample = metadata[entry.key]!;
      return FamilyGroup(
        parentId: sample['parent_id'],
        parentName: sample['parent_name'] ?? 'Family',
        phone: sample['phone']?.toString() ?? '',
        address: sample['address'] ?? 'School Bus Stop',
        stopLat: sample['stop_lat'],
        stopLng: sample['stop_lng'],
        students: entry.value,
      );
    }).toList();
  }

  dynamic _getStudentStatus(dynamic student) {
    if (_activeShift == 'morning') {
      return student['morning_status'];
    } else {
      return student['afternoon_status'];
    }
  }

  String _formatTimeStr(String? timeStr) {
    if (timeStr == null || timeStr.isEmpty) return '';
    try {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        int hour = int.parse(parts[0]);
        int minute = int.parse(parts[1]);
        String ampm = hour >= 12 ? 'PM' : 'AM';
        int displayHour = hour % 12;
        if (displayHour == 0) displayHour = 12;
        String minuteStr = minute.toString().padLeft(2, '0');
        return '$displayHour:$minuteStr $ampm';
      }
    } catch (_) { /* unparseable time string - fall through and return it verbatim below */ }
    return timeStr;
  }

  /// "Evening" to the people using the app; the API and the database keep calling it 'afternoon'.
  String get _shiftName => _activeShift == 'morning' ? 'Morning' : 'Evening';
  Color get _shiftColor => _activeShift == 'morning' ? const Color(0xFF1565C0) : const Color(0xFF4338CA);

  /// Absent / leave / parent are the exceptions, so they live behind one button instead of three.
  void _showNotTravellingSheet(int studentId, String studentName) {
    final isMorning = _activeShift == 'morning';
    final options = [
      ['absent', Icons.cancel_rounded, Colors.redAccent, 'Absent', 'Not at the stop, not coming today'],
      ['leave', Icons.event_busy_rounded, Colors.orange[800]!, 'On leave', 'Approved leave for today'],
      ['by_parent', Icons.family_restroom_rounded, _byParentColor,
        isMorning ? 'Parent taking to school' : 'Parent collecting from school',
        'Counts as present, just not on the bus'],
    ];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(studentName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('$_shiftName shift · why is this child not on the bus?',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600])),
              const SizedBox(height: 10),
              ...options.map((o) => ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: CircleAvatar(
                      backgroundColor: (o[2] as Color).withOpacity(0.12),
                      child: Icon(o[1] as IconData, color: o[2] as Color),
                    ),
                    title: Text(o[3] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(o[4] as String, style: const TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _confirmAndMarkAttendance(studentId, studentName, o[0] as String);
                    },
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shiftOption({
    required String key,
    required String title,
    required String route,
    required String time,
    required IconData icon,
    required Color color,
  }) {
    final selected = _activeShift == key;
    return Expanded(
      child: InkWell(
        onTap: () {
          if (!selected) setState(() => _activeShift = key);
        },
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                  color: selected ? Colors.white.withOpacity(0.18) : color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 19, color: selected ? Colors.amberAccent : color),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                          color: selected ? Colors.white : const Color(0xFF1E293B),
                          fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(route,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? Colors.white.withOpacity(0.85) : Colors.grey[700],
                          fontSize: 11, fontWeight: FontWeight.w600)),
                    Text(time,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: selected ? Colors.white70 : Colors.grey[500], fontSize: 10)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShiftSelector() {
    final mStart = _formatTimeStr(_shiftTimings?['morning_start'] ?? '05:30:00');
    final mEnd = _formatTimeStr(_shiftTimings?['morning_end'] ?? '07:30:00');
    final aStart = _formatTimeStr(_shiftTimings?['afternoon_start'] ?? '13:00:00');
    final aEnd = _formatTimeStr(_shiftTimings?['afternoon_end'] ?? '16:00:00');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      padding: const EdgeInsets.all(5),
      child: Row(
        children: [
          _shiftOption(
            key: 'morning', title: 'Morning', route: 'Home → School',
            time: '$mStart - $mEnd', icon: Icons.wb_sunny_rounded, color: const Color(0xFF1565C0),
          ),
          const SizedBox(width: 5),
          _shiftOption(
            key: 'afternoon', title: 'Evening', route: 'School → Home',
            time: '$aStart - $aEnd', icon: Icons.nights_stay_rounded, color: const Color(0xFF4338CA),
          ),
        ],
      ),
    );
  }

  // Filtered families based on selected filter
  List<FamilyGroup> get _filteredFamilyGroups {
    final families = _familyGroups;
    if (_filter == 'all') return families;

    List<FamilyGroup> result = [];
    for (var f in families) {
      List<dynamic> matchingStudents = [];
      for (var s in f.students) {
        final st = _getStudentStatus(s);
        if (_filter == 'pending' && st == null) {
          matchingStudents.add(s);
        } else if (st != null && st['event_type'] == _filter) {
          matchingStudents.add(s);
        }
      }
      if (matchingStudents.isNotEmpty) {
        result.add(FamilyGroup(
          parentId: f.parentId,
          parentName: f.parentName,
          phone: f.phone,
          address: f.address,
          stopLat: f.stopLat,
          stopLng: f.stopLng,
          students: matchingStudents,
        ));
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    int totalCount = _students.length;
    int pickedCount = _students.where((s) => _getStudentStatus(s) != null && _getStudentStatus(s)['event_type'] == 'pickup').length;
    int droppedCount = _students.where((s) => _getStudentStatus(s) != null && _getStudentStatus(s)['event_type'] == 'dropoff').length;
    int absentCount = _students.where((s) => _getStudentStatus(s) != null && _getStudentStatus(s)['event_type'] == 'absent').length;
    int leaveCount = _students.where((s) => _getStudentStatus(s) != null && _getStudentStatus(s)['event_type'] == 'leave').length;
    int byParentCount = _students.where((s) => _getStudentStatus(s) != null && _getStudentStatus(s)['event_type'] == 'by_parent').length;
    int pendingCount = _students.where((s) => _getStudentStatus(s) == null).length;

    final filteredFamilies = _filteredFamilyGroups;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        title: const Text('Student List & Attendance', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh, color: Colors.white), onPressed: _loadRoster),
        ],
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      drawer: Drawer(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1565C0), Color(0xFF1A237E)],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(radius: 28, backgroundColor: Colors.white24, child: Icon(Icons.directions_bus, size: 32, color: Colors.white)),
                      const Spacer(),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        padding: const EdgeInsets.all(4),
                        child: ClipOval(
                          child: Image.asset(
                            'assets/images/logo.png',
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(Icons.directions_bus, color: Color(0xFF1565C0)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(_staffName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text('$_staffRole  •  Bus: $_busName', style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12)),
                  if (_driverName != 'Not Assigned') ...[
                    const SizedBox(height: 6),
                    Text('Driver: $_driverName ($_driverPhone)', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 11)),
                  ]
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.refresh, color: Colors.blueGrey),
              title: const Text('Refresh Student List'),
              onTap: () {
                Navigator.pop(context);
                _loadRoster();
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_rounded, color: Colors.blueGrey),
              title: const Text('Terms & Conditions'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsScreen()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_rounded, color: Colors.blueGrey),
              title: const Text('Privacy Policy'),
              onTap: () {
                Navigator.pop(context);
                launchUrl(Uri.parse('https://smartstepgps.cloud/privacy.html'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_rounded, color: Colors.blueGrey),
              title: const Text('About Us'),
              onTap: () {
                Navigator.pop(context);
                launchUrl(Uri.parse('https://smartstepgps.cloud/about.html'));
              },
            ),
            const Spacer(),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.orange),
              title: const Text('Delete Account', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context);
                _requestAccountDeletion();
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.redAccent),
              title: const Text('Sign Out', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
              onTap: _logout,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
      body: _isLoading
          ? const CustomLoading(message: 'Loading student list...')
          : RefreshIndicator(
              onRefresh: _loadRoster,
              child: CustomScrollView(
                slivers: [
                  // Top Shift Selector, Summary & Driver Card
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _buildShiftSelector(),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [BoxShadow(color: const Color(0xFF1565C0).withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))],
                            ),
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('$_staffRole: $_staffName', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                                        const SizedBox(height: 2),
                                        Text('Bus: $_busName', style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13, fontWeight: FontWeight.w500)),
                                      ],
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(20)),
                                      child: Text('$totalCount Students', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                                    ),
                                  ],
                                ),
                                if (_driverName != 'Not Assigned') ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.18), borderRadius: BorderRadius.circular(10)),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.person_pin, size: 18, color: Colors.white70),
                                            const SizedBox(width: 8),
                                            Text('Driver: $_driverName', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                          ],
                                        ),
                                        if (_driverPhone.isNotEmpty)
                                          GestureDetector(
                                            onTap: () => _callPhone(_driverPhone),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(14)),
                                              child: Row(
                                                children: [
                                                  const Icon(Icons.call, size: 12, color: Colors.white),
                                                  const SizedBox(width: 4),
                                                  Text(_driverPhone, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                                ],
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 14),

                                // Stat pills: Pending, Picked Up, Dropped Off, Absent, On Leave, BP
                                Row(
                                  children: [
                                    _buildStatPill('Pending', pendingCount, Colors.white70),
                                    const SizedBox(width: 4),
                                    _buildStatPill('Picked Up', pickedCount, Colors.lightBlueAccent),
                                    const SizedBox(width: 4),
                                    _buildStatPill('Dropped', droppedCount, Colors.lightGreenAccent),
                                    const SizedBox(width: 4),
                                    _buildStatPill('Absent', absentCount, const Color(0xFFFF8A80)),
                                    const SizedBox(width: 4),
                                    _buildStatPill('Leave', leaveCount, const Color(0xFFFFD180)),
                                    const SizedBox(width: 4),
                                    // Abbreviated to "BP" here only because six pills share one row;
                                    // every other surface spells out "By Parents (BP)".
                                    _buildStatPill('BP', byParentCount, const Color(0xFFD0BCFF)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),

                          // Filter Buttons (Separate Absent and On Leave)
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _buildFilterChip('all', 'All ($totalCount)'),
                                const SizedBox(width: 6),
                                _buildFilterChip('pending', 'Pending ($pendingCount)'),
                                const SizedBox(width: 6),
                                _buildFilterChip('pickup', 'Picked Up ($pickedCount)'),
                                const SizedBox(width: 6),
                                _buildFilterChip('dropoff', 'Dropped Off ($droppedCount)'),
                                const SizedBox(width: 6),
                                _buildFilterChip('absent', 'Absent ($absentCount)'),
                                const SizedBox(width: 6),
                                _buildFilterChip('leave', 'On Leave ($leaveCount)'),
                                const SizedBox(width: 6),
                                _buildFilterChip('by_parent', 'By Parents ($byParentCount)'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Family / Siblings Roster List
                  if (filteredFamilies.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_outline, size: 50, color: Colors.grey[400]),
                            const SizedBox(height: 10),
                            Text('No students match this filter', style: TextStyle(color: Colors.grey[600], fontSize: 15)),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final family = filteredFamilies[index];
                            return _buildFamilyCard(family);
                          },
                          childCount: filteredFamilies.length,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildFamilyCard(FamilyGroup family) {
    final hasCoords = family.stopLat != null && family.stopLng != null;
    final studentNames = family.students.map((s) => s['name']?.toString() ?? 'Student').toList();
    final isMultipleSiblings = family.students.length > 1;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Family Header Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isMultipleSiblings ? const Color(0xFFF3E5F5) : const Color(0xFFF5F7FB),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.15))),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  isMultipleSiblings ? Icons.family_restroom : Icons.person_pin_circle_outlined,
                  color: isMultipleSiblings ? const Color(0xFF7B1FA2) : const Color(0xFF1565C0),
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              family.parentName,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14.5,
                                color: isMultipleSiblings ? const Color(0xFF4A148C) : const Color(0xFF1A237E),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isMultipleSiblings) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF7B1FA2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${family.students.length} Siblings',
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ]
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        family.address,
                        style: TextStyle(color: Colors.grey[700], fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Quick Communication & Navigation Actions
                if (family.phone.isNotEmpty) ...[
                  IconButton(
                    icon: const Icon(Icons.phone, color: Color(0xFF1565C0), size: 20),
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    tooltip: 'Call Parent',
                    onPressed: () => _callPhone(family.phone),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.chat, color: Color(0xFF25D366), size: 20),
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    tooltip: 'WhatsApp Parent',
                    onPressed: () => _openWhatsApp(family.phone, studentNames),
                  ),
                  const SizedBox(width: 4),
                ],
                if (hasCoords)
                  IconButton(
                    icon: const Icon(Icons.navigation, color: Colors.purple, size: 20),
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    tooltip: 'Open in Google Maps',
                    onPressed: () => _openLocationOnMap(family.stopLat, family.stopLng, family.address),
                  ),
              ],
            ),
          ),

          // Sibling / Student Rows
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Column(
              children: family.students.asMap().entries.map((entry) {
                final idx = entry.key;
                final student = entry.value;
                final status = _getStudentStatus(student);
                final studentName = student['name'] ?? 'Unknown';

                return Column(
                  children: [
                    if (idx > 0) const Divider(height: 16, thickness: 0.8),
                    _buildStudentRow(student, status, studentName),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudentRow(dynamic student, dynamic status, String studentName) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: const Color(0xFF1565C0).withOpacity(0.1),
              child: Text(
                studentName.isNotEmpty ? studentName[0].toUpperCase() : '?',
                style: const TextStyle(color: Color(0xFF1565C0), fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    studentName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  Text(
                    'Grade: ${student['grade'] ?? 'N/A'}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 11.5),
                  ),
                ],
              ),
            ),

            // Current Status Badge
            if (status != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _getStatusBgColor(status['event_type']),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_getStatusIcon(status['event_type']), size: 12, color: _getStatusColor(status['event_type'])),
                    const SizedBox(width: 4),
                    Text(
                      _getStatusLabel(status['event_type']),
                      style: TextStyle(
                        color: _getStatusColor(status['event_type']),
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'PENDING',
                  style: TextStyle(color: Colors.grey[700], fontWeight: FontWeight.bold, fontSize: 10),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Attendance Action Buttons
        // 1. If completed (dropoff, absent, leave) -> Locked for staff
        if (status != null && status['event_type'] != 'pickup')
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.withOpacity(0.2)),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 14, color: Colors.grey[600]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$_shiftName done · ${_getStatusLabel(status['event_type'])}',
                    style: TextStyle(color: Colors.grey[700], fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  status['created_at'] != null ? status['created_at'].toString().split(' ').last : '',
                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                ),
              ],
            ),
          )
        // 2. If Picked Up -> Display DROP OFF button (Stage 2: Not Locked!)
        else if (status != null && status['event_type'] == 'pickup')
          Row(
            children: [
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 42,
                  child: ElevatedButton.icon(
                    onPressed: () => _confirmAndMarkAttendance(student['id'], studentName, 'dropoff'),
                    icon: Icon(_activeShift == 'morning' ? Icons.school : Icons.home, size: 15),
                    label: Text(
                      _activeShift == 'morning' ? 'Dropped at school' : 'Dropped at home',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      foregroundColor: Colors.white,
                      elevation: 1,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.25)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.access_time, size: 13, color: Color(0xFF1565C0)),
                    const SizedBox(width: 4),
                    Text(
                      status['created_at'] != null ? status['created_at'].toString().split(' ').last : '',
                      style: const TextStyle(color: Color(0xFF1565C0), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          )
        // 3. Pending -> ONE clear next step for this shift, plus a single "Not travelling" button
        //    that holds the less common outcomes (absent / leave / parent). Four buttons side by
        //    side was hard to hit on a moving bus and made every child's card look the same.
        else
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: ElevatedButton.icon(
                    onPressed: () => _confirmAndMarkAttendance(student['id'], studentName, 'pickup'),
                    icon: Icon(_activeShift == 'morning' ? Icons.home_rounded : Icons.school_rounded, size: 17),
                    label: Text(
                      _activeShift == 'morning' ? 'Picked up from home' : 'Boarded at school',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _shiftColor,
                      foregroundColor: Colors.white,
                      elevation: 1,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 42,
                child: OutlinedButton(
                  onPressed: () => _showNotTravellingSheet(student['id'], studentName),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.grey.withOpacity(0.45)),
                    foregroundColor: const Color(0xFF475569),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Not travelling', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      SizedBox(width: 2),
                      Icon(Icons.expand_more_rounded, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  // By Parents keeps its own colour throughout - purple. It must not look like an absence (red) and
  // must not look like a bus event (blue/green), because it is neither: the child is present, they
  // just are not travelling on the bus for this shift.
  static const Color _byParentColor = Color(0xFF7C3AED);

  Color _getStatusBgColor(String? type) {
    if (type == 'dropoff') return Colors.green.withOpacity(0.12);
    if (type == 'pickup') return Colors.blue.withOpacity(0.12);
    if (type == 'leave') return Colors.orange.withOpacity(0.12);
    if (type == 'by_parent') return _byParentColor.withOpacity(0.12);
    return Colors.red.withOpacity(0.12);
  }

  Color _getStatusColor(String? type) {
    if (type == 'dropoff') return Colors.green[800]!;
    if (type == 'pickup') return const Color(0xFF1565C0);
    if (type == 'leave') return Colors.orange[800]!;
    if (type == 'by_parent') return _byParentColor;
    return Colors.redAccent;
  }

  IconData _getStatusIcon(String? type) {
    if (type == 'dropoff') return Icons.check_circle;
    if (type == 'pickup') return Icons.directions_bus;
    if (type == 'leave') return Icons.event_busy;
    if (type == 'by_parent') return Icons.family_restroom;
    return Icons.cancel;
  }

  String _getStatusLabel(String? type) {
    if (type == 'dropoff') {
      return _activeShift == 'morning' ? 'DROPPED AT SCHOOL' : 'DROPPED AT HOME';
    }
    if (type == 'pickup') {
      return _activeShift == 'morning' ? 'ON BUS (TO SCHOOL)' : 'BOARDED AT SCHOOL';
    }
    if (type == 'leave') return 'ON LEAVE';
    if (type == 'by_parent') return 'BY PARENTS (BP)';
    return 'ABSENT';
  }

  Widget _buildStatPill(String title, int count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.18),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text('$count', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 9.5),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String key, String label) {
    final isSelected = _filter == key;
    return GestureDetector(
      onTap: () => setState(() => _filter = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1565C0) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? const Color(0xFF1565C0) : Colors.grey[300]!),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey[800],
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
