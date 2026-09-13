import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import 'login_screen.dart';

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
        final err = response['error'] ?? 'Failed to load roster';
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
    }

    final shiftLabel = _activeShift == 'morning' ? 'Morning Shift' : 'Afternoon Shift';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              type == 'dropoff' ? Icons.check_circle : (type == 'pickup' ? Icons.directions_bus : Icons.warning_amber),
              color: actionColor,
            ),
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

  Future<void> _executeMarkAttendance(int studentId, String type) async {
    final response = await ApiService.markAttendance(studentId, type, 0.0, 0.0, shift: _activeShift);
    if (response['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Attendance recorded for ${_activeShift == 'morning' ? 'Morning' : 'Afternoon'} shift!'),
        backgroundColor: type == 'dropoff' ? Colors.green : (type == 'pickup' ? Colors.blue : Colors.orange),
        duration: const Duration(seconds: 1),
      ));
      _loadRoster();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(response['error'] ?? 'Action failed'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  void _showAbsentOrLeavePicker(int studentId, String studentName) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mark Attendance for $studentName', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('Select the status reason for today:', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 18),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), shape: BoxShape.circle),
                child: const Icon(Icons.close, color: Colors.redAccent),
              ),
              title: const Text('Mark Absent', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Student did not arrive at the pickup stop'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmAndMarkAttendance(studentId, studentName, 'absent');
              },
            ),
            const Divider(),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), shape: BoxShape.circle),
                child: const Icon(Icons.event_busy, color: Colors.orange),
              ),
              title: const Text('On Leave', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Parent notified / officially on approved leave'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmAndMarkAttendance(studentId, studentName, 'leave');
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
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
    } catch (_) {}
    return timeStr;
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
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          // Morning Tab
          Expanded(
            child: InkWell(
              onTap: () {
                if (_activeShift != 'morning') {
                  setState(() => _activeShift = 'morning');
                }
              },
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                decoration: BoxDecoration(
                  color: _activeShift == 'morning' ? const Color(0xFF1565C0) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.wb_sunny_rounded,
                          size: 15,
                          color: _activeShift == 'morning' ? Colors.amberAccent : Colors.orange,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Morning (PickUp)',
                          style: TextStyle(
                            color: _activeShift == 'morning' ? Colors.white : const Color(0xFF1E293B),
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$mStart - $mEnd',
                      style: TextStyle(
                        color: _activeShift == 'morning' ? Colors.white70 : Colors.grey[600],
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Afternoon Tab
          Expanded(
            child: InkWell(
              onTap: () {
                if (_activeShift != 'afternoon') {
                  setState(() => _activeShift = 'afternoon');
                }
              },
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                decoration: BoxDecoration(
                  color: _activeShift == 'afternoon' ? const Color(0xFF4338CA) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.nights_stay_rounded,
                          size: 15,
                          color: _activeShift == 'afternoon' ? Colors.amberAccent : const Color(0xFF6366F1),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Afternoon (DropOff)',
                          style: TextStyle(
                            color: _activeShift == 'afternoon' ? Colors.white : const Color(0xFF1E293B),
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$aStart - $aEnd',
                      style: TextStyle(
                        color: _activeShift == 'afternoon' ? Colors.white70 : Colors.grey[600],
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
    int pendingCount = _students.where((s) => _getStudentStatus(s) == null).length;

    final filteredFamilies = _filteredFamilyGroups;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        title: const Text('Route Roster & Attendance', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
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
                  const CircleAvatar(radius: 28, backgroundColor: Colors.white24, child: Icon(Icons.directions_bus, size: 32, color: Colors.white)),
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
              title: const Text('Refresh Roster'),
              onTap: () {
                Navigator.pop(context);
                _loadRoster();
              },
            ),
            const Spacer(),
            const Divider(),
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
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF1565C0)))
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

                                // 5 Separate Stat Pills: Pending, Picked Up, Dropped Off, Absent, On Leave
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
                    '${_activeShift == 'morning' ? 'Morning' : 'Afternoon'} Completed (${_getStatusLabel(status['event_type'])}) • Locked',
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
                  height: 36,
                  child: ElevatedButton.icon(
                    onPressed: () => _confirmAndMarkAttendance(student['id'], studentName, 'dropoff'),
                    icon: Icon(_activeShift == 'morning' ? Icons.school : Icons.home, size: 15),
                    label: Text(
                      _activeShift == 'morning' ? 'Drop Off at School' : 'Drop Off at Home',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
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
        // 3. If Pending -> Display PICK UP, ABSENT, LEAVE (Stage 1)
        else
          Row(
            children: [
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 34,
                  child: ElevatedButton.icon(
                    onPressed: () => _confirmAndMarkAttendance(student['id'], studentName, 'pickup'),
                    icon: const Icon(Icons.directions_bus, size: 14),
                    label: Text(
                      _activeShift == 'morning' ? 'Pick Up (Home)' : 'Pick Up (School)',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      elevation: 1,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Absent Button
              SizedBox(
                height: 34,
                child: OutlinedButton(
                  onPressed: () => _confirmAndMarkAttendance(student['id'], studentName, 'absent'),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    foregroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Absent', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 6),

              // Leave Button
              SizedBox(
                height: 34,
                child: OutlinedButton(
                  onPressed: () => _confirmAndMarkAttendance(student['id'], studentName, 'leave'),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.orange),
                    foregroundColor: Colors.orange[800],
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Leave', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Color _getStatusBgColor(String? type) {
    if (type == 'dropoff') return Colors.green.withOpacity(0.12);
    if (type == 'pickup') return Colors.blue.withOpacity(0.12);
    if (type == 'leave') return Colors.orange.withOpacity(0.12);
    return Colors.red.withOpacity(0.12);
  }

  Color _getStatusColor(String? type) {
    if (type == 'dropoff') return Colors.green[800]!;
    if (type == 'pickup') return const Color(0xFF1565C0);
    if (type == 'leave') return Colors.orange[800]!;
    return Colors.redAccent;
  }

  IconData _getStatusIcon(String? type) {
    if (type == 'dropoff') return Icons.check_circle;
    if (type == 'pickup') return Icons.directions_bus;
    if (type == 'leave') return Icons.event_busy;
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
