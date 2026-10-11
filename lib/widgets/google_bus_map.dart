import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';

/// The official Google Maps view used by the parent and monitor maps when the portal chooses
/// "Google Maps - official" (and the app was built with a Google Maps API key).
///
/// Google's map draws markers as pictures, not Flutter widgets, so each pin is painted once into a small
/// image ([PinStyle] -> [PinIcons]) and reused. The screens describe what to show - pins, the bus, a route
/// line - and drive the camera through [GoogleMapCam]; everything Google-specific stays in this file.

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

/// A small rounded label on its own (the bus's speed pill), kept upright above the bus.
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

/// Paints [PinStyle]s and [PillStyle]s into marker pictures, once each.
class PinIcons {
  PinIcons._();
  static final Map<String, Future<gm.BitmapDescriptor>> _cache = {};

  static double get _dpr {
    final views = ui.PlatformDispatcher.instance.views;
    return views.isEmpty ? 2.0 : views.first.devicePixelRatio.clamp(1.0, 4.0).toDouble();
  }

  static Future<gm.BitmapDescriptor> pin(PinStyle s) => _cache.putIfAbsent(s.key, () => _paintPin(s));
  static Future<gm.BitmapDescriptor> pill(PillStyle s) => _cache.putIfAbsent(s.key, () => _paintPill(s));

  static TextPainter _tp(String text, TextStyle style) =>
      TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, maxLines: 2, ellipsis: '…')
        ..layout(maxWidth: 150);

  static Future<gm.BitmapDescriptor> _render(Size size, void Function(Canvas c) draw) async {
    final dpr = _dpr;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(dpr);
    draw(c);
    final img = await rec.endRecording().toImage((size.width * dpr).ceil(), (size.height * dpr).ceil());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return gm.BitmapDescriptor.bytes(data!.buffer.asUint8List(), imagePixelRatio: dpr);
  }

  /// Badge at the bottom centre of the picture, label above it. Anchor: the badge centre (see [anchorFor]).
  static Future<gm.BitmapDescriptor> _paintPin(PinStyle s) {
    final label = s.label == null || s.label!.isEmpty
        ? null
        : _tp(s.label!, TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: s.labelColor ?? s.color, height: 1.2));
    final ring = s.halo != null ? s.size * 0.3 : 0.0;
    final badge = s.size + ring * 2;
    final labelH = label == null ? 0.0 : label.height + 8;
    final w = math.max(badge, label == null ? 0.0 : label.width + 14) + 4;
    final h = labelH + (label == null ? 0 : 3) + badge + 4;
    return _render(Size(w, h), (c) {
      final cx = w / 2;
      if (label != null) {
        final r = RRect.fromRectAndRadius(Rect.fromLTWH(cx - label.width / 2 - 6, 1, label.width + 12, label.height + 6), const Radius.circular(6));
        c.drawRRect(r.shift(const Offset(0, 1)), Paint()..color = const Color(0x33000000));
        c.drawRRect(r, Paint()..color = Colors.white);
        label.paint(c, Offset(cx - label.width / 2, 4));
      }
      final cy = labelH + (label == null ? 0 : 3) + badge / 2 + 1;
      if (s.halo != null) c.drawCircle(Offset(cx, cy), badge / 2, Paint()..color = s.halo!);
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

  /// Where the badge centre sits in [_paintPin]'s picture, as a 0..1 anchor.
  static Offset anchorFor(PinStyle s) {
    final hasLabel = s.label != null && s.label!.isNotEmpty;
    if (!hasLabel) return const Offset(0.5, 0.5);
    final label = _tp(s.label!, TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: s.labelColor ?? s.color, height: 1.2));
    final ring = s.halo != null ? s.size * 0.3 : 0.0;
    final badge = s.size + ring * 2;
    final labelH = label.height + 8;
    final h = labelH + 3 + badge + 4;
    return Offset(0.5, (labelH + 3 + badge / 2 + 1) / h);
  }

  /// The pill sits well above its point (the bus), so the picture has empty space under it.
  static Future<gm.BitmapDescriptor> _paintPill(PillStyle s) {
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

/// Camera control for the Google map, with the calls the screens need.
class GoogleMapCam {
  GoogleMapCam._(this._c, this._pos);
  final gm.GoogleMapController _c;
  gm.CameraPosition _pos;
  DateTime _lastFollow = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _pendingFollow;
  Timer? _followTimer;

  double get zoom => _pos.zoom;
  double get bearing => _pos.bearing;

  static gm.LatLng g(LatLng p) => gm.LatLng(p.latitude, p.longitude);

  void move(LatLng p, [double? zoom]) {
    _c.moveCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(target: g(p), zoom: zoom ?? _pos.zoom, bearing: _pos.bearing)));
  }

  void animateTo(LatLng p, [double? zoom]) {
    _c.animateCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(target: g(p), zoom: zoom ?? _pos.zoom, bearing: _pos.bearing)));
  }

  /// Keep the bus in the middle while it moves. Called every frame of the bus's glide; passed on to Google
  /// at most about eight times a second, which looks smooth and keeps the phone cool.
  void follow(LatLng p) {
    _pendingFollow = p;
    final since = DateTime.now().difference(_lastFollow).inMilliseconds;
    if (since >= 120) {
      _flushFollow();
    } else {
      _followTimer ??= Timer(Duration(milliseconds: 120 - since), _flushFollow);
    }
  }

  void _flushFollow() {
    _followTimer = null;
    final p = _pendingFollow;
    if (p == null) return;
    _pendingFollow = null;
    _lastFollow = DateTime.now();
    try {
      move(p);
    } catch (_) {}
  }

  /// Bring every point into view.
  void fit(List<LatLng> pts, {double padding = 48, double maxZoom = 17}) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      animateTo(pts.first, math.min(15, maxZoom));
      return;
    }
    var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
    for (final p in pts) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    // Points almost on top of each other: Google would zoom in to the limit.
    if ((n - s).abs() < 0.0005 && (e - w).abs() < 0.0005) {
      animateTo(LatLng((n + s) / 2, (e + w) / 2), math.min(16, maxZoom));
      return;
    }
    _c.animateCamera(gm.CameraUpdate.newLatLngBounds(
        gm.LatLngBounds(southwest: gm.LatLng(s, w), northeast: gm.LatLng(n, e)), padding));
  }

  /// North up again.
  void north() {
    _c.animateCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(target: _pos.target, zoom: _pos.zoom, bearing: 0)));
  }

  /// Move to [p], at least [minZoom], north up.
  void moveNorth(LatLng p, double minZoom) {
    _c.animateCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(target: g(p), zoom: math.max(_pos.zoom, minZoom), bearing: 0)));
  }

  void dispose() => _followTimer?.cancel();
}

