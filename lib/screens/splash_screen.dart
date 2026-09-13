import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'login_screen.dart';
import 'parent_dashboard.dart';
import 'monitor_dashboard.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  String _appName = 'Smart Step GPS';
  String _tagline = 'Safe & Smart School Transit';

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _scaleAnimation = Tween<double>(begin: 0.75, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutBack),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeIn),
    );

    _animController.forward();
    _initializeApp();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    // Run settings fetch and minimum splash delay concurrently
    final stopwatch = Stopwatch()..start();

    try {
      final settings = await ApiService.getSettings();
      if (settings['success'] == true) {
        if (mounted) {
          setState(() {
            _appName = settings['company_name'] ?? settings['app_name'] ?? _appName;
            _tagline = settings['company_tagline'] ?? _tagline;
          });
        }
      }
    } catch (_) {}

    // Ensure at least 1.8 seconds of splash time for smooth UX
    final elapsed = stopwatch.elapsedMilliseconds;
    if (elapsed < 1800) {
      await Future.delayed(Duration(milliseconds: 1800 - elapsed));
    }

    if (!mounted) return;

    // Check user session
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token');
    final role = prefs.getString('role');

    Widget destination;
    if (token != null && token.isNotEmpty && role != null) {
      if (role == 'monitor' || role == 'driver') {
        destination = const MonitorDashboard();
      } else {
        destination = const ParentDashboard();
      }
    } else {
      destination = const LoginScreen();
    }

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => destination,
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1565C0), // Deep blue
              Color(0xFF0D47A1), // Navy
              Color(0xFF0A192F), // Dark navy
            ],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // Background decorative circles
              Positioned(
                top: -60,
                right: -60,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.04),
                  ),
                ),
              ),
              Positioned(
                bottom: -80,
                left: -80,
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.04),
                  ),
                ),
              ),

              // Center Logo & Branding
              Center(
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: ScaleTransition(
                    scale: _scaleAnimation,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Glowing outer circle with Logo
                        Container(
                          padding: const EdgeInsets.all(22),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.35),
                                blurRadius: 35,
                                offset: const Offset(0, 14),
                              ),
                              BoxShadow(
                                color: const Color(0xFF42A5F5).withOpacity(0.4),
                                blurRadius: 40,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: ClipOval(
                            child: Image.asset(
                              'assets/images/logo.png',
                              width: 100,
                              height: 100,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.directions_bus_rounded,
                                size: 80,
                                color: Color(0xFF1565C0),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),

                        // App / Company Title
                        Text(
                          _appName,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Subtitle / Tagline
                        Text(
                          _tagline,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: Colors.white.withOpacity(0.85),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Bottom spinner & version
              Positioned(
                bottom: 36,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white.withOpacity(0.8)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Smart Transportation System',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withOpacity(0.6),
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
