import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../widgets/custom_loading.dart';

class TermsScreen extends StatefulWidget {
  const TermsScreen({Key? key}) : super(key: key);

  @override
  State<TermsScreen> createState() => _TermsScreenState();
}

class _TermsScreenState extends State<TermsScreen> {
  bool _isLoading = true;
  String _termsContent = '';
  String _lastUpdated = 'September 2026';

  @override
  void initState() {
    super.initState();
    _fetchTerms();
  }

  Future<void> _fetchTerms() async {
    try {
      final res = await ApiService.getSettings();
      if (res['success'] == true && res['terms_and_conditions'] != null && res['terms_and_conditions'].toString().trim().isNotEmpty) {
        setState(() {
          _termsContent = res['terms_and_conditions'].toString();
          _isLoading = false;
        });
        return;
      }
    } catch (e) { debugPrint('Terms: could not load settings from server: $e'); }

    // Fallback default terms
    setState(() {
      _termsContent = _defaultTerms;
      _isLoading = false;
    });
  }

  static const String _defaultTerms = '''
1. Acceptance of Terms
By accessing or using the Smart Step GPS mobile application and its associated services, you agree to be bound by these Terms and Conditions. If you do not agree, please do not use the application.

2. Transportation & Real-Time Tracking
Smart Step GPS provides real-time school bus tracking, attendance logging, geofenced notifications, and route monitoring for parents, school staff, and authorized monitors. While we strive for maximum accuracy, GPS coordinates and estimated arrival times (ETAs) may experience occasional fluctuations due to cellular network conditions, weather, or hardware telemetry latency.

3. Parent & Guardian Responsibilities
Parents and guardians are responsible for ensuring that their contact information, authorized pickup contacts, and student profiles are accurate and up-to-date. Parents must ensure children are present at designated bus stops at the specified morning pickup time.

4. Account Security & Privacy
Users are responsible for safeguarding their login credentials. Any unauthorized access using your account must be reported immediately to school administration. Your personal and location data is processed strictly in accordance with our Privacy Policy and applicable data protection regulations.

5. Attendance & Leave Notices
Parents can submit student absence and leave notifications via the portal. Submissions should be made prior to the scheduled bus departure to allow drivers and bus monitors to optimize route schedules.

6. Service Availability & Updates
The service is provided on an "as is" and "as available" basis. We reserve the right to modify or discontinue features, update software versions, or perform maintenance with or without notice.

7. Contact & Support
For any questions regarding these terms, school bus routes, or technical support, please contact your school administration or email support@khanhub.site.
''';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        title: const Text(
          'Terms & Conditions',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF1565C0),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Open in Browser',
            icon: const Icon(Icons.open_in_browser_rounded, color: Colors.white),
            onPressed: () => launchUrl(Uri.parse('https://gps.khanhub.site/terms.html')),
          ),
        ],
      ),
      body: _isLoading
          ? const CustomLoading(message: 'Loading Terms & Conditions...')
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1565C0), Color(0xFF1A237E)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF1565C0).withOpacity(0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.gavel_rounded,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Smart Step GPS',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'User Agreement & Policies • $_lastUpdated',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.85),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Content card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: SelectableText(
                        _termsContent,
                        style: const TextStyle(
                          fontSize: 14.5,
                          height: 1.6,
                          color: Color(0xFF2C3E50),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // External Web Policy Link
                    Center(
                      child: TextButton.icon(
                        onPressed: () => launchUrl(Uri.parse('https://gps.khanhub.site/privacy.html')),
                        icon: const Icon(Icons.shield_outlined, size: 18, color: Color(0xFF1565C0)),
                        label: const Text(
                          'View Privacy Policy',
                          style: TextStyle(
                            color: Color(0xFF1565C0),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
    );
  }
}
