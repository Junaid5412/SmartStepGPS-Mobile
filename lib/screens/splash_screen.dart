import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/app_errors.dart';
import '../widgets/bottom_strip.dart';
import 'login_screen.dart';
import 'parent_dashboard.dart';
import 'monitor_dashboard.dart';

/// ONE splash, not three.
///
/// A cold start used to show three different screens: the system splash (the logo on light grey),
/// then this screen in dark blue with the built-in name "Smart Step GPS", and a moment later the
/// same screen with the name the server sends ("Smart Step School Bus") - the title changed while
/// people were reading it.
///
/// Now this screen CONTINUES the system splash: the same light background (#F0F4F8, the
/// `splash_background` colour on Android and the LaunchScreen colour on iOS) and the same logo,
/// at the same size, in the same place - so its first frame looks exactly like what was already on
/// screen. The name and tagline then fade in underneath, once, and never change while visible:
/// they are the name remembered from the last launch, or - only on the very first launch - the one
/// the server sends, waited for briefly before anything is written.
class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFFF0F4F8);          // = android splash_background / iOS LaunchScreen
  static const _logoW = 121.0, _logoH = 100.0;   // = Android 12 splash_icon, launch_background, iOS launch screen (dp/pt)
  static const _prefName = 'brand_name', _prefTagline = 'brand_tagline';

  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final Animation<double> _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
  late final Animation<Offset> _rise = Tween<Offset>(begin: const Offset(0, 0.25), end: Offset.zero)
      .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));

  String? _name;      // null until decided - nothing is drawn under the logo before that
  String _tagline = 'Safe & Smart School Transport';

  Timer? _watchdog;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    AppErrors.screen = 'splash';
    bottomStripColor.value = _bg;            // no white band under the navigation bar while the splash is up
    // The splash can never be where the app stops: whatever goes wrong below, after 12 s it moves on to sign-in.
    _watchdog = Timer(const Duration(seconds: 12), () {
      if (!_left) {
        AppErrors.report('Splash watchdog: start-up did not finish in 12 s', StackTrace.current, kind: 'startup');
        _go(const LoginScreen());
      }
    });
    _initializeApp().catchError((Object e, StackTrace st) {
      AppErrors.report(e, st, kind: 'startup');
      _go(const LoginScreen());
    });
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    bottomStripColor.value = Colors.white;
    _anim.dispose();
    super.dispose();
  }

  void _go(Widget destination) {
    if (_left || !mounted) return;
    _left = true;
    _watchdog?.cancel();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (_, __, ___) => destination,
        transitionsBuilder: (_, animation, __, child) => FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  void _show(String name, String? tagline) {
    if (!mounted || _name != null) return;   // shown once; it never changes on screen
    setState(() {
      _name = name;
      if (tagline != null && tagline.trim().isNotEmpty) _tagline = tagline;
    });
    _anim.forward();
  }

  Future<void> _initializeApp() async {
    final stopwatch = Stopwatch()..start();
    final prefs = await SharedPreferences.getInstance();

    // The name from the last launch, shown at once.
    final cachedName = prefs.getString(_prefName);
    if (cachedName != null && cachedName.trim().isNotEmpty) _show(cachedName, prefs.getString(_prefTagline));

    // The server's name: remembered for the next launch. Only on a first launch (nothing remembered
    // yet) does this one go on screen - and it is waited for at most 1.5 s, then the built-in name.
    final fetch = ApiService.getSettings().then((settings) async {
      if (settings['success'] == true) {
        final name = (settings['company_name'] ?? settings['app_name'])?.toString();
        final tagline = settings['company_tagline']?.toString();
        if (name != null && name.trim().isNotEmpty) {
          await prefs.setString(_prefName, name);
          if (tagline != null && tagline.trim().isNotEmpty) await prefs.setString(_prefTagline, tagline);
          _show(name, tagline);
        }
      }
    }).catchError((e) { debugPrint('Splash: could not load settings from server: $e'); });
    if (_name == null) {
      await Future.any([fetch, Future.delayed(const Duration(milliseconds: 1500))]);
      _show('Smart Step School Bus', null);
    }

    // At least 1.6 s on screen, so the name can be read rather than flashing past.
    final elapsed = stopwatch.elapsedMilliseconds;
    if (elapsed < 1600) await Future.delayed(Duration(milliseconds: 1600 - elapsed));
    if (!mounted) return;

    // Check user session
    final token = await ApiService.getToken();
    final role = prefs.getString('role');

    Widget destination;
    // No "token != null" here: ApiService.getToken() returns a non-nullable String, so that test
    // was always true and only made this read as if it handled a case it never could.
    if (token.isNotEmpty && role != null) {
      if (role == 'monitor' || role == 'driver') {
        destination = const MonitorDashboard();
      } else {
        destination = const ParentDashboard();
      }
    } else {
      destination = const LoginScreen();
    }

    // Reading the token can be slow on a cold start, and the user can background the app in that window.
    _go(destination);
  }

  @override
  Widget build(BuildContext context) {
    // Light background: dark status-bar icons. Only icon brightness - no bar colours (Android 15 ignores
    // them and Google Play flags the calls; see main.dart).
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: _bg,
        body: LayoutBuilder(builder: (context, box) {
          // main.dart lifts every screen above the navigation bar; the system splash is centred in the
          // WHOLE window, so the centre here moves down by half that inset to land on the same spot.
          final inset = MediaQueryData.fromView(View.of(context)).padding.bottom;
          final centreY = (box.maxHeight + inset) / 2;
          final logoBottom = centreY + _logoH / 2;
          return Stack(
            children: [
              // Exactly where the system splash drew the logo: centred in the whole window.
              Positioned(
                top: centreY - _logoH / 2,
                left: 0,
                right: 0,
                child: Image.asset(
                  'assets/images/logo.png',
                  width: _logoW,
                  height: _logoH,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.directions_bus_rounded, size: 80, color: Color(0xFF1565C0)),
                ),
              ),
              // The name and tagline fade in under it - once.
              Positioned(
                top: logoBottom + 26,
                left: 24,
                right: 24,
                child: FadeTransition(
                  opacity: _fade,
                  child: SlideTransition(
                    position: _rise,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _name ?? '',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Color(0xFF0D2A6B), letterSpacing: 0.4),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _tagline,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: Color(0xFF64748B), letterSpacing: 0.3),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // A quiet progress line at the bottom while the session is checked.
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: FadeTransition(
                  opacity: _fade,
                  child: const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2, valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1565C0))),
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}
