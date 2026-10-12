import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// What the native map views (official Google map, OpenFreeMap) show, independent of which one draws it:
/// pins, the bus, a route line - and the camera calls the screens use.
///
/// Native maps draw markers as pictures, not Flutter widgets, so each pin is painted once into a small PNG
/// ([PinIcons]) and reused.

/// How one pin looks: a round badge with an icon or a number, and optionally a label above it.
@immutable
class PinStyle {
  final double size;          // badge diameter, logical pixels
  final Color color;          // badge colour
  final double border;        // white ring width
  final IconData? icon;       // icon inside the badge, or ...
  final String? text;         // ... a short text (stop number)
  final Color fg;             // icon / text colour
  final String? label;        // label above the badge ("Your stop", the school's name)
  final Color? labelColor;
  final Color? halo;          // soft ring around the badge (the bus)

  const PinStyle({
    required this.size,
    required this.color,
    this.border = 2,
    this.icon,
    this.text,
    this.fg = Colors.white,
    this.label,
    this.labelColor,
    this.halo,
  });

  String get key => [size, color.toARGB32(), border, icon?.codePoint, text, fg.toARGB32(), label, labelColor?.toARGB32(), halo?.toARGB32()].join('|');
}

/// A small rounded label on its own (the bus's speed pill), drawn upright above the bus.
@immutable
class PillStyle {
  final String text;
  final Color color;
  final Color? dot;
  const PillStyle({required this.text, required this.color, this.dot});
  String get key => 'pill|$text|${color.toARGB32()}|${dot?.toARGB32()}';
}

/// One fixed pin on the map.
@immutable
class GPin {
  final String id;
  final LatLng pos;
  final PinStyle style;
  final VoidCallback? onTap;
  const GPin({required this.id, required this.pos, required this.style, this.onTap});
}

/// One line on the map (the route ahead).
@immutable
class GLine {
  final String id;
  final List<LatLng> points;
  final Color color;
  final int width;
  const GLine({required this.id, required this.points, required this.color, this.width = 6});
}

/// The bus as it should look right now.
@immutable
class BusLook {
  final PinStyle body;
  final double heading;     // degrees, clockwise from north
  final bool rotate;        // turn the badge to face the heading (moving) or keep it upright (stopped)
  final PillStyle? pill;
  const BusLook({required this.body, this.heading = 0, this.rotate = false, this.pill});
}

/// Camera calls the screens make, whichever native map is on screen.
abstract class BusMapCam {
  double get zoom;
  void move(LatLng p, [double? zoom]);
  void animateTo(LatLng p, [double? zoom]);
  /// Keep the bus in the middle while it moves (called every frame of the glide; passed on a few times a second).
  void follow(LatLng p);
  /// Bring every point into view.
  void fit(List<LatLng> pts, {double padding = 48, double maxZoom = 17});
  /// North up again.
  void north();
  /// Move to [p], at least [minZoom], north up.
  void moveNorth(LatLng p, double minZoom);
  void dispose();
}

/// Throttles [BusMapCam.follow] to about eight camera moves a second.
class FollowThrottle {
  FollowThrottle(this._apply);
  final void Function(LatLng p) _apply;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _pending;
  Timer? _timer;

  void push(LatLng p) {
    _pending = p;
    final since = DateTime.now().difference(_last).inMilliseconds;
    if (since >= 120) {
      _flush();
    } else {
      _timer ??= Timer(Duration(milliseconds: 120 - since), _flush);
    }
  }

  void _flush() {
    _timer = null;
    final p = _pending;
    if (p == null) return;
    _pending = null;
    _last = DateTime.now();
    try {
      _apply(p);
    } catch (_) {}
  }

  void dispose() => _timer?.cancel();
}

/// The geometry of one painted pin.
class _PinLayout {
  final TextPainter? label;
  final double badge, labelH, w, h, cx, cy;
  _PinLayout(this.label, this.badge, this.labelH, this.w, this.h, this.cx, this.cy);
}

/// Paints [PinStyle]s and [PillStyle]s into PNG pictures at the screen's density, once each.
class PinIcons {
  PinIcons._();
  static final Map<String, Future<Uint8List>> _cache = {};

  static double get dpr {
    final views = ui.PlatformDispatcher.instance.views;
    return views.isEmpty ? 2.0 : views.first.devicePixelRatio.clamp(1.0, 4.0).toDouble();
  }

  static Future<Uint8List> pinPng(PinStyle s) => _cache.putIfAbsent(s.key, () => _paintPin(s));
  static Future<Uint8List> pillPng(PillStyle s) => _cache.putIfAbsent(s.key, () => _paintPill(s));

