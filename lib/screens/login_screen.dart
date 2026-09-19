import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import 'monitor_dashboard.dart';
import 'parent_dashboard.dart';
import 'forgot_password_screen.dart';
import 'terms_screen.dart';
import 'privacy_screen.dart';
import '../widgets/custom_loading.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String _logoUrl = '';
  String _appName = 'Smart Step GPS';
  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _animController.forward();
    _loadSettings();
    _checkExistingSession();
  }

  @override
  void dispose() {
    _animController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _checkExistingSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token');
    final role = prefs.getString('role');
    if (token != null && token.isNotEmpty && role != null) {
      if (role == 'monitor' || role == 'driver') {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MonitorDashboard()));
      } else {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ParentDashboard()));
      }
    }
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await ApiService.getSettings();
      if (settings['success'] == true) {
        setState(() {
          _appName = settings['app_name'] ?? 'Smart Step GPS';
          _logoUrl = settings['logo'] ?? '';
        });
      }
    } catch (e) { debugPrint('Login: could not load branding settings: $e'); }
  }

  void _login() async {
    if (_usernameController.text.trim().isEmpty || _passwordController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter username and password'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() => _isLoading = true);
    try {
      // Empty, not 'DUMMY_FCM_TOKEN'. Push notifications are not wired up in this build - there is
      // no firebase_messaging dependency and no google-services.json - so there is no real token to
      // send. Sending a placeholder wrote the literal string "DUMMY_FCM_TOKEN" into every user's
      // fcm_token column, and api/mobile/attendance.php then tried to push to it on every pickup,
      // filling logs/fcm.log with deliveries that never happened. An empty value is stored as NULL,
      // which is the truth: we have no way to reach this device.
      final result = await ApiService.login(
        _usernameController.text.trim(),
        _passwordController.text.trim(),
        '',
      );
      // The sign-in request is slow enough that the user can leave this screen, or Android can
      // dispose it, before the reply lands. Touching setState or context after that throws
      // "setState() called after dispose()" / "Looking up a deactivated widget's ancestor" - a
      // crash on a bad connection rather than on a bad password. Every use of either after an
      // await is guarded from here on.
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (result['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await ApiService.setToken(result['token']);
        await prefs.setString('role', result['role']);
        if (result['user'] != null && result['user']['name'] != null) {
          await prefs.setString('user_name', result['user']['name']);
        }
        if (!mounted) return;
        if (result['role'] == 'monitor' || result['role'] == 'driver') {
          Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MonitorDashboard()));
        } else {
          Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ParentDashboard()));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['error'] ?? 'Login failed'), backgroundColor: Colors.redAccent),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network Error: Could not connect to server.'), backgroundColor: Colors.redAccent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const _AnimatedBackground(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
              child: FadeTransition(
                opacity: _fadeAnim,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 20),
                    // Logo Header
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.15),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/logo.png',
                          height: 80,
                          width: 80,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => _logoUrl.isNotEmpty
                            ? Image.network(_logoUrl, height: 80, width: 80, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.directions_bus, size: 50, color: Color(0xFF0D47A1)))
                            : const Icon(Icons.directions_bus, size: 50, color: Color(0xFF0D47A1)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(_appName, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1.2)),
                    const SizedBox(height: 8),
                    Text('Safe & Smart School Fleet Transportation', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.9), letterSpacing: 0.5, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 48),

                    // Login Card
                    Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 40, offset: const Offset(0, 15)),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Welcome Back', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                          const SizedBox(height: 6),
                          const Text('Sign in to your account to continue', style: TextStyle(fontSize: 14, color: Color(0xFF64748B))),
                          const SizedBox(height: 32),
                          
                          // Username Field
                          TextField(
                            controller: _usernameController,
                            style: const TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF1E293B)),
                            decoration: InputDecoration(
                              labelText: 'Username or Phone',
                              labelStyle: const TextStyle(color: Color(0xFF64748B)),
                              prefixIcon: const Icon(Icons.person_outline_rounded, color: Color(0xFF3B82F6)),
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 2)),
                              contentPadding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                          const SizedBox(height: 20),
                          
                          // Password Field
                          TextField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            style: const TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF1E293B)),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              labelStyle: const TextStyle(color: Color(0xFF64748B)),
                              prefixIcon: const Icon(Icons.lock_outline_rounded, color: Color(0xFF3B82F6)),
                              suffixIcon: IconButton(
                                icon: Icon(_obscurePassword ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: const Color(0xFF94A3B8)),
                                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 2)),
                              contentPadding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                          
                          // Forgot Password
                          Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12, bottom: 20),
                              child: TextButton(
                                onPressed: () {
                                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()));
                                },
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text(
                                  'Forgot Password?',
                                  style: TextStyle(
                                    color: Color(0xFF3B82F6),
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          
                          // Sign In Button
                          Container(
                            width: double.infinity,
                            height: 56,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)]),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(color: const Color(0xFF2563EB).withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6)),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _login,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              child: _isLoading 
                                ? CustomLoading.indicator(color: Colors.white)
                                : const Text('Sign In', style: TextStyle(fontSize: 17, color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                    
                    // Footer Links
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyScreen())),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                            child: Text('Privacy Policy', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 13, fontWeight: FontWeight.w500)),
                          ),
                        ),
                        Container(width: 4, height: 4, margin: const EdgeInsets.symmetric(horizontal: 4), decoration: BoxDecoration(color: Colors.white.withOpacity(0.5), shape: BoxShape.circle)),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsScreen())),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                            child: Text('Terms of Service', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 13, fontWeight: FontWeight.w500)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
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

class _AnimatedBackground extends StatefulWidget {
  const _AnimatedBackground({Key? key}) : super(key: key);

  @override
  __AnimatedBackgroundState createState() => __AnimatedBackgroundState();
}

class __AnimatedBackgroundState extends State<_AnimatedBackground> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final width = MediaQuery.of(context).size.width;
        final height = MediaQuery.of(context).size.height;
        return Stack(
          children: [
            // Base Color
            Container(color: const Color(0xFF0F172A)),
            
            // Orb 1
            Positioned(
              left: width * 0.1 + (math.sin(_controller.value * 2 * math.pi) * 80),
              top: height * 0.1 + (math.cos(_controller.value * 2 * math.pi) * 80),
              child: Container(
                width: 350, height: 350,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF2563EB).withOpacity(0.6),
                ),
              ),
            ),
            
            // Orb 2
            Positioned(
              right: -50 + (math.cos(_controller.value * 2 * math.pi) * 100),
              bottom: height * 0.2 + (math.sin(_controller.value * 2 * math.pi) * 100),
              child: Container(
                width: 400, height: 400,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0EA5E9).withOpacity(0.5),
                ),
              ),
            ),
            
            // Orb 3
            Positioned(
              left: -50 + (math.sin(_controller.value * 2 * math.pi + math.pi) * 100),
              bottom: -50 + (math.cos(_controller.value * 2 * math.pi + math.pi) * 100),
              child: Container(
                width: 300, height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF818CF8).withOpacity(0.4),
                ),
              ),
            ),
            
            // Blur overlay
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                child: Container(color: Colors.transparent),
              ),
            ),
            
            // Subtle dotted pattern overlay
            Positioned.fill(
              child: Opacity(
                opacity: 0.1,
                child: Image.asset(
                  'assets/images/pattern.png', // Fallback to transparent if absent
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
