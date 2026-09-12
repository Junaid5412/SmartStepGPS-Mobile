import 'package:flutter/material.dart';

class ParentDashboard extends StatelessWidget {
  const ParentDashboard({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Parent Dashboard')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.notifications_active, size: 64, color: Colors.blue),
            SizedBox(height: 16),
            Text('Waiting for bus updates...', style: TextStyle(fontSize: 18)),
            SizedBox(height: 8),
            Text('You will receive a push notification when your child boards or leaves the bus.', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
