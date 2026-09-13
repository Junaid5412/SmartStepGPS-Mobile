import 'package:flutter/material.dart';

class CustomLoading extends StatefulWidget {
  final String? message;
  final double size;
  final Color primaryColor;
  final Color? backgroundColor;

  const CustomLoading({
    Key? key,
    this.message = 'Loading...',
    this.size = 90.0,
    this.primaryColor = const Color(0xFF1565C0),
    this.backgroundColor,
  }) : super(key: key);

  /// Compact spinner suitable for button actions
  static Widget indicator({double size = 20.0, Color color = Colors.white, double strokeWidth = 2.5}) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: strokeWidth,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }

  @override
  State<CustomLoading> createState() => _CustomLoadingState();
}

class _CustomLoadingState extends State<CustomLoading> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.94, end: 1.06).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ScaleTransition(
            scale: _pulseAnimation,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Outer rotating/glowing circular progress indicator
                SizedBox(
                  width: widget.size,
                  height: widget.size,
                  child: CircularProgressIndicator(
                    strokeWidth: 3.5,
                    valueColor: AlwaysStoppedAnimation<Color>(widget.primaryColor),
                    backgroundColor: widget.primaryColor.withOpacity(0.15),
                  ),
                ),
                // Inner white badge containing logo
                Container(
                  width: widget.size * 0.76,
                  height: widget.size * 0.76,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: widget.primaryColor.withOpacity(0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: EdgeInsets.all(widget.size * 0.12),
                  child: Image.asset(
                    'assets/images/logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Icon(
                        Icons.directions_bus_rounded,
                        color: widget.primaryColor,
                        size: widget.size * 0.45,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          if (widget.message != null && widget.message!.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              widget.message!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: widget.primaryColor.withOpacity(0.85),
                letterSpacing: 0.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
