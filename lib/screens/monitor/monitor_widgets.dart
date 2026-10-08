import 'package:flutter/material.dart';

import 'monitor_store.dart';

/// Keeps content to a readable width on tablets and in landscape, centred.
class PageWidth extends StatelessWidget {
  final Widget child;
  final double max;
  const PageWidth({super.key, required this.child, this.max = 760});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: max), child: child),
      );
}

/// Dark gradient top band, under the status bar.
class GradientHeader extends StatelessWidget {
  final List<Color> colors;
  final Widget child;
  final EdgeInsets padding;
  const GradientHeader({
    super.key,
    required this.colors,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(18, 14, 18, 20),
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(26)),
        ),
        child: SafeArea(
          bottom: false,
          child: PageWidth(child: Padding(padding: padding, child: child)),
        ),
      );
}

class HeaderChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const HeaderChip({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white70),
            const SizedBox(width: 6),
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}

class Initials extends StatelessWidget {
  final String name;
  final double size;
  final bool dark;
  final Color color;
  const Initials({super.key, required this.name, this.size = 36, this.dark = false, this.color = MonitorColors.navy});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final text = parts.isEmpty
        ? '?'
        : (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dark ? Colors.white.withValues(alpha: 0.16) : color.withValues(alpha: 0.10),
        shape: BoxShape.circle,
        border: dark ? Border.all(color: Colors.white24) : null,
      ),
      child: Text(text,
          style: TextStyle(
              color: dark ? Colors.white : color, fontWeight: FontWeight.w800, fontSize: size * 0.36)),
    );
  }
}

class IconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final bool onDark;
  const IconTile({super.key, required this.icon, required this.color, this.size = 44, this.onDark = false});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: onDark ? Colors.white.withValues(alpha: 0.16) : color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Icon(icon, color: onDark ? Colors.amberAccent : color, size: size * 0.5),
      );
}

class SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? borderColor;
  const SurfaceCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.borderColor});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor ?? MonitorColors.line),
            ),
            child: child,
          ),
        ),
      );
}

class ProgressRing extends StatelessWidget {
  final double value;
  final String label;
  final String caption;
  final Color color;
  final Color track;
  final double size;
  const ProgressRing({
    super.key,
    required this.value,
    required this.label,
    required this.caption,
    required this.color,
    required this.track,
    this.size = 86,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CircularProgressIndicator(
              value: value,
              strokeWidth: 8,
              strokeCap: StrokeCap.round,
              backgroundColor: track,
              valueColor: AlwaysStoppedAnimation(color),
            ),
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 18)),
                      Text(caption, style: TextStyle(color: color.withValues(alpha: 0.75), fontSize: 11)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

class StatTile extends StatelessWidget {
  final String label;
  final int value;
  final IconData icon;
  final Color color;
  const StatTile({super.key, required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => SurfaceCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            IconTile(icon: icon, color: color, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$value',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: MonitorColors.ink)),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: MonitorColors.muted)),
                ],
              ),
            ),
          ],
        ),
      );
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: MonitorColors.ink)),
          ),
          if (trailing != null) trailing!,
        ],
      );
}

class ErrorNote extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;
  const ErrorNote({super.key, required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFECACA)),
          ),
          child: Row(
            children: [
              const Icon(Icons.wifi_off_rounded, color: MonitorColors.red, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(color: Color(0xFF991B1B), fontSize: 13))),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

/// Small coloured status label.
class StatusPill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const StatusPill({super.key, required this.text, required this.color, this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
            Text(text, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}
