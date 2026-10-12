import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import 'bus_map_common.dart';

/// The free map: OpenFreeMap's OpenStreetMap styles drawn by MapLibre, natively on the phone's graphics chip
/// (App Module Settings -> "OpenFreeMap"). No API key, no account, no usage limit; the map credit sits in the
/// small (i) button in the corner, as OpenStreetMap's licence asks.

/// Camera control for the MapLibre map.
class LibreMapCam implements BusMapCam {
  LibreMapCam._(this._c, this._pad) {
    _follow = FollowThrottle((p) => move(p));
  }
  final ml.MapLibreMapController _c;
  final EdgeInsets _pad;
  late final FollowThrottle _follow;

  static ml.LatLng l(LatLng p) => ml.LatLng(p.latitude, p.longitude);

  ml.CameraPosition? get _pos => _c.cameraPosition;
  double get bearing => _pos?.bearing ?? 0;

  @override
  double get zoom => _pos?.zoom ?? 15;

  @override
  void move(LatLng p, [double? zoom]) {
    _c.moveCamera(ml.CameraUpdate.newCameraPosition(ml.CameraPosition(target: l(p), zoom: zoom ?? this.zoom, bearing: bearing)));
  }

  @override
  void animateTo(LatLng p, [double? zoom]) {
    _c.animateCamera(ml.CameraUpdate.newCameraPosition(ml.CameraPosition(target: l(p), zoom: zoom ?? this.zoom, bearing: bearing)),
        duration: const Duration(milliseconds: 600));
  }

  @override
  void follow(LatLng p) => _follow.push(p);

  @override
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
    if ((n - s).abs() < 0.0005 && (e - w).abs() < 0.0005) {
      animateTo(LatLng((n + s) / 2, (e + w) / 2), math.min(16, maxZoom));
      return;
    }
    _c.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        ml.LatLngBounds(southwest: ml.LatLng(s, w), northeast: ml.LatLng(n, e)),
        left: padding + _pad.left,
        top: padding + _pad.top,
        right: padding + _pad.right,
        bottom: padding + _pad.bottom,
      ),
      duration: const Duration(milliseconds: 700),
    );
  }

  @override
  void north() {
    _c.animateCamera(ml.CameraUpdate.bearingTo(0), duration: const Duration(milliseconds: 400));
  }

  @override
  void moveNorth(LatLng p, double minZoom) {
    _c.animateCamera(ml.CameraUpdate.newCameraPosition(ml.CameraPosition(target: l(p), zoom: math.max(zoom, minZoom), bearing: 0)),
        duration: const Duration(milliseconds: 600));
  }

  @override
  void dispose() => _follow.dispose();
}

/// The MapLibre map with the screen's pins, the bus and a route line.
class LibreBusMap extends StatefulWidget {
  final String styleUrl;
  final LatLng initialCenter;
  final double initialZoom;
  final List<GPin> pins;
  final List<GLine> lines;
  final ValueListenable<LatLng?>? bus;
  final BusLook Function()? busLook;
  final EdgeInsets padding;               // kept clear when fitting a view (the screen's header and card)
  final void Function(BusMapCam cam)? onReady;
  final VoidCallback? onUserGesture;
  final ValueChanged<double>? onRotation; // map turn in degrees, same sense as flutter_map's rotation

  const LibreBusMap({
    super.key,
    required this.styleUrl,
    required this.initialCenter,
    this.initialZoom = 15,
    this.pins = const [],
    this.lines = const [],
    this.bus,
    this.busLook,
    this.padding = EdgeInsets.zero,
    this.onReady,
    this.onUserGesture,
    this.onRotation,
  });

  @override
  State<LibreBusMap> createState() => _LibreBusMapState();
}

