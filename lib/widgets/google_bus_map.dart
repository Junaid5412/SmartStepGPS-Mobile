import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';

import 'bus_map_common.dart';
import '../services/map_config.dart' show NativeMapGuard;

/// The official Google Maps view (App Module Settings -> "Google Maps - official"; the app must be built with a
/// Google Maps API key). Pins, bus and line come from [bus_map_common.dart].

/// Camera control for the Google map.
class GoogleMapCam implements BusMapCam {
  GoogleMapCam._(this._c, this._pos) {
    _follow = FollowThrottle((p) => move(p));
  }
  final gm.GoogleMapController _c;
  gm.CameraPosition _pos;
  late final FollowThrottle _follow;

  @override
  double get zoom => _pos.zoom;

  static gm.LatLng g(LatLng p) => gm.LatLng(p.latitude, p.longitude);

  @override
  void move(LatLng p, [double? zoom]) {
    _c.moveCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(target: g(p), zoom: zoom ?? _pos.zoom, bearing: _pos.bearing)));
  }

  @override
  void animateTo(LatLng p, [double? zoom]) {
    _c.animateCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(target: g(p), zoom: zoom ?? _pos.zoom, bearing: _pos.bearing)));
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
    _c.animateCamera(gm.CameraUpdate.newLatLngBounds(
        gm.LatLngBounds(southwest: gm.LatLng(s, w), northeast: gm.LatLng(n, e)), padding));
  }

  @override
  void north() {
    _c.animateCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(target: _pos.target, zoom: _pos.zoom, bearing: 0)));
  }

  @override
  void moveNorth(LatLng p, double minZoom) {
    _c.animateCamera(gm.CameraUpdate.newCameraPosition(gm.CameraPosition(target: g(p), zoom: math.max(_pos.zoom, minZoom), bearing: 0)));
  }

  @override
  void dispose() => _follow.dispose();
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
  final EdgeInsets padding;               // keeps Google's logo and fitted views clear of the screen's cards
  final void Function(BusMapCam cam)? onReady;
  final VoidCallback? onUserGesture;
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

  @override
  void initState() {
    super.initState();
    NativeMapGuard.opening('google');
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

  /// The bus glides every frame; the map is told at most ten times a second.
  void _busMoved() {
    if (_busTimer != null) return;
    _busTimer = Timer(const Duration(milliseconds: 100), () {
      _busTimer = null;
      if (mounted) setState(() {});
    });
  }

  gm.BitmapDescriptor? _icon(String key, Future<Uint8List> Function() png) {
    final have = _icons[key];
    if (have != null) return have;
    png().then((bytes) {
      if (!mounted) return;
      setState(() => _icons[key] = gm.BitmapDescriptor.bytes(bytes, imagePixelRatio: PinIcons.dpr));
    }).catchError((Object e) {
      debugPrint('GoogleBusMap: could not paint a pin: $e');
    });
    return null;
  }

  Set<gm.Marker> _markers() {
    final out = <gm.Marker>{};
    for (final p in widget.pins) {
      final ic = _icon(p.style.key, () => PinIcons.pinPng(p.style));
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
      final body = _icon(look.body.key, () => PinIcons.pinPng(look.body));
      if (body != null) {
        out.add(gm.Marker(
          markerId: const gm.MarkerId('bus'),
          position: GoogleMapCam.g(pos),
          icon: body,
          anchor: const Offset(0.5, 0.5),
          // Moving: the arrow lies flat on the map and points the way the bus drives, however the map is turned.
          flat: look.rotate,
          rotation: look.rotate ? look.heading : 0,
          zIndex: 3,
        ));
      }
      final pl = look.pill;
      if (pl != null) {
        final pic = _icon(pl.key, () => PinIcons.pillPng(pl));
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
      out.add(gm.Polyline(polylineId: gm.PolylineId('${l.id}_edge'), points: pts, color: Colors.white, width: l.width + 4,
          jointType: gm.JointType.round, startCap: gm.Cap.roundCap, endCap: gm.Cap.roundCap, zIndex: 1));
      out.add(gm.Polyline(polylineId: gm.PolylineId(l.id), points: pts, color: l.color, width: l.width,
          jointType: gm.JointType.round, startCap: gm.Cap.roundCap, endCap: gm.Cap.roundCap, zIndex: 2));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return GestureWatch(
      onUserGesture: widget.onUserGesture,
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
          NativeMapGuard.opened();   // the native map is up
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
