import 'package:flutter/material.dart';
import '../services/api_service.dart';

class MonitorDashboard extends StatefulWidget {
  const MonitorDashboard({Key? key}) : super(key: key);

  @override
  _MonitorDashboardState createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends State<MonitorDashboard> {
  List<dynamic> _students = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRoster();
  }

  Future<void> _loadRoster() async {
    setState(() => _isLoading = true);
    final response = await ApiService.getRoster();
    if (response['success'] == true) {
      setState(() {
        _students = response['data'];
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(response['error'] ?? 'Failed to load roster')));
    }
  }

  Future<void> _markAttendance(int studentId, String type) async {
    // Determine location dynamically in real app via geolocator
    final response = await ApiService.markAttendance(studentId, type, 0.0, 0.0);
    if (response['success'] == true) {
      _loadRoster();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(response['error'] ?? 'Failed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Route Roster')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _students.length,
              itemBuilder: (context, index) {
                final student = _students[index];
                final status = student['today_status'];
                
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ListTile(
                    title: Text(student['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Stop: \${student["address"]}'),
                    trailing: status != null 
                        ? Text(status['event_type'].toString().toUpperCase(), style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.directions_bus, color: Colors.blue),
                                onPressed: () => _markAttendance(student['id'], 'pickup'),
                                tooltip: 'Pick Up',
                              ),
                              IconButton(
                                icon: const Icon(Icons.home, color: Colors.orange),
                                onPressed: () => _markAttendance(student['id'], 'dropoff'),
                                tooltip: 'Drop Off',
                              ),
                            ],
                          ),
                  ),
                );
              },
            ),
    );
  }
}
