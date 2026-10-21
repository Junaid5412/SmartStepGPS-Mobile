import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'monitor_dashboard.dart';
import 'parent_dashboard.dart';
import 'forgot_password_screen.dart';
import 'terms_screen.dart';
import 'privacy_screen.dart';
import '../widgets/custom_loading.dart';
import '../widgets/bottom_strip.dart';
import '../services/app_errors.dart';

/// Sign-in: a light screen with the company logo up top, the form in the middle, and a navy hill at the
/// bottom carrying the yellow Sign in button (2026-10 redesign). The background is a quiet morning school
/// run: a soft sun and clouds behind the logo, and on the hill a skyline, a school, two children waiting
/// at the stop and a yellow school bus that drives up to them when the screen opens.
class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  // The palette of this screen.
  static const _bg = Color(0xFFEEF2FA);       // pale lavender-blue page
  static const _blob = Color(0xFFE1E7F3);     // the soft shapes behind
  static const _field = Color(0xFFE2E8F5);    // pill fields
  static const _navy = Color(0xFF0B1446);     // headings, the hill
  static const _ink = Color(0xFF3A4170);      // secondary text
  static const _hint = Color(0xFF8C93B3);
  static const _yellow = Color(0xFFFFC83D);   // school-bus yellow

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String _logoUrl = '';
  late final AnimationController _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final Animation<double> _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
  late final Animation<Offset> _riseAnim = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
      .animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));
  // The bus driving up to the stop, once, after the page has faded in.
  late final AnimationController _driveController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
  late final Animation<double> _drive = CurvedAnimation(parent: _driveController, curve: const Interval(0.2, 1, curve: Curves.easeOutCubic));
  static const _scene = 48.0;   // height of the scene drawn above the hill's top edge

  @override
  void initState() {
    super.initState();
    AppErrors.screen = 'login';
    bottomStripColor.value = _navy;          // the strip under the navigation bar continues the navy hill
    _animController.forward();
    _driveController.forward();
    _loadSettings();
    _checkExistingSession();
  }

  @override
  void dispose() {
    bottomStripColor.value = Colors.white;
    _animController.dispose();
    _driveController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Remove animations" in the accessibility settings: the bus is simply parked at the stop.
    if (MediaQuery.of(context).disableAnimations) _driveController.value = 1;
  }

  Future<void> _checkExistingSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token');
    final role = prefs.getString('role');
    if (!mounted) return;
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
      if (settings['success'] == true && mounted) {
        setState(() => _logoUrl = settings['logo'] ?? '');
      }
    } catch (e) { debugPrint('Login: could not load branding settings: $e'); }
  }

  void _login() async {
    FocusScope.of(context).unfocus();
    if (_usernameController.text.trim().isEmpty || _passwordController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your username and password'), backgroundColor: Colors.orange),
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
        const SnackBar(content: Text('Network error: could not connect to the server.'), backgroundColor: Colors.redAccent),
      );
    }
  }

  // ─── pieces ───────────────────────────────────────────────────────────────────────────────────

  Widget _logo() {
    Widget fallback() => _logoUrl.isNotEmpty
        ? Image.network(_logoUrl, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.directions_bus_rounded, size: 72, color: _navy))
        : const Icon(Icons.directions_bus_rounded, size: 72, color: _navy);
    return Container(
      width: 212,
      height: 212,
      decoration: const BoxDecoration(color: _blob, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Image.asset('assets/images/logo.png', fit: BoxFit.contain, errorBuilder: (_, __, ___) => fallback()),
      ),
    );
  }

  Widget _pillField({
    required TextEditingController controller,
    required String hint,
    required Widget suffix,
    bool obscure = false,
    TextInputType keyboard = TextInputType.text,
    TextInputAction action = TextInputAction.next,
    ValueChanged<String>? onSubmitted,
    List<String>? autofill,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      textInputAction: action,
      onSubmitted: onSubmitted,
      autofillHints: autofill,
      autocorrect: false,
      enableSuggestions: !obscure,
      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: _navy),
      cursorColor: _navy,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _hint),
        filled: true,
        fillColor: _field,
        contentPadding: const EdgeInsets.fromLTRB(24, 18, 12, 18),
        suffixIcon: Padding(padding: const EdgeInsets.only(right: 10), child: suffix),
        suffixIconConstraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(32), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(32), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(32), borderSide: const BorderSide(color: _navy, width: 1.6)),
      ),
    );
  }

  /// The navy hill: a dome across the bottom, with the school-run scene painted along its top edge.
  Widget _hill({required Widget child}) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: _scene),
          child: ClipPath(
            clipper: _HillClipper(),
            child: Container(
              width: double.infinity,
              color: _navy,
              padding: const EdgeInsets.fromLTRB(24, 66, 24, 18),
              child: child,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: _scene + 50,
          child: IgnorePointer(child: CustomPaint(painter: _SchoolRunPainter(drive: _drive, sky: _scene))),
        ),
      ],
    );
  }

  Widget _link(String text, VoidCallback onTap, {Color color = const Color(0xFFB9C1E4), FontWeight weight = FontWeight.w500}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Text(text, style: TextStyle(color: color, fontSize: 12.5, fontWeight: weight)),
      ),
    );
  }

  // ─── layout ───────────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final form = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: AutofillGroup(
        child: Column(
          children: [
            _pillField(
              controller: _usernameController,
              hint: 'Username or phone',
              keyboard: TextInputType.emailAddress,
              autofill: const [AutofillHints.username],
              suffix: const Icon(Icons.person_outline_rounded, color: _navy, size: 24),
            ),
            const SizedBox(height: 16),
            _pillField(
              controller: _passwordController,
              hint: 'Password',
              obscure: _obscurePassword,
              action: TextInputAction.done,
              onSubmitted: (_) => _isLoading ? null : _login(),
              autofill: const [AutofillHints.password],
              suffix: IconButton(
                tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: _navy, size: 23),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordScreen())),
                style: TextButton.styleFrom(foregroundColor: _ink, padding: const EdgeInsets.fromLTRB(8, 10, 6, 4)),
                child: const Text('Forgot password?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );

    final signIn = SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _login,
        style: ElevatedButton.styleFrom(
          backgroundColor: _yellow,
          disabledBackgroundColor: _yellow.withValues(alpha: 0.7),
          foregroundColor: _navy,
          elevation: 0,
          shape: const StadiumBorder(),
        ),
        child: _isLoading
            ? CustomLoading.indicator(color: _navy)
            : const Text('SIGN IN', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 1)),
      ),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light page: dark status-bar icons; light icons over the navy hill at the bottom.
      value: const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            // The morning sky behind the logo.
            Positioned.fill(
              child: IgnorePointer(child: CustomPaint(painter: _SkyPainter(top: MediaQuery.of(context).padding.top))),
            ),
            LayoutBuilder(builder: (context, box) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: IntrinsicHeight(
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: SlideTransition(
                        position: _riseAnim,
                        child: Column(
                          children: [
                            SizedBox(height: MediaQuery.of(context).padding.top + 28),
                            _logo(),
                            const SizedBox(height: 26),
                            const Text('WELCOME BACK',
                                style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900, color: _navy, letterSpacing: 0.4)),
                            const SizedBox(height: 4),
                            const Text('SIGN IN',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _ink, letterSpacing: 1.6)),
                            const SizedBox(height: 26),
                            form,
                            const Spacer(),
                            const SizedBox(height: 8),
                            _hill(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  signIn,
                                  const SizedBox(height: 14),
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      const Text("Can't sign in? ", style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w500)),
                                      _link('Reset your password', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordScreen())),
                                          color: _yellow, weight: FontWeight.w800),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _link('Privacy policy', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyScreen()))),
                                      Container(width: 3, height: 3, decoration: const BoxDecoration(color: Color(0xFF6E78A6), shape: BoxShape.circle)),
                                      _link('Terms of service', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsScreen()))),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// The top edge of the navy hill: a wide, gentle dome.
