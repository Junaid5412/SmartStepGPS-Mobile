import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import 'monitor_dashboard.dart';
import 'parent_dashboard.dart';
import 'forgot_password_screen.dart';
import 'terms_screen.dart';
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
    } catch (_) {}
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
      final result = await ApiService.login(
        _usernameController.text.trim(),
        _passwordController.text.trim(),
        'DUMMY_FCM_TOKEN',
      );
      setState(() => _isLoading = false);
      if (result['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('api_token', result['token']);
        await prefs.setString('role', result['role']);
        if (result['user'] != null && result['user']['name'] != null) {
          await prefs.setString('user_name', result['user']['name']);
        }
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
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network Error: Could not connect to server.'), backgroundColor: Colors.redAccent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1565C0), Color(0xFF0D47A1), Color(0xFF1A237E)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: FadeTransition(
                opacity: _fadeAnim,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Logo
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/logo.png',
                          height: 64,
                          width: 64,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => _logoUrl.isNotEmpty
                            ? Image.network(_logoUrl, height: 64, width: 64, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.directions_bus, size: 50, color: Color(0xFF1565C0)))
                            : const Icon(Icons.directions_bus, size: 50, color: Color(0xFF1565C0)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(_appName, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
                    const SizedBox(height: 6),
                    Text('Parent & Staff Portal', style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.7), letterSpacing: 0.5)),
                    const SizedBox(height: 40),

                    // Login Card
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 30, offset: const Offset(0, 10))],
                      ),
                      child: Column(
                        children: [
                          const Text('Sign In', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A237E))),
                          const SizedBox(height: 24),
                          TextField(
                            controller: _usernameController,
                            decoration: InputDecoration(
                              labelText: 'Username or Phone',
                              prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF1565C0)),
                              filled: true,
                              fillColor: const Color(0xFFF5F7FA),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF1565C0), width: 2)),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF1565C0)),
                              suffixIcon: IconButton(
                                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: Colors.grey),
                                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF5F7FA),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF1565C0), width: 2)),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                                );
                              },
                              child: const Text(
                                'Forgot Password?',
                                style: TextStyle(
                                  color: Color(0xFF1565C0),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _login,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1565C0),
                                disabledBackgroundColor: const Color(0xFF1565C0).withOpacity(0.6),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                elevation: 4,
                              ),
                              child: _isLoading 
                                ? CustomLoading.indicator()
                                : const Text('Sign In', style: TextStyle(fontSize: 17, color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => launchUrl(Uri.parse('https://gps.khanhub.site/privacy.html')),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                            child: Text('Privacy Policy', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12, decoration: TextDecoration.underline, decorationColor: Colors.white54)),
                          ),
                        ),
                        Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('|', style: TextStyle(color: Colors.white.withOpacity(0.4)))),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsScreen())),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                            child: Text('Terms & Conditions', style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12, decoration: TextDecoration.underline, decorationColor: Colors.white70)),
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
      ),
    );
  }
}