/// The Google map with the screen's pins, the bus and a route line.
class GoogleBusMap extends StatefulWidget {
  final LatLng initialCenter;
  final double initialZoom;
  final bool hybrid;
  final List<GPin> pins;
  final List<GLine> lines;
  final ValueListenable<LatLng?>? bus;
  final BusLook Function()? busLook;
  final VoidCallback? onBusTap;
  final EdgeInsets padding;               // keeps Google's logo and fitted views clear of the screen's cards
  final void Function(GoogleMapCam cam)? onReady;
  final VoidCallback? onUserGesture;      // the user dragged / pinched the map
  final ValueChanged<double>? onRotation; // map turn in degrees, same sense as flutter_map's rotation

  const GoogleBusMap({
    super.key,
    required this.initialCenter,
    this.initialZoom = 15,
    this.hybrid = false,
    this.pins = const [],
    this.lines = const [],
    this.bus,
    this.busLook,
    this.onBusTap,
    this.padding = EdgeInsets.zero,
    this.onReady,
    this.onUserGesture,
    this.onRotation,
  });

  @override
  State<GoogleBusMap> createState() => _GoogleBusMapState();
}

class _GoogleBusMapState extends State<GoogleBusMap> {
  GoogleMapCam? _cam;
  final Map<String, gm.BitmapDescriptor> _icons = {};
  Timer? _busTimer;
  Offset? _down;
  bool _dragged = false;

  @override
  void initState() {
    super.initState();
    widget.bus?.addListener(_busMoved);
  }

  @override
  void didUpdateWidget(covariant GoogleBusMap old) {
    super.didUpdateWidget(old);
    if (old.bus != widget.bus) {
      old.bus?.removeListener(_busMoved);
      widget.bus?.addListener(_busMoved);
    }
  }

  @override
  void dispose() {
    widget.bus?.removeListener(_busMoved);
    _busTimer?.cancel();
    _cam?.dispose();
    super.dispose();
  }

  /// The bus glides every frame; the Google map is told at most ten times a second.
  void _busMoved() {
    if (_busTimer != null) return;
    _busTimer = Timer(const Duration(milliseconds: 100), () {
      _busTimer = null;
      if (mounted) setState(() {});
    });
  }