class _HillClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(0, 46)
      ..quadraticBezierTo(size.width / 2, -26, size.width, 46)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// The morning sky: a soft sun, two clouds and a pair of birds, kept clear of the logo circle.
class _SkyPainter extends CustomPainter {
  const _SkyPainter({required this.top});
  final double top;   // status-bar height

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final sun = Offset(w * 0.13 + 6, top + 58);
    canvas.drawCircle(sun, 42, Paint()..color = const Color(0xFFFFC83D).withValues(alpha: 0.10));
    canvas.drawCircle(sun, 26, Paint()..color = const Color(0xFFFFE7A6));

    final white = Paint()..color = Colors.white;
    void cloud(Offset c, double s) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: c.translate(0, 6 * s), width: 70 * s, height: 18 * s), Radius.circular(9 * s)), white);
      canvas.drawCircle(c.translate(-12 * s, 0), 12 * s, white);
      canvas.drawCircle(c.translate(8 * s, -4 * s), 15 * s, white);
    }
    cloud(Offset(w * 0.84, top + 46), 1);
    cloud(Offset(w * 0.12, top + 168), 0.7);

    final bird = Paint()
      ..color = const Color(0xFFB5C0DA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    void flyer(Offset o, double s) => canvas.drawPath(
        Path()
          ..moveTo(o.dx - 6 * s, o.dy - 3 * s)
          ..quadraticBezierTo(o.dx - 3 * s, o.dy - 5 * s, o.dx, o.dy)
          ..quadraticBezierTo(o.dx + 3 * s, o.dy - 5 * s, o.dx + 6 * s, o.dy - 3 * s),
        bird);
    flyer(Offset(w * 0.78, top + 82), 1);
    flyer(Offset(w * 0.85, top + 94), 0.8);
  }

  @override
  bool shouldRepaint(covariant _SkyPainter old) => old.top != top;
}

