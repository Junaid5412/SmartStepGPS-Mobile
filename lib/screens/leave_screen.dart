import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/custom_loading.dart';

class LeaveScreen extends StatefulWidget {
  final List<dynamic> students;

  const LeaveScreen({Key? key, required this.students}) : super(key: key);

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  List<dynamic> _requests = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchLeaveRequests();
  }

  Future<void> _fetchLeaveRequests() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await ApiService.getLeaveRequests();
      if (res['success'] == true) {
        setState(() {
          _requests = res['requests'] ?? [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = res['error']?.toString() ?? 'Failed to load leave requests.';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'An error occurred while loading leave requests.';
        _isLoading = false;
      });
    }
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return Colors.green;
      case 'rejected':
        return Colors.red;
      case 'pending':
      default:
        return Colors.orange;
    }
  }

  String _capitalize(String text) {
    if (text.isEmpty) return '';
    return text[0].toUpperCase() + text.substring(1).toLowerCase();
  }

  void _openAddLeaveSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddLeaveBottomSheet(
        students: widget.students,
        onSuccess: () {
          _fetchLeaveRequests();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Leave request submitted successfully.'),
              backgroundColor: Colors.green,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text(
          'Leave Requests',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.blueAccent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: 'Refresh',
            onPressed: _fetchLeaveRequests,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: Colors.blueAccent,
        onRefresh: _fetchLeaveRequests,
        child: _buildBody(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddLeaveSheet,
        backgroundColor: Colors.blueAccent,
        tooltip: 'Request Leave',
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const CustomLoading(message: 'Loading leave requests...');
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
                    onPressed: _fetchLeaveRequests,
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

    if (_requests.isEmpty) {
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
                  Icon(Icons.assignment_outlined, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text(
                    'No leave requests found.',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Tap the + button to submit a new leave request.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: _requests.length,
      itemBuilder: (context, index) {
        final item = _requests[index];
        return _buildLeaveCard(item);
      },
    );
  }

  Widget _buildLeaveCard(dynamic item) {
    final studentName = item['student_name']?.toString() ?? 'Student';
    final leaveDate = item['leave_date']?.toString() ?? 'N/A';
    final reason = item['reason']?.toString() ?? 'N/A';
    final comment = item['comment']?.toString();
    final status = item['status']?.toString() ?? 'pending';

    final statusColor = _getStatusColor(status);
    final statusLabel = _capitalize(status);

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: Student Name & Status Badge
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: Colors.blueAccent.withOpacity(0.12),
                        child: const Icon(
                          Icons.person,
                          size: 18,
                          color: Colors.blueAccent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          studentName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor.withOpacity(0.5), width: 1),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            // Leave details: Date & Reason
            Row(
              children: [
                const Icon(Icons.calendar_today, size: 16, color: Colors.blueGrey),
                const SizedBox(width: 8),
                const Text(
                  'Date:',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.blueGrey, fontSize: 13),
                ),
                const SizedBox(width: 6),
                Text(
                  leaveDate,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.category_outlined, size: 16, color: Colors.blueGrey),
                const SizedBox(width: 8),
                const Text(
                  'Reason:',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.blueGrey, fontSize: 13),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    reason,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      color: Colors.black87,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            // Comment section (if provided)
            if (comment != null && comment.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.notes, size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        comment.trim(),
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade800,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddLeaveBottomSheet extends StatefulWidget {
  final List<dynamic> students;
  final VoidCallback onSuccess;

  const _AddLeaveBottomSheet({
    Key? key,
    required this.students,
    required this.onSuccess,
  }) : super(key: key);

  @override
  State<_AddLeaveBottomSheet> createState() => _AddLeaveBottomSheetState();
}

class _AddLeaveBottomSheetState extends State<_AddLeaveBottomSheet> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _commentController = TextEditingController();

  final List<String> _reasons = [
    'Medical',
    'Family Emergency',
    'Travel',
    'Personal',
    'Other',
  ];

  int? _selectedStudentId;
  DateTime? _selectedDate;
  String? _selectedReason;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.students.isNotEmpty) {
      _selectedStudentId = _getStudentId(widget.students[0]);
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
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

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Colors.blueAccent,
              onPrimary: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  String _formatDate(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedStudentId == null || _selectedStudentId == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a student.')),
      );
      return;
    }

    if (_selectedDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a leave date.')),
      );
      return;
    }

    if (_selectedReason == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a reason.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final leaveDateStr = _formatDate(_selectedDate!);
    final comment = _commentController.text.trim();

    try {
      final res = await ApiService.submitLeave(
        _selectedStudentId!,
        leaveDateStr,
        _selectedReason!,
        comment,
      );

      if (res['success'] == true) {
        if (mounted) {
          Navigator.pop(context);
          widget.onSuccess();
        }
      } else {
        if (mounted) {
          setState(() => _isSubmitting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(res['message']?.toString() ?? res['error']?.toString() ?? 'Failed to submit leave request.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('An error occurred. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Submit Leave Request',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(height: 16),
              const SizedBox(height: 8),

              // Child Dropdown
              const Text(
                'Select Child',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<int>(
                value: _selectedStudentId,
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  prefixIcon: const Icon(Icons.person, color: Colors.blueAccent),
                ),
                hint: const Text('Select a child'),
                items: widget.students.map((student) {
                  final id = _getStudentId(student);
                  final name = _getStudentName(student);
                  return DropdownMenuItem<int>(
                    value: id,
                    child: Text(name),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() {
                    _selectedStudentId = val;
                  });
                },
                validator: (val) => val == null ? 'Please select a child' : null,
              ),
              const SizedBox(height: 16),

              // Leave Date Picker Field
              const Text(
                'Leave Date',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 6),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.calendar_today, color: Colors.blueAccent, size: 20),
                          const SizedBox(width: 10),
                          Text(
                            _selectedDate != null
                                ? _formatDate(_selectedDate!)
                                : 'Select date',
                            style: TextStyle(
                              fontSize: 15,
                              color: _selectedDate != null ? Colors.black87 : Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      const Icon(Icons.arrow_drop_down, color: Colors.grey),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Reason Dropdown
              const Text(
                'Reason',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _selectedReason,
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  prefixIcon: const Icon(Icons.assignment, color: Colors.blueAccent),
                ),
                hint: const Text('Select a reason'),
                items: _reasons.map((reason) {
                  return DropdownMenuItem<String>(
                    value: reason,
                    child: Text(reason),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() {
                    _selectedReason = val;
                  });
                },
                validator: (val) => val == null ? 'Please select a reason' : null,
              ),
              const SizedBox(height: 16),

              // Additional Comment TextField
              const Text(
                'Additional Comment (Optional)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _commentController,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Enter any additional details or instructions...',
                  hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 22),

              // Submit Button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    elevation: 1,
                  ),
                  child: _isSubmitting
                      ? CustomLoading.indicator()
                      : const Text(
                          'Submit Leave Request',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
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
