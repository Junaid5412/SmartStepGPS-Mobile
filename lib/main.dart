import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/login_screen.dart';
import 'screens/monitor_dashboard.dart';
import 'screens/parent_dashboard.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // TODO: Initialize Firebase
  // await Firebase.initializeApp();
  
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('api_token');
  final role = prefs.getString('role');

  Widget initialScreen = const LoginScreen();
  if (token != null) {
    if (role == 'monitor') {
      initialScreen = const MonitorDashboard();
    } else if (role == 'parent') {
      initialScreen = const ParentDashboard();
    }
  }

  runApp(SmartStepApp(initialScreen: initialScreen));
}

class SmartStepApp extends StatelessWidget {
  final Widget initialScreen;

  const SmartStepApp({Key? key, required this.initialScreen}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Step GPS',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Roboto',
      ),
      home: initialScreen,
    );
  }
}