  gm.BitmapDescriptor? _icon(String key, Future<gm.BitmapDescriptor> Function() make) {
    final have = _icons[key];
    if (have != null) return have;
    make().then((d) {
      if (!mounted) return;
      setState(() => _icons[key] = d);
    }).catchError((Object e) {
      debugPrint('GoogleBusMap: could not paint a pin: $e');
    });
    return null;
  }

  Set<gm.Marker> _markers() {
    final out = <gm.Marker>{};
    for (final p in widget.pins) {
      final ic = _icon(p.style.key, () => PinIcons.pin(p.style));
      if (ic == null) continue;
      out.add(gm.Marker(
        markerId: gm.MarkerId(p.id),
        position: GoogleMapCam.g(p.pos),
        icon: ic,
        anchor: PinIcons.anchorFor(p.style),
        consumeTapEvents: p.onTap != null,
        onTap: p.onTap,
        zIndex: 1,
      ));
    }
    final pos = widget.bus?.value;
    final look = widget.busLook?.call();
    if (pos != null && look != null) {
      final body = _icon(look.body.key, () => PinIcons.pin(look.body));
      if (body != null) {
        out.add(gm.Marker(
          markerId: const gm.MarkerId('bus'),
          position: GoogleMapCam.g(pos),
          icon: body,
          anchor: const Offset(0.5, 0.5),
          // Moving: the arrow lies flat on the map and points the way the bus drives, however the map is turned.
          flat: look.rotate,
          rotation: look.rotate ? look.heading : 0,
          consumeTapEvents: widget.onBusTap != null,
          onTap: widget.onBusTap,
          zIndex: 3,
        ));
      }
      final pl = look.pill;
      if (pl != null) {
        final pic = _icon(pl.key, () => PinIcons.pill(pl));
        if (pic != null) {
          out.add(gm.Marker(
            markerId: const gm.MarkerId('bus_pill'),
            position: GoogleMapCam.g(pos),
            icon: pic,
            anchor: const Offset(0.5, 1.0),
            zIndex: 4,
          ));
        }
      }
    }
    return out;
  }

  Set<gm.Polyline> _polylines() {
    final out = <gm.Polyline>{};
    for (final l in widget.lines) {
      if (l.points.length < 2) continue;
      final pts = [for (final p in l.points) GoogleMapCam.g(p)];
      // A white edge under the coloured line, like the line on the other maps.
      out.add(gm.Polyline(polylineId: gm.PolylineId('${l.id}_edge'), points: pts, color: Colors.white, width: l.width + 4,
          jointType: gm.JointType.round, startCap: gm.Cap.roundCap, endCap: gm.Cap.roundCap, zIndex: 1));
      out.add(gm.Polyline(polylineId: gm.PolylineId(l.id), points: pts, color: l.color, width: l.width,
          jointType: gm.JointType.round, startCap: gm.Cap.roundCap, endCap: gm.Cap.roundCap, zIndex: 2));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Google's map does not say whether a camera move came from a finger, so watch the fingers here: a drag of
      // more than a few pixels or a second finger is the user taking over.
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
      child: gm.GoogleMap(
        initialCameraPosition: gm.CameraPosition(target: GoogleMapCam.g(widget.initialCenter), zoom: widget.initialZoom),
        mapType: widget.hybrid ? gm.MapType.hybrid : gm.MapType.normal,
        markers: _markers(),
        polylines: _polylines(),
        padding: widget.padding,
        compassEnabled: false,          // the screens show their own compass button
        mapToolbarEnabled: false,
        zoomControlsEnabled: false,
        myLocationButtonEnabled: false,
        myLocationEnabled: false,
        rotateGesturesEnabled: true,
        tiltGesturesEnabled: false,
        buildingsEnabled: true,
        trafficEnabled: false,
        minMaxZoomPreference: const gm.MinMaxZoomPreference(6, 20),
        onMapCreated: (c) {
          final cam = GoogleMapCam._(c, gm.CameraPosition(target: GoogleMapCam.g(widget.initialCenter), zoom: widget.initialZoom));
          _cam = cam;
          widget.onReady?.call(cam);
        },
        onCameraMove: (pos) {
          _cam?._pos = pos;
          // Google's bearing is where the camera faces; north on screen is the opposite turn.
          widget.onRotation?.call((360 - pos.bearing) % 360);
        },
      ),
    );
  }
}