  static TextPainter _tp(String text, TextStyle style) =>
      TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, maxLines: 2, ellipsis: '…')
        ..layout(maxWidth: 150);

  static Future<Uint8List> _render(Size size, void Function(Canvas c) draw) async {
    final d = dpr;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(d);
    draw(c);
    final img = await rec.endRecording().toImage((size.width * d).ceil(), (size.height * d).ceil());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  static _PinLayout _layout(PinStyle s) {
    final label = s.label == null || s.label!.isEmpty
        ? null
        : _tp(s.label!, TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: s.labelColor ?? s.color, height: 1.2));
    final ring = s.halo != null ? s.size * 0.3 : 0.0;
    final badge = s.size + ring * 2;
    final labelH = label == null ? 0.0 : label.height + 8;
    final w = math.max(badge, label == null ? 0.0 : label.width + 14) + 4;
    final h = labelH + (label == null ? 0 : 3) + badge + 4;
    final cy = labelH + (label == null ? 0 : 3) + badge / 2 + 1;
    return _PinLayout(label, badge, labelH, w, h, w / 2, cy);
  }

  /// The picture's size in logical pixels.
  static Size sizeFor(PinStyle s) {
    final l = _layout(s);
    return Size(l.w, l.h);
  }

  /// Where the badge centre sits in the picture, as a 0..1 anchor.
  static Offset anchorFor(PinStyle s) {
    final l = _layout(s);
    return Offset(0.5, l.cy / l.h);
  }

  static Future<Uint8List> _paintPin(PinStyle s) {
    final l = _layout(s);
    return _render(Size(l.w, l.h), (c) {
      final cx = l.cx, cy = l.cy;
      final label = l.label;
      if (label != null) {
        final r = RRect.fromRectAndRadius(Rect.fromLTWH(cx - label.width / 2 - 6, 1, label.width + 12, label.height + 6), const Radius.circular(6));
        c.drawRRect(r.shift(const Offset(0, 1)), Paint()..color = const Color(0x33000000));
        c.drawRRect(r, Paint()..color = Colors.white);
        label.paint(c, Offset(cx - label.width / 2, 4));
      }
      if (s.halo != null) c.drawCircle(Offset(cx, cy), l.badge / 2, Paint()..color = s.halo!);
      c.drawCircle(Offset(cx, cy + 1.5), s.size / 2, Paint()..color = const Color(0x40000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      c.drawCircle(Offset(cx, cy), s.size / 2, Paint()..color = Colors.white);
      c.drawCircle(Offset(cx, cy), s.size / 2 - s.border, Paint()..color = s.color);
      if (s.icon != null) {
        final ic = s.icon!;
        final t = _tp(String.fromCharCode(ic.codePoint),
            TextStyle(fontFamily: ic.fontFamily, package: ic.fontPackage, fontSize: s.size * 0.55, color: s.fg, height: 1));
        t.paint(c, Offset(cx - t.width / 2, cy - t.height / 2));
      } else if (s.text != null) {
        final t = _tp(s.text!, TextStyle(fontSize: s.size * 0.4, fontWeight: FontWeight.w800, color: s.fg, height: 1));
        t.paint(c, Offset(cx - t.width / 2, cy - t.height / 2));
      }
    });
  }

  /// The pill sits well above its point (the bus): the picture has empty space under it, so it is anchored at
  /// its bottom centre.
  static Future<Uint8List> _paintPill(PillStyle s) {
    final t = _tp(s.text, const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white, height: 1.1));
    final dotW = s.dot != null ? 10.0 : 0.0;
    final pw = t.width + 14 + dotW, ph = t.height + 7;
    const gap = 30.0;                       // space between the pill and the bus centre
    final w = pw + 4, h = ph + gap + 2;
    return _render(Size(w, h), (c) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(2, 1, pw, ph), Radius.circular(ph / 2));
      c.drawRRect(r, Paint()..color = s.color);
      c.drawRRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
      var x = 2 + 7.0;
      if (s.dot != null) {
        c.drawCircle(Offset(x + 3, 1 + ph / 2), 3, Paint()..color = s.dot!);
        x += dotW;
      }
      t.paint(c, Offset(x, 1 + (ph - t.height) / 2));
    });
  }
}

/// Watches the fingers on a native map: a drag of more than a few pixels is the user taking over (the native
/// maps do not say whether a camera move came from a finger).
class GestureWatch extends StatefulWidget {
  final Widget child;
  final VoidCallback? onUserGesture;
  const GestureWatch({super.key, required this.child, this.onUserGesture});

  @override
  State<GestureWatch> createState() => _GestureWatchState();
}

class _GestureWatchState extends State<GestureWatch> {
  Offset? _down;
  bool _dragged = false;

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (e) {
          _down = e.position;
          _dragged = false;
        },
        onPointerMove: (e) {
          final d = _down;
          if (!_dragged && d != null && (e.position - d).distance > 12) {
            _dragged = true;
            widget.onUserGesture?.call();
          }
        },
        onPointerUp: (_) => _down = null,
        child: widget.child,
      );
}
