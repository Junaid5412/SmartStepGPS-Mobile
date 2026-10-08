import 'package:flutter/material.dart';

import 'monitor_store.dart';
import 'monitor_widgets.dart';

class MonitorProfile extends StatelessWidget {
  final MonitorStore store;
  final VoidCallback onRefresh, onTerms, onPrivacy, onAbout, onDeleteAccount, onSignOut;
  final void Function(String phone) onCall;

  const MonitorProfile({
    super.key,
    required this.store,
    required this.onRefresh,
    required this.onTerms,
    required this.onPrivacy,
    required this.onAbout,
    required this.onDeleteAccount,
    required this.onSignOut,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    final hasDriver = store.driverName.isNotEmpty && store.driverName != 'Not Assigned';
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        GradientHeader(
          colors: const [MonitorColors.navyDeep, MonitorColors.navy],
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 26),
          child: Column(
            children: [
              Initials(name: store.staffName, size: 72, dark: true),
              const SizedBox(height: 12),
              Text(store.staffName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  HeaderChip(icon: Icons.badge_rounded, text: store.staffRole),
                  HeaderChip(icon: Icons.directions_bus_rounded, text: store.busName),
                ],
              ),
            ],
          ),
        ),
        PageWidth(
          max: 640,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasDriver) ...[
                  _group([
                    _tile(Icons.person_pin_rounded, 'Driver', onTap: store.driverPhone.isEmpty ? null : () => onCall(store.driverPhone),
                        subtitle: [store.driverName, if (store.driverPhone.isNotEmpty) store.driverPhone].join(' · '),
                        trailing: store.driverPhone.isEmpty
                            ? null
                            : const Icon(Icons.call_rounded, color: Color(0xFF16A34A))),
                  ]),
                  const SizedBox(height: 14),
                ],
                _group([
                  _tile(Icons.refresh_rounded, 'Refresh student list', onTap: onRefresh),
                  _tile(Icons.description_rounded, 'Terms & Conditions', onTap: onTerms),
                  _tile(Icons.privacy_tip_rounded, 'Privacy Policy', onTap: onPrivacy),
                  _tile(Icons.info_rounded, 'About Smart Step School Bus', onTap: onAbout),
                ]),
                const SizedBox(height: 14),
                _group([
                  _tile(Icons.delete_forever_rounded, 'Delete account', onTap: onDeleteAccount, color: MonitorColors.amber),
                  _tile(Icons.logout_rounded, 'Sign out', onTap: onSignOut, color: MonitorColors.red),
                ]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _group(List<Widget> tiles) => SurfaceCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 56, color: MonitorColors.line),
              tiles[i],
            ],
          ],
        ),
      );

  Widget _tile(IconData icon, String title,
      {VoidCallback? onTap, String? subtitle, Widget? trailing, Color color = MonitorColors.navy}) {
    final danger = color != MonitorColors.navy;
    return ListTile(
      onTap: onTap,
      leading: IconTile(icon: icon, color: color, size: 36),
      title: Text(title,
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: danger ? color : MonitorColors.ink)),
      subtitle: subtitle == null ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing ?? (danger ? null : const Icon(Icons.chevron_right_rounded, color: MonitorColors.muted)),
    );
  }
}