/// The scene on the hill's top edge: a pastel skyline on the left, a small school on the right, two
/// children with a backpack waiting at the bus stop, a dashed road, and the yellow school bus that
/// drives in from the school side and stops beside them. Its hill line is the curve of [_HillClipper]
/// moved down by [sky].
class _SchoolRunPainter extends CustomPainter {
  _SchoolRunPainter({required this.drive, required this.sky}) : super(repaint: drive);
  final Animation<double> drive;
  final double sky;

  static const _navy = Color(0xFF0B1446);
  static const _yellow = Color(0xFFFFC83D);
  static const _stopX = 104.0;

  double _hillY(double x, double w) {
    final u = (x / w).clamp(0.0, 1.0);
    return sky + 46 - 144 * u * (1 - u);
  }

  double _slope(double x, double w) => -144 * (1 - 2 * x / w) / w;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final windows = Paint()..color = const Color(0xFFEEF2FA);

    // Skyline on the left (its feet are covered by the hill painted over it).
    final block = Paint()..color = const Color(0xFFD6DEEE);
    for (final b in const [[2.0, 16.0, 28.0], [20.0, 22.0, 42.0], [44.0, 14.0, 22.0]]) {
      final x = b[0], bw = b[1], h = b[2];
      final topY = _hillY(x + bw, w) - h;
      canvas.drawRect(Rect.fromLTWH(x, topY, bw, sky + 60 - topY), block);
      for (double wy = topY + 5; wy < topY + h - 8; wy += 8) {
        for (double wx = x + 4; wx < x + bw - 4; wx += 7) {
          canvas.drawRect(Rect.fromLTWH(wx, wy, 3.5, 3.5), windows);
        }
      }
    }

    // A small school on the right: gable roof, round clock window, a flag.
    final sx = w - 58, sw = 48.0;
    final bodyTop = _hillY(sx + sw / 2, w) - 30;
    canvas.drawRect(Rect.fromLTWH(sx, bodyTop, sw, sky + 60 - bodyTop), Paint()..color = const Color(0xFFD3DBEC));
    final apex = Offset(sx + sw / 2, bodyTop - 16);
    canvas.drawPath(
        Path()
          ..moveTo(sx - 4, bodyTop + 1)
          ..lineTo(apex.dx, apex.dy)
          ..lineTo(sx + sw + 4, bodyTop + 1)
          ..close(),
        Paint()..color = const Color(0xFFC3CEE6));
    canvas.drawCircle(Offset(apex.dx, bodyTop - 5), 3.6, windows);
    canvas.drawRect(Rect.fromLTWH(apex.dx - 0.8, apex.dy - 14, 1.6, 14), Paint()..color = const Color(0xFF9AA8CC));
    canvas.drawRect(Rect.fromLTWH(apex.dx + 0.8, apex.dy - 14, 10, 6), Paint()..color = _yellow);
    canvas.drawRect(Rect.fromLTWH(sx + 6, bodyTop + 6, 8, 6), windows);
    canvas.drawRect(Rect.fromLTWH(sx + sw - 14, bodyTop + 6, 8, 6), windows);
    canvas.drawRect(Rect.fromLTWH(apex.dx - 5, bodyTop + 10, 10, 20), Paint()..color = const Color(0xFFB4C1DE));

