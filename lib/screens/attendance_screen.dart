import 'package:flutter/material.dart';
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
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
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
        setState(() {
          _records = res['records'] ?? [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = res['error']?.toString() ?? 'Failed to load attendance history.';
          _records = [];
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'An error occurred while loading attendance records.';
        _records = [];
        _isLoading = false;
      });
    }
  }

  String _capitalize(String text) {
    if (text.isEmpty) return '';
    return text[0].toUpperCase() + text.substring(1).toLowerCase();
  }

  IconData _getEventIcon(String eventType) {
    switch (eventType.toLowerCase()) {
      case 'pickup':
        return Icons.check_circle;
      case 'dropoff':
        return Icons.arrow_downward;
      case 'absent':
        return Icons.close;
      default:
        return Icons.event_available;
    }
  }

  Color _getEventColor(String eventType) {
    switch (eventType.toLowerCase()) {
      case 'pickup':
        return Colors.green;
      case 'dropoff':
        return Colors.blueAccent;
      case 'absent':
        return Colors.red;
      default:
        return Colors.blueGrey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text(
          'Attendance History',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.blueAccent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
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
                _buildStudentSelector(),
                Expanded(
                  child: RefreshIndicator(
                    color: Colors.blueAccent,
                    onRefresh: _fetchAttendance,
                    child: _buildAttendanceContent(),
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
      padding: const EdgeInsets.symmetric(vertical: 10),
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
                backgroundColor: isSelected ? Colors.white.withOpacity(0.2) : Colors.grey.shade300,
                child: Icon(
                  Icons.person,
                  size: 16,
                  color: isSelected ? Colors.white : Colors.grey.shade700,
                ),
              ),
              selected: isSelected,
              selectedColor: Colors.blueAccent,
              backgroundColor: Colors.grey.shade100,
              side: BorderSide(
                color: isSelected ? Colors.blueAccent : Colors.grey.shade300,
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

  Widget _buildAttendanceContent() {
    if (_isLoading) {
      return const CustomLoading(message: 'Fetching attendance history...');
    }

    if (_errorMessage != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 52, color: Colors.red[300]),
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: Colors.grey[800]),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _fetchAttendance,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Try Again'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
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

    if (_records.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_busy, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                const Text(
                  'No attendance records found.',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Attendance activities will appear here once logged.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      itemCount: _records.length,
      itemBuilder: (context, index) {
        final record = _records[index];
        final isLast = index == _records.length - 1;
        return _buildTimelineItem(record, isLast);
      },
    );
  }

  Widget _buildTimelineItem(dynamic record, bool isLast) {
    final eventType = record['event_type']?.toString() ?? 'unknown';
    final createdAt = record['created_at']?.toString() ?? 'N/A';
    final lat = record['lat'];
    final lng = record['lng'];
    final hasCoords = lat != null && lng != null && (lat != 0 || lng != 0);

    final eventColor = _getEventColor(eventType);
    final eventIcon = _getEventIcon(eventType);
    final capitalizedType = _capitalize(eventType);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline Node and Connecting Line
          SizedBox(
            width: 44,
            child: Column(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: eventColor.withOpacity(0.12),
                    shape: BoxShape.circle,
                    border: Border.all(color: eventColor, width: 2),
                  ),
                  child: Icon(eventIcon, color: eventColor, size: 20),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: Colors.grey[300],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Record Card Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Card(
                elevation: 1.5,
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            capitalizedType,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: eventColor,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: eventColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              capitalizedType.toUpperCase(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: eventColor,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.access_time, size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              createdAt,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[700],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (hasCoords) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.location_on_outlined, size: 14, color: Colors.grey[600]),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Lat: $lat, Lng: $lng',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
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
            ),
          ),
        ],
      ),
    );
  }
}
