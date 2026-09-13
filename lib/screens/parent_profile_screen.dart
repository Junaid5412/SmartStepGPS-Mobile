import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/custom_loading.dart';

class ParentProfileScreen extends StatefulWidget {
  const ParentProfileScreen({Key? key}) : super(key: key);

  @override
  _ParentProfileScreenState createState() => _ParentProfileScreenState();
}

class _ParentProfileScreenState extends State<ParentProfileScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isChangingPassword = false;

  final _fatherNameCtrl = TextEditingController();
  final _fatherPhoneCtrl = TextEditingController();
  final _fatherEmailCtrl = TextEditingController();
  final _motherNameCtrl = TextEditingController();
  final _motherPhoneCtrl = TextEditingController();
  final _motherEmailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  final _oldPasswordCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  String _username = '';

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _isLoading = true);
    final res = await ApiService.getProfile();
    if (res['success'] == true) {
      final p = res['profile'] ?? {};
      setState(() {
        _username = p['username'] ?? '';
        _fatherNameCtrl.text = p['father_name'] ?? '';
        _fatherPhoneCtrl.text = p['father_phone'] ?? '';
        _fatherEmailCtrl.text = p['father_email'] ?? '';
        _motherNameCtrl.text = p['mother_name'] ?? '';
        _motherPhoneCtrl.text = p['mother_phone'] ?? '';
        _motherEmailCtrl.text = p['mother_email'] ?? '';
        _addressCtrl.text = p['address'] ?? '';
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res['error'] ?? 'Failed to load profile'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  Future<void> _saveProfile() async {
    setState(() => _isSaving = true);
    final res = await ApiService.updateProfile(
      fatherName: _fatherNameCtrl.text.trim(),
      fatherPhone: _fatherPhoneCtrl.text.trim(),
      fatherEmail: _fatherEmailCtrl.text.trim(),
      motherName: _motherNameCtrl.text.trim(),
      motherPhone: _motherPhoneCtrl.text.trim(),
      motherEmail: _motherEmailCtrl.text.trim(),
      address: _addressCtrl.text.trim(),
    );
    setState(() => _isSaving = false);

    if (res['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Profile details updated successfully!'),
        backgroundColor: Colors.green,
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res['error'] ?? 'Failed to update profile'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  Future<void> _changePassword() async {
    final oldPass = _oldPasswordCtrl.text.trim();
    final newPass = _newPasswordCtrl.text.trim();
    final confirmPass = _confirmPasswordCtrl.text.trim();

    if (oldPass.isEmpty || newPass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please fill all password fields'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    if (newPass != confirmPass) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('New passwords do not match'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    if (newPass.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Password must be at least 6 characters long'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    setState(() => _isChangingPassword = true);
    final res = await ApiService.changePassword(oldPass, newPass);
    setState(() => _isChangingPassword = false);

    if (res['success'] == true) {
      _oldPasswordCtrl.clear();
      _newPasswordCtrl.clear();
      _confirmPasswordCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Password changed successfully!'),
        backgroundColor: Colors.green,
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res['error'] ?? 'Failed to change password'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        title: const Text('My Profile & Settings', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoading
          ? const CustomLoading(message: 'Loading your profile...')
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Username banner
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF0D47A1)]),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        const CircleAvatar(radius: 26, backgroundColor: Colors.white24, child: Icon(Icons.person, color: Colors.white, size: 30)),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Parent Portal Account', style: TextStyle(color: Colors.white70, fontSize: 12)),
                            Text(_username.isNotEmpty ? _username : 'Parent User', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Father Information Card
                  _buildSectionHeader(Icons.male, 'Father / Guardian Information', Colors.blue),
                  _buildCard([
                    _buildTextField(_fatherNameCtrl, 'Father Full Name', Icons.person_outline),
                    _buildTextField(_fatherPhoneCtrl, 'Father Phone Number', Icons.phone_outlined, keyboardType: TextInputType.phone),
                    _buildTextField(_fatherEmailCtrl, 'Father Email Address', Icons.email_outlined, keyboardType: TextInputType.emailAddress),
                  ]),
                  const SizedBox(height: 18),

                  // Mother Information Card
                  _buildSectionHeader(Icons.female, 'Mother / Guardian Information', Colors.pink),
                  _buildCard([
                    _buildTextField(_motherNameCtrl, 'Mother Full Name', Icons.person_outline),
                    _buildTextField(_motherPhoneCtrl, 'Mother Phone Number', Icons.phone_outlined, keyboardType: TextInputType.phone),
                    _buildTextField(_motherEmailCtrl, 'Mother Email Address', Icons.email_outlined, keyboardType: TextInputType.emailAddress),
                  ]),
                  const SizedBox(height: 18),

                  // Home Stop / Address Card
                  _buildSectionHeader(Icons.location_on, 'Home Address / Default Pickup Stop', Colors.orange),
                  _buildCard([
                    _buildTextField(_addressCtrl, 'Street Address / Stop Landmark', Icons.home_outlined, maxLines: 2),
                  ]),
                  const SizedBox(height: 14),

                  // Save Profile Button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveProfile,
                      icon: _isSaving ? CustomLoading.indicator() : const Icon(Icons.check),
                      label: Text(_isSaving ? 'Saving Changes...' : 'Save Profile Details', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Change Password Section
                  _buildSectionHeader(Icons.lock_outline, 'Change Password', Colors.teal),
                  _buildCard([
                    _buildTextField(_oldPasswordCtrl, 'Current Password', Icons.lock_clock, obscureText: true),
                    _buildTextField(_newPasswordCtrl, 'New Password (min 6 chars)', Icons.lock, obscureText: true),
                    _buildTextField(_confirmPasswordCtrl, 'Confirm New Password', Icons.check_circle_outline, obscureText: true),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton.icon(
                        onPressed: _isChangingPassword ? null : _changePassword,
                        icon: _isChangingPassword ? CustomLoading.indicator() : const Icon(Icons.vpn_key),
                        label: Text(_isChangingPassword ? 'Updating...' : 'Update Password', style: const TextStyle(fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal[700],
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 30),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionHeader(IconData icon, String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
        ],
      ),
    );
  }

  Widget _buildCard(List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, IconData icon, {TextInputType? keyboardType, bool obscureText = false, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboardType,
        obscureText: obscureText,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 20, color: const Color(0xFF1565C0)),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF1565C0), width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }
}
