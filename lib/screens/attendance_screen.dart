import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../widgets/custom_loading.dart';

class AttendanceScreen extends StatefulWidget {
  final List<dynamic> students;

  const AttendanceScreen({Key? key, required this.students}) : super(key: key);

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  int _selectedStudentIndex = 0;
  List<dynamic> _records = [];
  final Map<String, List<dynamic>> _recordsByDate = {};
  bool _isLoading = false;
  String? _errorMessage;

  late DateTime _focusedMonth;
  late DateTime _selectedDate;

  static const List<String> _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];

  static const List<String> _weekdayShortNames = [
    'SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'
  ];

  static const List<String> _weekdayFullNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
  ];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focusedMonth = DateTime(now.year, now.month, 1);
    _selectedDate = DateTime(now.year, now.month, now.day);

    if (widget.students.isNotEmpty) {
      _fetchAttendance();
    }
  }

  int _getStudentId(dynamic student) {
    if (student is Map) {
      final id = student['id'] ?? student['student_id'];
      if (id is int) return id;
      if (id != null) return int.tryParse(id.toString()) ?? 0;
    }
    return 0;
  }

  String _getStudentName(dynamic student) {
    if (student is Map) {
      return student['name']?.toString() ?? 'Student';
    }
    return 'Student';
  }

  String _toDateKey(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<void> _fetchAttendance() async {
    if (widget.students.isEmpty) return;

    final student = widget.students[_selectedStudentIndex];
    final studentId = _getStudentId(student);

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await ApiService.getAttendanceHistory(studentId);
      if (res['success'] == true) {
        final List<dynamic> rawRecords = res['records'] ?? [];
        final Map<String, List<dynamic>> grouped = {};

        for (final r in rawRecords) {
          final createdAt = r['created_at']?.toString() ?? '';
          final parsed = DateTime.tryParse(createdAt);
          if (parsed != null) {
            final key = _toDateKey(parsed);
            grouped.putIfAbsent(key, () => []).add(r);
          }
        }

        setState(() {
          _records = rawRecords;
          _recordsByDate.clear();
          _recordsByDate.addAll(grouped);
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = res['error']?.toString() ?? 'Failed to load attendance history.';
          _records = [];
          _recordsByDate.clear();
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'An error occurred while loading attendance records.';
        _records = [];
        _recordsByDate.clear();
        _isLoading = false;
      });
    }
  }

  void _previousMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);
    });
  }

  void _goToToday() {
    final now = DateTime.now();
    setState(() {
      _focusedMonth = DateTime(now.year, now.month, 1);
      _selectedDate = DateTime(now.year, now.month, now.day);
    });
  }

  String _formatDisplayDate(DateTime dt) {
    final weekday = _weekdayFullNames[dt.weekday - 1];
    final month = _monthNames[dt.month - 1];
    return '$weekday, $month ${dt.day}, ${dt.year}';
  }

  String _formatTime(String rawTime) {
    final parsed = DateTime.tryParse(rawTime);
    if (parsed == null) return rawTime;
    final hour = parsed.hour;
    final minute = parsed.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour:$minute $period';
  }

  Color _getEventColor(String eventType) {
    switch (eventType.toLowerCase()) {
      case 'pickup':
        return const Color(0xFF2E7D32); // Green
      case 'dropoff':
        return const Color(0xFF1565C0); // Blue
      case 'absent':
        return const Color(0xFFC62828); // Red
      case 'leave':
        return const Color(0xFFEF6C00); // Orange
      default:
        return const Color(0xFF546E7A);
    }
  }

  IconData _getEventIcon(String eventType) {
    switch (eventType.toLowerCase()) {
      case 'pickup':
        return Icons.login_rounded;
      case 'dropoff':
        return Icons.logout_rounded;
      case 'absent':
        return Icons.cancel_outlined;
      case 'leave':
        return Icons.event_busy_rounded;
      default:
        return Icons.check_circle_outline_rounded;
    }
  }

  /// Opens the attendance location in the device's map app.
  ///
  /// Every failure here used to be swallowed, so tapping the location simply did nothing and the
  /// parent had no idea whether the tap registered, the coordinates were missing, or no map app was
  /// installed. Each of those now says so.
  Future<void> _openInMap(dynamic lat, dynamic lng) async {
    // 0,0 is a real coordinate in the Atlantic. Older app builds stamped every attendance event
    // with it, so treat it as "no location" rather than sending the parent to the ocean.
    final dLat = double.tryParse('$lat');
    final dLng = double.tryParse('$lng');
    final hasFix = dLat != null && dLng != null &&
        !(dLat.abs() < 0.0001 && dLng.abs() < 0.0001) &&
        dLat.abs() <= 90 && dLng.abs() <= 180;

    if (!hasFix) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No location was recorded for this attendance event.'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    final url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$dLat,$dLng');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No map application is available on this device.'),
          backgroundColor: Colors.orange,
        ));
      }
    } catch (e) {
      debugPrint('Attendance: could not open map: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not open the map. Please try again.'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      appBar: AppBar(
        title: const Text(
          'Attendance Calendar',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
        ),
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            tooltip: 'Refresh',
            onPressed: widget.students.isNotEmpty ? _fetchAttendance : null,
          ),
        ],
      ),
      body: widget.students.isEmpty
          ? const Center(
              child: Text(
                'No students assigned to your account.',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            )
          : Column(
              children: [
                if (widget.students.length > 1) _buildStudentSelector(),
                Expanded(
                  child: RefreshIndicator(
                    color: const Color(0xFF1565C0),
                    onRefresh: _fetchAttendance,
                    child: _buildMainContent(),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildStudentSelector() {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: 42,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: widget.students.length,
          separatorBuilder: (context, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final student = widget.students[index];
            final name = _getStudentName(student);
            final isSelected = index == _selectedStudentIndex;

            return ChoiceChip(
              label: Text(
                name,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.black87,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
              avatar: CircleAvatar(
                backgroundColor: isSelected ? Colors.white.withOpacity(0.25) : Colors.grey.shade300,
                child: Icon(
                  Icons.person_rounded,
                  size: 15,
                  color: isSelected ? Colors.white : Colors.grey.shade700,
                ),
              ),
              selected: isSelected,
              selectedColor: const Color(0xFF1565C0),
              backgroundColor: Colors.grey.shade100,
              side: BorderSide(
                color: isSelected ? const Color(0xFF1565C0) : Colors.grey.shade300,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              onSelected: (selected) {
                if (selected && index != _selectedStudentIndex) {
                  setState(() {
                    _selectedStudentIndex = index;
                  });
                  _fetchAttendance();
                }
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    if (_isLoading) {
      return const CustomLoading(message: 'Loading attendance calendar...');
    }

    if (_errorMessage != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.22),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, size: 52, color: Colors.red[300]),
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: Colors.grey[800]),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _fetchAttendance,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Try Again'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _buildCalendarCard(),
        const SizedBox(height: 16),
        _buildDateDetailsSection(),
      ],
    );
  }

  Widget _buildCalendarCard() {
    final year = _focusedMonth.year;
    final month = _focusedMonth.month;
    final daysInMonth = DateUtils.getDaysInMonth(year, month);
    // Sunday is column 0 (Dart weekday: Mon=1, ..., Sat=6, Sun=7 => Sun%7 = 0)
    final startOffset = DateTime(year, month, 1).weekday % 7;
    final totalCells = startOffset + daysInMonth;
    final rowCount = (totalCells / 7).ceil();

    final now = DateTime.now();
    final isCurrentMonth = _focusedMonth.year == now.year && _focusedMonth.month == now.month;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          // Month Header & Navigation
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_monthNames[month - 1]} $year',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A237E),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Tap any date with dots for details',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isCurrentMonth)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    child: OutlinedButton(
                      onPressed: _goToToday,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: const BorderSide(color: Color(0xFF1565C0)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Today', style: TextStyle(fontSize: 11, color: Color(0xFF1565C0), fontWeight: FontWeight.bold)),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded, size: 28),
                  color: const Color(0xFF1565C0),
                  tooltip: 'Previous Month',
                  onPressed: _previousMonth,
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded, size: 28),
                  color: const Color(0xFF1565C0),
                  tooltip: 'Next Month',
                  onPressed: _nextMonth,
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 0.8),
          // Weekday Labels Row
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: _weekdayShortNames.map((day) {
                final isWeekend = day == 'FRI' || day == 'SAT' || day == 'SUN';
                return Expanded(
                  child: Center(
                    child: Text(
                      day,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isWeekend ? Colors.blueGrey[400] : Colors.blueGrey[700],
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // Calendar Grid
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Column(
              children: List.generate(rowCount, (rowIndex) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: List.generate(7, (colIndex) {
                      final cellIndex = rowIndex * 7 + colIndex;
                      if (cellIndex < startOffset || cellIndex >= totalCells) {
                        return const Expanded(child: SizedBox(height: 48));
                      }

                      final dayNum = cellIndex - startOffset + 1;
                      final date = DateTime(year, month, dayNum);
                      final dateKey = _toDateKey(date);
                      final dayRecords = _recordsByDate[dateKey] ?? [];

                      final isSelected = _isSameDay(date, _selectedDate);
                      final isToday = _isSameDay(date, DateTime.now());

                      return Expanded(
                        child: _buildDayCell(
                          date: date,
                          dayNum: dayNum,
                          records: dayRecords,
                          isSelected: isSelected,
                          isToday: isToday,
                        ),
                      );
                    }),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, thickness: 0.8),
          // Monthly Summary Stats
          _buildMonthSummaryStats(year, month),
        ],
      ),
    );
  }

  Widget _buildDayCell({
    required DateTime date,
    required int dayNum,
    required List<dynamic> records,
    required bool isSelected,
    required bool isToday,
  }) {
    final hasPickup = records.any((r) => r['event_type'] == 'pickup');
    final hasDropoff = records.any((r) => r['event_type'] == 'dropoff');
    final hasAbsent = records.any((r) => r['event_type'] == 'absent');
    final hasLeave = records.any((r) => r['event_type'] == 'leave');

    return InkWell(
      onTap: () {
        setState(() {
          _selectedDate = date;
        });
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 50,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF1565C0)
              : (isToday ? const Color(0xFFE3F2FD) : Colors.transparent),
          borderRadius: BorderRadius.circular(12),
          border: isToday && !isSelected
              ? Border.all(color: const Color(0xFF1565C0), width: 1.5)
              : null,
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF1565C0).withOpacity(0.35),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$dayNum',
              style: TextStyle(
                fontSize: 13,
                fontWeight: (isSelected || isToday) ? FontWeight.bold : FontWeight.w500,
                color: isSelected
                    ? Colors.white
                    : (isToday ? const Color(0xFF0D47A1) : Colors.black87),
              ),
            ),
            const SizedBox(height: 3),
            // Indicator dots
            SizedBox(
              height: 6,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (hasPickup)
                    _buildDot(const Color(0xFF4CAF50), isSelected),
                  if (hasDropoff)
                    _buildDot(const Color(0xFF29B6F6), isSelected),
                  if (hasAbsent)
                    _buildDot(const Color(0xFFE53935), isSelected),
                  if (hasLeave)
                    _buildDot(const Color(0xFFFFB300), isSelected),
                  if (records.isEmpty)
                    const SizedBox(width: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDot(Color color, bool isSelected) {
    return Container(
      width: 5,
      height: 5,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: isSelected ? Colors.white : color,
        shape: BoxShape.circle,
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 1,
                )
              ]
            : null,
      ),
    );
  }

  Widget _buildMonthSummaryStats(int year, int month) {
    int presentDays = 0;
    int absentDays = 0;
    int leaveDays = 0;

    final daysInMonth = DateUtils.getDaysInMonth(year, month);
    for (int d = 1; d <= daysInMonth; d++) {
      final key = '$year-${month.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
      final recs = _recordsByDate[key];
      if (recs != null && recs.isNotEmpty) {
        if (recs.any((r) => r['event_type'] == 'pickup' || r['event_type'] == 'dropoff')) {
          presentDays++;
        }
        if (recs.any((r) => r['event_type'] == 'absent')) {
          absentDays++;
        }
        if (recs.any((r) => r['event_type'] == 'leave')) {
          leaveDays++;
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatPill('Present', '$presentDays days', const Color(0xFF2E7D32), Icons.check_circle_rounded),
          _buildStatPill('Absent', '$absentDays days', const Color(0xFFC62828), Icons.cancel_rounded),
          _buildStatPill('Leave', '$leaveDays days', const Color(0xFFEF6C00), Icons.event_busy_rounded),
        ],
      ),
    );
  }

  Widget _buildStatPill(String label, String value, Color color, IconData icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600], fontWeight: FontWeight.w500)),
            Text(value, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }

  Widget _buildDateDetailsSection() {
    final dateKey = _toDateKey(_selectedDate);
    final dayRecords = _recordsByDate[dateKey] ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.event_note_rounded, size: 20, color: Color(0xFF1565C0)),
                const SizedBox(width: 8),
                Text(
                  _formatDisplayDate(_selectedDate),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF263238),
                  ),
                ),
              ],
            ),
            if (dayRecords.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${dayRecords.length} ${dayRecords.length == 1 ? 'event' : 'events'}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1565C0),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (dayRecords.isEmpty)
          _buildEmptyDayCard()
        else
          ...dayRecords.map((record) => _buildRecordCard(record)).toList(),
      ],
    );
  }

  Widget _buildEmptyDayCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(Icons.event_available_rounded, size: 42, color: Colors.grey[350]),
          const SizedBox(height: 10),
          const Text(
            'No attendance recorded on this date',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap another date with colored dots on the calendar.',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(dynamic record) {
    final eventType = record['event_type']?.toString().toLowerCase() ?? '';
    final createdAt = record['created_at']?.toString() ?? '';
    final shift = record['shift']?.toString().toLowerCase() ?? '';
    final staffName = record['staff_name']?.toString() ?? '';
    final staffRole = record['staff_role']?.toString() ?? '';
    final lat = record['lat'];
    final lng = record['lng'];
    final hasCoords = lat != null && lng != null && (lat != 0 || lng != 0);

    final eventColor = _getEventColor(eventType);
    final eventIcon = _getEventIcon(eventType);

    String eventTitle = 'Attendance Record';
    if (eventType == 'pickup') eventTitle = 'Morning Pick Up';
    if (eventType == 'dropoff') eventTitle = 'Afternoon Drop Off';
    if (eventType == 'absent') eventTitle = 'Marked Absent';
    if (eventType == 'leave') eventTitle = 'Approved Leave';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Colored vertical accent line
              Container(
                width: 6,
                color: eventColor,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: eventColor.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(eventIcon, color: eventColor, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  eventTitle,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: eventColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Icon(Icons.access_time_rounded, size: 13, color: Colors.grey[600]),
                                    const SizedBox(width: 4),
                                    Text(
                                      _formatTime(createdAt),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[700],
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (shift.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade100,
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: Colors.grey.shade300),
                                        ),
                                        child: Text(
                                          shift.toUpperCase(),
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.grey[700],
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (staffName.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Icon(Icons.badge_outlined, size: 14, color: Colors.grey[500]),
                            const SizedBox(width: 6),
                            Text(
                              'Staff: $staffName',
                              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                            ),
                            if (staffRole.isNotEmpty)
                              Text(
                                ' (${staffRole.toUpperCase()})',
                                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                              ),
                          ],
                        ),
                      ],
                      if (hasCoords) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.location_on_rounded, size: 14, color: Colors.red[400]),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '$lat, $lng',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                            ),
                            InkWell(
                              onTap: () => _openInMap(lat, lng),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1565C0).withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.map_rounded, size: 12, color: Color(0xFF1565C0)),
                                    SizedBox(width: 4),
                                    Text(
                                      'View on Map',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1565C0),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