class _LibreBusMapState extends State<LibreBusMap> {
  ml.MapLibreMapController? _c;
  LibreMapCam? _cam;
  bool _styleReady = false;
  final Set<String> _images = {};
  final Map<String, ml.Symbol> _symbols = {};     // our id -> symbol on the map
  final Map<String, String> _symSig = {};         // our id -> what it shows now
  final Map<String, String> _tapIds = {};         // map symbol id -> our id
  final Map<String, List<ml.Line>> _lines = {};
  final Map<String, String> _lineSig = {};
  bool _syncing = false;
  bool _again = false;
  Timer? _busTimer;
  double _bearing = 0;

  @override
  void initState() {
    super.initState();
    widget.bus?.addListener(_busMoved);
  }

  @override
  void didUpdateWidget(covariant LibreBusMap old) {
    super.didUpdateWidget(old);
    if (old.bus != widget.bus) {
      old.bus?.removeListener(_busMoved);
      widget.bus?.addListener(_busMoved);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.bus?.removeListener(_busMoved);
    _busTimer?.cancel();
    _c?.onSymbolTapped.remove(_onSymbolTap);
    _cam?.dispose();
    super.dispose();
  }

  /// The bus glides every frame; the map is told at most ten times a second.
  void _busMoved() {
    if (_busTimer != null) return;
    _busTimer = Timer(const Duration(milliseconds: 100), () {
      _busTimer = null;
      _sync();
    });
  }

  void _onSymbolTap(ml.Symbol s) {
    final id = _tapIds[s.id];
    if (id == null) return;
    for (final p in widget.pins) {
      if (p.id == id) {
        p.onTap?.call();
        return;
      }
    }
  }

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// Registers a painted picture with the map once, and returns its name.
  Future<String> _image(String key, Future<Uint8List> Function() png) async {
    final name = 'ss${key.hashCode & 0x7fffffff}';
    if (!_images.contains(name)) {
      await _c!.addImage(name, await png());
      _images.add(name);
    }
    return name;
  }

  /// Brings the map's symbols and lines in line with the widget. One run at a time; a change that arrives while
  /// one is running is picked up by a second run.
  Future<void> _sync() async {
    if (!_styleReady || _c == null || !mounted) return;
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again && mounted);
    } catch (e) {
      debugPrint('LibreBusMap: update failed: $e');
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    final c = _c!;
    final want = <String, ml.SymbolOptions>{};
    final sig = <String, String>{};

    for (final p in widget.pins) {
      final img = await _image(p.style.key, () => PinIcons.pinPng(p.style));
      final size = PinIcons.sizeFor(p.style);
      final dy = (0.5 - PinIcons.anchorFor(p.style).dy) * size.height;   // badge centre onto the point
      want[p.id] = ml.SymbolOptions(
        geometry: LibreMapCam.l(p.pos),
        iconImage: img,
        iconAnchor: 'center',
        iconOffset: Offset(0, dy),
        iconSize: 1,
        zIndex: 1,
      );
      sig[p.id] = '${p.pos.latitude},${p.pos.longitude}|$img';
    }

    final pos = widget.bus?.value;
    final look = widget.busLook?.call();
    if (pos != null && look != null) {
      final body = await _image(look.body.key, () => PinIcons.pinPng(look.body));
      // The icon turns with the screen, so a heading on the map is the heading less the map's own turn.
      final rot = look.rotate ? ((look.heading - _bearing) % 360) : 0.0;
      want['bus'] = ml.SymbolOptions(geometry: LibreMapCam.l(pos), iconImage: body, iconAnchor: 'center', iconRotate: rot, iconSize: 1, zIndex: 3);
      sig['bus'] = '${pos.latitude},${pos.longitude}|$body|${rot.toStringAsFixed(1)}';
      final pl = look.pill;
      if (pl != null) {
        final pill = await _image(pl.key, () => PinIcons.pillPng(pl));
        want['bus_pill'] = ml.SymbolOptions(geometry: LibreMapCam.l(pos), iconImage: pill, iconAnchor: 'bottom', iconSize: 1, zIndex: 4);
        sig['bus_pill'] = '${pos.latitude},${pos.longitude}|$pill';
      }
    }

    // Symbols: add, update what changed, remove what is gone.
    for (final e in want.entries) {
      final have = _symbols[e.key];
      if (have == null) {
        final s = await c.addSymbol(e.value);
        _symbols[e.key] = s;
        _tapIds[s.id] = e.key;
      } else if (_symSig[e.key] != sig[e.key]) {
        await c.updateSymbol(have, e.value);
      }
      _symSig[e.key] = sig[e.key]!;
    }
    for (final id in _symbols.keys.where((k) => !want.containsKey(k)).toList()) {
      final s = _symbols.remove(id)!;
      _symSig.remove(id);
      _tapIds.remove(s.id);
      await c.removeSymbol(s);
    }

    // Lines: redrawn only when the points or the colour change.
    final wantLines = {for (final l in widget.lines) if (l.points.length > 1) l.id: l};
    for (final l in wantLines.values) {
      final s = '${l.points.length}|${l.points.first.latitude},${l.points.first.longitude}|${l.points.last.latitude},${l.points.last.longitude}|${l.color.toARGB32()}|${l.width}';
      if (_lineSig[l.id] == s) continue;
      for (final old in _lines.remove(l.id) ?? const <ml.Line>[]) {
        await c.removeLine(old);
      }
      final pts = [for (final p in l.points) LibreMapCam.l(p)];
      final edge = await c.addLine(ml.LineOptions(geometry: pts, lineColor: '#FFFFFF', lineWidth: l.width + 4.0, lineJoin: 'round'));
      final main = await c.addLine(ml.LineOptions(geometry: pts, lineColor: _hex(l.color), lineOpacity: l.color.a, lineWidth: l.width.toDouble(), lineJoin: 'round'));
      _lines[l.id] = [edge, main];
      _lineSig[l.id] = s;
    }
    for (final id in _lines.keys.where((k) => !wantLines.containsKey(k)).toList()) {
      for (final old in _lines.remove(id)!) {
        await c.removeLine(old);
      }
      _lineSig.remove(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureWatch(
      onUserGesture: widget.onUserGesture,
      child: ml.MapLibreMap(
        styleString: widget.styleUrl,
        initialCameraPosition: ml.CameraPosition(target: LibreMapCam.l(widget.initialCenter), zoom: widget.initialZoom),
        trackCameraPosition: true,
        compassEnabled: false,           // the screens show their own compass button
        rotateGesturesEnabled: true,
        tiltGesturesEnabled: false,
        myLocationEnabled: false,
        logoEnabled: false,
        attributionButtonPosition: ml.AttributionButtonPosition.bottomLeft,
        attributionButtonMargins: math.Point(8, widget.padding.bottom + 8),
        minMaxZoomPreference: const ml.MinMaxZoomPreference(6, 19.5),
        onMapCreated: (c) {
          _c = c;
          c.onSymbolTapped.add(_onSymbolTap);
          _cam = LibreMapCam._(c, widget.padding);
        },
        onStyleLoadedCallback: () async {
          final c = _c;
          if (c == null || !mounted) return;
          // A (re)loaded style starts empty: pictures, symbols and lines are added again.
          _styleReady = true;
          _images.clear();
          _symbols.clear();
          _symSig.clear();
          _tapIds.clear();
          _lines.clear();
          _lineSig.clear();
          try {
            await c.setSymbolIconAllowOverlap(true);    // the bus, its label and the pins are never hidden
            await c.setSymbolIconIgnorePlacement(true);
          } catch (_) {}
          final cam = _cam;
          if (cam != null) widget.onReady?.call(cam);
          _sync();
        },
        onCameraMove: (pos) {
          final turned = (pos.bearing - _bearing).abs() > 0.5;
          _bearing = pos.bearing;
          widget.onRotation?.call((360 - pos.bearing) % 360);
          if (turned) _busMoved();       // keep the bus arrow pointing the right way as the map turns
        },
      ),
    );
  }
}