    // The hill's top, over the feet of the buildings (the same navy as the hill below).
    canvas.drawPath(
        Path()
          ..moveTo(0, sky + 46)
          ..quadraticBezierTo(w / 2, sky - 26, w, sky + 46)
          ..lineTo(w, size.height + 12)
          ..lineTo(0, size.height + 12)
          ..close(),
        Paint()..color = _navy);

    // The road: a dashed lane line following the hill.
    final dash = Paint()
      ..color = const Color(0xFF2A3576)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final road = Path()
      ..moveTo(0, sky + 60)
      ..quadraticBezierTo(w / 2, sky - 12, w, sky + 60);
    for (final m in road.computeMetrics()) {
      for (double d = 4; d < m.length; d += 19) {
        canvas.drawPath(m.extractPath(d, d + 10), dash);
      }
    }

    // The bus stop.
    final stopBase = _hillY(_stopX, w) + 2;
    canvas.drawRect(Rect.fromLTWH(_stopX - 1, stopBase - 34, 2, 34), Paint()..color = const Color(0xFF7C8BB8));
    canvas.drawCircle(Offset(_stopX, stopBase - 38), 7, Paint()..color = _yellow);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(_stopX, stopBase - 38), width: 7, height: 5), const Radius.circular(1.2)),
        Paint()..color = _navy);

    // Two children waiting, holding hands, the taller one with a yellow backpack.
    void child(double x, double s, Color c, {bool bag = false}) {
      final base = _hillY(x, w) + 1;
      final legs = Paint()..color = const Color(0xFF5D6C9E);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - 3 * s, base - 7 * s, 2.6 * s, 7 * s), Radius.circular(s)), legs);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + 0.4 * s, base - 7 * s, 2.6 * s, 7 * s), Radius.circular(s)), legs);
      if (bag) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - 8 * s, base - 18 * s, 4.5 * s, 9 * s), Radius.circular(1.5 * s)), Paint()..color = _yellow);
      }
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - 4.5 * s, base - 19 * s, 9 * s, 13 * s), Radius.circular(3.5 * s)), Paint()..color = c);
      canvas.drawCircle(Offset(x, base - 23.5 * s), 4.3 * s, Paint()..color = c);
    }
    const kidA = 66.0, kidB = 84.0;
    child(kidA, 1, const Color(0xFF7C8BB8), bag: true);
    child(kidB, 0.82, const Color(0xFF8F9DC8));
    canvas.drawLine(Offset(kidA + 4, _hillY(kidA, w) - 11), Offset(kidB - 3.5, _hillY(kidB, w) - 9),
        Paint()
          ..color = const Color(0xFF8F9DC8)
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round);

    // The school bus: drives in from the school side and stops beside the children, tilted with the hill.
    final endX = _stopX + 56, startX = endX + w * 0.24;
    final bx = startX + (endX - startX) * drive.value;
    canvas.save();
    canvas.translate(bx, _hillY(bx, w) + 1);
    canvas.rotate(math.atan(_slope(bx, w)));
    canvas.scale(-1, 1);   // drawn facing right, shown facing left (towards the stop)
    canvas.drawRRect(
        RRect.fromLTRBAndCorners(-32, -27, 32, -4,
            topLeft: const Radius.circular(6), topRight: const Radius.circular(9),
            bottomLeft: const Radius.circular(3), bottomRight: const Radius.circular(3)),
        Paint()..color = _yellow);
    canvas.drawRect(const Rect.fromLTWH(-32, -10, 64, 2), Paint()..color = const Color(0xFFE0A526));
    final glass = Paint()..color = Colors.white.withValues(alpha: 0.95);
    for (var i = 0; i < 4; i++) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(-28 + i * 11.0, -23, 8.5, 7), const Radius.circular(1.5)), glass);
    }
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(17, -23, 12, 9), const Radius.circular(2)), Paint()..color = const Color(0xFF8FB3E6));
    canvas.drawCircle(const Offset(29.5, -7), 1.8, Paint()..color = Colors.white);
    for (final wx in const [-18.0, 19.0]) {
      canvas.drawCircle(Offset(wx, -3), 5, Paint()..color = const Color(0xFF1C2558));
      canvas.drawCircle(Offset(wx, -3), 2, Paint()..color = const Color(0xFFC9D3E8));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SchoolRunPainter old) => old.sky != sky || old.drive != drive;
}
