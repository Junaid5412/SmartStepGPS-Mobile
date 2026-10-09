import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import '../services/api_service.dart';
import '../services/offline_map.dart';
import '../widgets/custom_loading.dart';

class MapScreen extends StatefulWidget {
  final Map<String, dynamic> student;

  const MapScreen({Key? key, required this.student}) : super(key: key);

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  Timer? _timer;

  /// The bundled English map of Qatar as a layer, built ONCE when the map has opened (null for the
  /// moment that takes on first use). Handing Flutter the same widget instance on every rebuild lets it
  /// skip the layer entirely; a freshly constructed VectorTileLayer each time made the map redo work
  /// on every rebuild, which is what made panning and zooming stutter.
  Widget? _tileLayer;

  /// The bus marker's animated position. The glide runs at 60 fps; it used to call setState on every
  /// frame and so rebuilt the whole screen - map included - sixty times a second. Now only the bus
  /// marker layer listens to this.
  final ValueNotifier<LatLng?> _busPos = ValueNotifier<LatLng?>(null);

  /// Short status line shown just under the header (e.g. "Locating live bus position...").
  String? _banner;
  Timer? _bannerTimer;

  bool _isLoading = true;
  bool _isActiveWindow = true;
  String _currentShift = 'morning';
  Map<String, dynamic> _timings = {};

  // Locations
  LatLng? _busLocation;       // latest raw GPS position from API
  LatLng? _displayBusLocation; // interpolated position for rendering (smooth)
  LatLng? _previousBusLocation; // previous raw GPS position (for animation start)
  double _speed = 0.0;
  String _lastUpdated = '';
  int? _ageSec;       // how old the bus position was when fetched (server clock), null if unknown
  DateTime? _ageAt;   // when that was
  bool _full = false; // full-screen map
  double _busBearing = 0.0;   // heading in degrees (0=north, 90=east)
  LatLng? _bearingAnchor;     // where that heading was measured from

  // Smooth marker animation
  AnimationController? _markerAnimController;
  bool _cameraFollowBus = true; // auto-pan camera to follow bus

  LatLng? _homeLocation;
  String _homeAddress = '';

  LatLng? _schoolLocation;
  String _schoolName = 'School Campus';

  LatLng? _parentLocation;

  // Road Routing
  List<LatLng> _roadPolyline = [];
  double _roadDistanceKm = 0.0;
  int _etaMinutes = 0;
  bool _initialFitted = false;
  DateTime? _lastRouteFetchTime;
  LatLng? _lastRoutedBusPosition;
  String _childStage = 'waiting'; // this child on this trip: waiting | on_bus | done
  String _routedSig = '';         // which trip the line was drawn for
  String _targetLabel = 'to your stop';

  @override
  void initState() {
    super.initState();
    OfflineMap.load().then((m) {
      if (!mounted) return;
      setState(() {
        _tileLayer = VectorTileLayer(
          theme: m.theme,
          tileProviders: TileProviders({OfflineMap.sourceName: m.provider}),
          // While zooming, keep showing nearby zoom levels' tiles instead of blank squares.
          maximumTileSubstitutionDifference: 3,
          // Tiles stop at zoom 15; closer than that, they are drawn larger.
          maximumZoom: 20,
        );
      });
    }).catchError((Object e) {
      debugPrint('Offline map failed to load: $e');
    });
    _parseInitialStudentData();
    _fetchParentLocation();
    _fetchLocation();
    // Poll live location every 3 seconds
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchLocation());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bannerTimer?.cancel();
    _markerAnimController?.dispose();
    _busPos.dispose();
    super.dispose();
  }

  void _parseInitialStudentData() {
    final s = widget.student;
    if (s['pickup_lat'] != null && s['pickup_lng'] != null) {
      final lat = double.tryParse(s['pickup_lat'].toString());
      final lng = double.tryParse(s['pickup_lng'].toString());
      if (lat != null && lng != null) {
        _homeLocation = LatLng(lat, lng);
      }
    }
    _homeAddress = s['pickup_point']?.toString() ?? s['pickup_address']?.toString() ?? 'Home Stop';
  }

  Future<void> _fetchParentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        // Pre-permission notice. REJECTED by Apple on 23 Sep 2026 under guideline 5.1.1(iv) in its
        // previous form, which offered "Deny" and "Allow" buttons. Two things were wrong with it:
        //
        //   1. A button labelled "Allow" makes the notice look like the permission decision itself,
        //      so a user can believe they have already answered before iOS even asks.
        //   2. "Deny" returned early and never reached Geolocator.requestPermission(), letting the
        //      user postpone the system prompt indefinitely. Apple requires that the real prompt
        //      always follows the notice - the decision belongs to the OS dialog, not to ours.
        //
        // So this is now purely informational: one button, worded "Continue", and no path that
        // skips ahead. The user's actual choice happens in the iOS prompt immediately after, where
        // declining is always available and is respected.
        //
        // PopScope(canPop: false) with barrierDismissible: false closes the last gap - the Android
        // back button previously dismissed this dialog, which was the same "delay the request"
        // behaviour Apple objected to.
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('About your location'),
              content: const Text(
                'Smart Step GPS shows where you are in relation to the school bus and the stop, so '
                'you can see how far away the bus is.\n\n'
                'Your location is used only while this screen is open. It stays on your device and '
                'is never sent to our servers.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        );

        if (!mounted) return;

        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 5),
      );
      if (mounted) {
        setState(() {
          _parentLocation = LatLng(pos.latitude, pos.longitude);
        });
      }
    } catch (e) {
      debugPrint('Parent GPS fetch error: $e');
    }
  }

  Future<void> _fetchLocation() async {
    final deviceId = int.tryParse(widget.student['device_id']?.toString() ?? '0') ?? 0;
    final studentId = int.tryParse(widget.student['id']?.toString() ?? '0');

    if (deviceId == 0 && studentId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final res = await ApiService.getBusLocation(deviceId, studentId: studentId);
      if (res['success'] == true && mounted) {
        final bool active = res['is_active_window'] ?? true;
        final shift = res['current_shift']?.toString() ?? 'morning';
        final timings = (res['timings'] is Map) ? Map<String, dynamic>.from(res['timings']) : <String, dynamic>{};

        // School coordinates
        LatLng? schoolPos;
        String schName = 'School Campus';
        if (res['school'] != null) {
          final sch = res['school'];
          schName = sch['name']?.toString() ?? 'School Campus';
          if (sch['lat'] != null && sch['lng'] != null) {
            final lat = double.tryParse(sch['lat'].toString());
            final lng = double.tryParse(sch['lng'].toString());
            if (lat != null && lng != null) {
              schoolPos = LatLng(lat, lng);
            }
          }
        }

        // Student home coordinates
        LatLng? homePos = _homeLocation;
        String homeAddr = _homeAddress;
        if (res['student'] != null) {
          final st = res['student'];
          if (st['pickup_lat'] != null && st['pickup_lng'] != null) {
            final lat = double.tryParse(st['pickup_lat'].toString());
            final lng = double.tryParse(st['pickup_lng'].toString());
            if (lat != null && lng != null) {
              homePos = LatLng(lat, lng);
            }
          }
          if (st['pickup_address'] != null) {
            homeAddr = st['pickup_address'].toString();
          }
        }

        final stage = '${res['child_stage'] ?? 'waiting'}';
        _childStage = (stage == 'on_bus' || stage == 'done') ? stage : 'waiting';

        // Bus location (use active location, or last_known_location if outside active window)
        final locData = active ? res['location'] : (res['last_known_location'] ?? res['location']);
        LatLng? busPos;
        double spd = 0.0;
        String upd = '';
        if (locData != null) {
          final lat = double.tryParse(locData['lat'].toString());
          final lng = double.tryParse(locData['lng'].toString());
          if (lat != null && lng != null) {
            busPos = LatLng(lat, lng);
          }
          spd = double.tryParse(locData['speed']?.toString() ?? '0') ?? 0.0;
          upd = locData['updated_at']?.toString() ?? '';
          final a = locData['age_sec'];
          _ageSec = a is num ? a.toInt() : int.tryParse('${a ?? ''}');
          _ageAt = DateTime.now();
        }

        setState(() {
          _isActiveWindow = active;
          _currentShift = shift;
          _timings = timings;
          _schoolName = schName;
          _schoolLocation = schoolPos;
          _homeLocation = homePos;
          _homeAddress = homeAddr;
          _speed = spd;
          _lastUpdated = upd;
          _isLoading = false;
        });

        // Smooth animate bus marker to new position (Uber-style glide)
        if (busPos != null) {
          _animateBusTo(_onRoad(busPos));
        }

        // The road line: where the bus is going for this child, re-drawn when the trip changes
        // (picked up, dropped) or every 15 s once the bus has moved ~45 m.
        if (_busLocation != null) {
          final now = DateTime.now();
          final sig = '$_currentShift|$_childStage';
          bool shouldFetchRoute = false;
          if (sig != _routedSig || _lastRouteFetchTime == null) {
            shouldFetchRoute = true;
          } else if (now.difference(_lastRouteFetchTime!).inSeconds >= 15) {
            if (_lastRoutedBusPosition == null) {
              shouldFetchRoute = true;
            } else {
              final dLat = (_busLocation!.latitude - _lastRoutedBusPosition!.latitude).abs();
              final dLng = (_busLocation!.longitude - _lastRoutedBusPosition!.longitude).abs();
              if (dLat > 0.0004 || dLng > 0.0004) {
                shouldFetchRoute = true;
              }
            }
          }

          if (shouldFetchRoute) {
            _lastRouteFetchTime = now;
            _lastRoutedBusPosition = _busLocation;
            _routedSig = sig;
            _fetchRoadRoute(_busLocation!);
          }
        }

        // Fit camera once on first successful data load
        if (!_initialFitted) {
          _initialFitted = true;
          _fitAllMarkers();
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Error fetching bus location: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Where the bus still has to go for this child, in order, and which of those points the
  /// distance and arrival time are for.
  ///   Morning: waiting -> their stop, then school (time to their stop); on the bus -> school.
  ///   Evening: not boarded yet -> school, then home (time to home); on the bus -> home.
  ///   Done (at school / home / absent): nothing to draw.
  (List<LatLng>, int, String) _trip() {
    final home = _homeLocation, school = _schoolLocation;
    final morning = _currentShift == 'morning';
    if (_childStage == 'done') return (const [], -1, '');
    if (morning) {
      if (_childStage == 'on_bus') {
        return school == null ? (const [], -1, '') : ([school], 0, 'to school');
      }
      if (home == null) return school == null ? (const [], -1, '') : ([school], 0, 'to school');
      return ([home, if (school != null) school], 0, 'to your stop');
    }
    if (home == null) return (const [], -1, '');
    if (_childStage == 'on_bus' || school == null) return ([home], 0, 'to your stop');
    return ([school, home], 1, 'to your stop');
  }

  /// The road line from the bus along that trip (public OSRM), with the distance and time to the
  /// point that matters to this parent.
  Future<void> _fetchRoadRoute(LatLng bus) async {
    final (dest, target, label) = _trip();
    if (dest.isEmpty) {
      if (mounted) {
        setState(() {
          _roadPolyline = [];
          _roadDistanceKm = 0;
          _etaMinutes = 0;
          _targetLabel = _currentShift == 'morning' ? 'at school' : 'trip complete';
        });
      }
      return;
    }
    try {
      final waypoints = [bus, ...dest];
      final coordsParam = waypoints.map((p) => '${p.longitude},${p.latitude}').join(';');
      final url = Uri.parse('https://router.project-osrm.org/route/v1/driving/$coordsParam?overview=full&geometries=geojson');

      final response = await http.get(url, headers: {'User-Agent': 'SmartStepGPS/1.0'}).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['routes'] != null && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final coords = route['geometry']['coordinates'] as List<dynamic>;
          final points = coords.map<LatLng>((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())).toList();

          // Distance and time up to the target point only (the legs before it, plus its own).
          double distMeters = 0, durSeconds = 0;
          final legs = (route['legs'] as List?) ?? const [];
          for (var i = 0; i <= target && i < legs.length; i++) {
            distMeters += (legs[i]['distance'] as num?)?.toDouble() ?? 0;
            durSeconds += (legs[i]['duration'] as num?)?.toDouble() ?? 0;
          }
          if (legs.isEmpty) {
            distMeters = (route['distance'] as num?)?.toDouble() ?? 0;
            durSeconds = (route['duration'] as num?)?.toDouble() ?? 0;
          }

          if (mounted) {
            setState(() {
              _roadPolyline = points;
              _roadDistanceKm = distMeters / 1000.0;
              _etaMinutes = (durSeconds / 60.0).round();
              _targetLabel = label;
            });
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('OSRM road routing error: $e');
    }

    // Routing service unreachable: straight lines along the same trip, distance as the crow flies.
    if (mounted) {
      const dist = Distance();
      var km = 0.0;
      var prev = bus;
      for (var i = 0; i <= target && i < dest.length; i++) {
        km += dist.as(LengthUnit.Meter, prev, dest[i]) / 1000.0;
        prev = dest[i];
      }
      setState(() {
        _roadDistanceKm = km * 1.3;
        _etaMinutes = (km * 1.3 / 30.0 * 60).round().clamp(1, 120);
        _targetLabel = label;
        _roadPolyline = [bus, ...dest];
      });
    }
  }

  /// GPS - a tracker's or an older phone's - wanders a few metres to the side of the road. Within
  /// 25 m of the route line the bus is drawn ON the line, as Uber does; further away it has really
  /// taken another road, and is drawn where it is.
  LatLng _onRoad(LatLng p) {
    final line = _roadPolyline;
    if (line.length < 2) return p;
    const mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * math.cos(p.latitude * math.pi / 180);
    double bestD = double.infinity;
    LatLng best = p;
    final limit = math.min(line.length - 1, 400);
    for (var i = 0; i < limit; i++) {
      final a = line[i], b = line[i + 1];
      final ax = (a.longitude - p.longitude) * mPerDegLng, ay = (a.latitude - p.latitude) * mPerDegLat;
      final bx = (b.longitude - p.longitude) * mPerDegLng, by = (b.latitude - p.latitude) * mPerDegLat;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
      final x = ax + t * dx, y = ay + t * dy;
      final d = math.sqrt(x * x + y * y);
      if (d < bestD) {
        bestD = d;
        best = LatLng(a.latitude + t * (b.latitude - a.latitude), a.longitude + t * (b.longitude - a.longitude));
      }
    }
    return bestD <= 25 ? best : p;
  }

  /// How old the bus position is now, in seconds, or null when unknown.
  int? get _ageNow => _ageSec == null || _ageAt == null ? null : _ageSec! + DateTime.now().difference(_ageAt!).inSeconds;

  bool get _positionLive => (_ageNow ?? 0) <= 60;

  /// Under the speed: "Live", or how long ago the bus last reported - never a bare clock time.
  String get _freshLabel {
    final a = _ageNow;
    if (a == null) return _lastUpdated.isEmpty ? '' : 'Live';
    if (a <= 30) return 'Live';
    if (a < 90) return 'Updated 1 min ago';
    if (a < 3600) return 'Updated ${(a / 60).round()} min ago';
    final t = DateTime.now().subtract(Duration(seconds: a));
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return 'Last seen $h:${t.minute.toString().padLeft(2, '0')} ${t.hour >= 12 ? 'PM' : 'AM'}';
  }

  /// ─── Uber-Style Smooth Marker Animation ───────────────────────────────
  /// Smoothly glides bus marker from current position to [target] over 2.5s
  /// using 60fps interpolation with ease-out physics.
  void _animateBusTo(LatLng target) {
    // First position: no animation needed, just place the marker
    if (_busLocation == null && _displayBusLocation == null) {
      setState(() {
        _busLocation = target;
        _displayBusLocation = target;
      });
      _busPos.value = target;
      return;
    }

    // Determine animation start point
    final from = _displayBusLocation ?? _busLocation ?? target;

    // Skip animation if position hasn't meaningfully changed (<2m)
    final dLat = (target.latitude - from.latitude).abs();
    final dLng = (target.longitude - from.longitude).abs();
    if (dLat < 0.00002 && dLng < 0.00002) {
      // Position basically unchanged — just update raw, no animation
      _busLocation = target;
      return;
    }

    // Direction of travel - only over a real move. GPS wanders a few metres even when the bus is
    // standing still (and the backup position from the monitor's phone differs slightly from the
    // tracker), which used to spin the arrow the wrong way.
    final anchor = _bearingAnchor;
    if (anchor == null) {
      _bearingAnchor = target;
    } else if (const Distance().as(LengthUnit.Meter, anchor, target) > 15) {
      _busBearing = _calculateBearing(anchor, target);
      _bearingAnchor = target;
    }

    // Save previous → new positions
    _previousBusLocation = from;
    _busLocation = target;

    // Stop any running animation
    _markerAnimController?.stop();
    _markerAnimController?.dispose();

    // Create new animation: 2.5s ease-out glide (matches poll interval)
    _markerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    // Curved animation for natural deceleration (like Uber)
    final curved = CurvedAnimation(
      parent: _markerAnimController!,
      curve: Curves.easeOutCubic,
    );

    // On each frame: interpolate position and optionally pan camera
    curved.addListener(() {
      if (!mounted) return;
      final t = curved.value;
      final interpolated = _lerpLatLng(_previousBusLocation!, _busLocation!, t);

      _displayBusLocation = interpolated;
      _busPos.value = interpolated; // repaints only the bus marker layer

      // Smooth camera follow (only while bus is moving at >3 km/h)
      if (_cameraFollowBus && _speed > 3 && t < 0.95) {
        // Don't fight user's manual pan — only follow during active movement
        try {
          _mapController.move(interpolated, _mapController.camera.zoom);
        } catch (e) { debugPrint('Map follow-camera move skipped: $e'); }
      }
    });

    // Start the glide
    _markerAnimController!.forward();
  }

  void _showBanner(String text) {
    _bannerTimer?.cancel();
    setState(() => _banner = text);
    _bannerTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _banner = null);
    });
  }

  /// Linear interpolation between two LatLng points
  LatLng _lerpLatLng(LatLng a, LatLng b, double t) {
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  /// Calculate bearing (heading) in degrees from point [a] to point [b]
  /// Uses spherical law of cosines: accurate for short GPS distances
  double _calculateBearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;

    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);

    final bearing = math.atan2(y, x) * 180 / math.pi;
    return (bearing + 360) % 360; // Normalize to 0-360
  }

  void _fitAllMarkers() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitNow();
    });
  }

  void _fitNow() {
    final points = <LatLng>[];
    if (_busLocation != null) points.add(_busLocation!);
    if (_homeLocation != null) points.add(_homeLocation!);
    if (_schoolLocation != null) points.add(_schoolLocation!);
    if (_parentLocation != null) points.add(_parentLocation!);

    if (points.isEmpty) return;

    if (points.length == 1) {
      try { _mapController.move(points.first, 15.0); } catch (_) {}
    } else {
      try {
        final bounds = LatLngBounds.fromPoints(points);
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.only(top: 100, bottom: 180, left: 50, right: 50),
            maxZoom: 17,
          ),
        );
      } catch (_) {
        try { _mapController.move(points.first, 15.0); } catch (_) {}
      }
    }
  }

  /// "BUS 1 · 245871": the bus's name and plate, whichever of them are set.
  String get _busTitle {
    final parts = [widget.student['bus_label'], widget.student['bus_name']]
        .map((v) => (v ?? '').toString().trim())
        .where((v) => v.isNotEmpty && v.toLowerCase() != 'auto detected')
        .toSet()
        .toList();
    return parts.isEmpty ? 'Bus Tracking' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final topInset = _full ? MediaQuery.of(context).padding.top : 0.0;
    return PopScope(
      canPop: !_full,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _full) _setFull(false);
      },
      child: Scaffold(
      appBar: _full ? null : AppBar(
        // The bus - its number and plate - and nothing else. Not the child's name: siblings share a
        // bus, so the screen is about the bus.
        title: Text(
          _busTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF1E3C72),
        elevation: 0,
      ),
      body: _isLoading
          ? const CustomLoading(message: 'Connecting to live bus GPS...')
          : (!_isActiveWindow)
              ? _buildOutOfShiftScreen()
              : Stack(
              children: [
                // 1. Flutter Map
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _displayBusLocation ?? _busLocation ?? _homeLocation ?? _schoolLocation ?? const LatLng(25.2854, 51.5310),
                    initialZoom: 15.0,
                    // Street detail goes to zoom 15 and is drawn larger up to 18; closer than that
                    // the map would go blank.
                    minZoom: 8,
                    maxZoom: 18,
                    // North always up: no two-finger rotating, which left the map turned.
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                    // Disable follow mode when user manually pans the map (like Uber)
                    onPositionChanged: (pos, hasGesture) {
                      if (hasGesture && _cameraFollowBus) {
                        setState(() => _cameraFollowBus = false);
                      }
                    },
                  ),
                  children: [
                    // Bundled English map of Qatar (works offline). It replaces
                    // tile.openstreetmap.org, whose usage policy does not allow apps with this
                    // many users. Until it has opened - a moment, on first use - the map shows a
                    // plain background under the markers rather than nothing at all.
                    _tileLayer ?? const ColoredBox(color: Color(0xFFF2F0EB), child: SizedBox.expand()),

                    // Road-wise Polyline (following real road geometry via OSRM)
                    if (_roadPolyline.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _roadPolyline,
                            strokeWidth: 5.0,
                            color: const Color(0xFF2A5298),
                            borderColor: const Color(0xFF1E3C72),
                            borderStrokeWidth: 1.5,
                          ),
                        ],
                      ),

                    // 4 Distinct Markers: School, Home, Bus, Parent
                    MarkerLayer(
                      markers: [
                        // 1. School Marker
                        if (_schoolLocation != null)
                          Marker(
                            point: _schoolLocation!,
                            width: 70,
                            height: 70,
                            child: _buildMarkerItem(
                              icon: Icons.school_rounded,
                              iconColor: Colors.white,
                              bgColor: const Color(0xFF4A148C),
                              label: _schoolName.length > 12 ? '${_schoolName.substring(0, 10)}..' : _schoolName,
                            ),
                          ),

                        // 2. Student Home Marker
                        if (_homeLocation != null)
                          Marker(
                            point: _homeLocation!,
                            width: 70,
                            height: 70,
                            child: _buildMarkerItem(
                              icon: Icons.home_rounded,
                              iconColor: Colors.white,
                              bgColor: const Color(0xFF2E7D32),
                              label: 'Home Stop',
                            ),
                          ),

                        // 4. Parent's Own Location Marker
                        if (_parentLocation != null)
                          Marker(
                            point: _parentLocation!,
                            width: 55,
                            height: 55,
                            child: _buildMarkerItem(
                              icon: Icons.person_pin_circle_rounded,
                              iconColor: Colors.white,
                              bgColor: const Color(0xFF0288D1),
                              label: 'You',
                            ),
                          ),
                      ],
                    ),

                    // Live bus, in its own layer on top: the 60 fps glide rebuilds only this.
                    ValueListenableBuilder<LatLng?>(
                      valueListenable: _busPos,
                      builder: (context, pos, _) => pos == null
                          ? const SizedBox.shrink()
                          : MarkerLayer(markers: [
                              Marker(point: pos, width: 75, height: 75, child: _buildBusMarker()),
                            ]),
                    ),

                    // Required by the OpenStreetMap licence (ODbL): visible, but small and quiet.
                    // Top-left, because the map controls sit top-right and the info card covers
                    // the bottom of the map.
                    Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(6, 6 + topInset, 6, 6),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            child: Text(
                              '© ${OfflineMap.attribution}',
                              style: TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),



                // 3. One floating control. "Locate Now" in the card below already finds, centres on
                //    and follows the bus; this brings the bus, home stop and school into view together.
                //    The separate recentre-bus / follow / home / school / my-location buttons repeated
                //    those two and crowded the map.
                Positioned(
                  right: 14,
                  top: 16 + topInset,
                  child: Column(
                    children: [
                      _buildFloatingAction(
                        icon: _full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                        tooltip: _full ? 'Exit full screen' : 'Full screen',
                        onTap: () => _setFull(!_full),
                      ),
                      const SizedBox(height: 10),
                      _buildFloatingAction(
                        icon: Icons.crop_free_rounded,
                        tooltip: 'Show bus, home and school',
                        onTap: _fitAllMarkers,
                      ),
                    ],
                  ),
                ),

                // Status banner, just under the header.
                Positioned(
                  top: 12 + topInset,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _banner == null ? 0 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E3C72),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 12, height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              ),
                              const SizedBox(width: 8),
                              Text(_banner ?? '', style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // 4. Bottom Info Card (Distance, ETA, Speed & Shift info)
                if (!_full)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: _buildBottomMetricsCard(),
                  )
                else
                  // Full screen: the essentials in one small pill.
                  Positioned(
                    left: 12,
                    bottom: 16,
                    child: _fullPill(),
                  ),
              ],
            ),
      ),
    );
  }

  /// Full screen hides the header, so the status bar sits on the light map: dark icons there.
  void _setFull(bool on) {
    setState(() => _full = on);
    SystemChrome.setSystemUIOverlayStyle(on ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light);
  }

  Widget _fullPill() {
    final parts = [
      if (_etaMinutes > 0) '~$_etaMinutes min $_targetLabel',
      _positionLive ? '${_speed.toInt()} km/h' : _freshLabel,
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF1E3C72),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.directions_bus_rounded, color: Colors.white, size: 16),
        const SizedBox(width: 6),
        Text(parts.join('  ·  '), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  /// Marker builder for School, Home, and Parent
  Widget _buildMarkerItem({
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: bgColor),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: bgColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2))],
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
      ],
    );
  }

  /// Bus Marker with Speed pill, heading rotation & pulsating styling
  Widget _buildBusMarker() {
    // Only rotate when actually moving (speed > 3 km/h)
    final bool isMoving = _speed > 3;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Speed pill (always upright, never rotated)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _isActiveWindow ? const Color(0xFF1E3C72) : Colors.grey.shade700,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isActiveWindow) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: isMoving ? Colors.greenAccent : Colors.orangeAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  isMoving ? '${_speed.toInt()} km/h' : 'STOPPED',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ] else
                const Text(
                  'OFFLINE',
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        // Bus icon circle — rotates to face direction of travel
        Transform.rotate(
          angle: isMoving ? _busBearing * math.pi / 180 : 0,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: _isActiveWindow
                  ? (isMoving ? const Color(0xFFFF8F00) : const Color(0xFF78909C))
                  : Colors.blueGrey,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 5, offset: Offset(0, 3))],
            ),
            child: Icon(
              isMoving ? Icons.navigation_rounded : Icons.directions_bus_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOutOfShiftScreen() {
    final mStart = _timings['morning_start'] ?? '05:30';
    final mEnd = _timings['morning_end'] ?? '07:30';
    final aStart = _timings['afternoon_start'] ?? '13:00';
    final aEnd = _timings['afternoon_end'] ?? '16:00';

    return Container(
      width: double.infinity,
      color: const Color(0xFFF8FAFC),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(28),
            decoration: const BoxDecoration(
              color: Color(0xFFEFF6FF),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.bus_alert_rounded, size: 80, color: Color(0xFF3B82F6)),
          ),
          const SizedBox(height: 32),
          const Text(
            'Bus Tracking Offline',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
          ),
          const SizedBox(height: 16),
          const Text(
            'Live GPS tracking is currently unavailable.\nFor security and privacy, tracking is only accessible during active school bus shift hours.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: Color(0xFF64748B), height: 1.5),
          ),
          const SizedBox(height: 48),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 20, offset: const Offset(0, 10))],
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.wb_sunny_rounded, color: Color(0xFFF59E0B)),
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Morning Shift', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF334155), fontSize: 15)),
                        const SizedBox(height: 2),
                        Text('$mStart - $mEnd', style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(color: Color(0xFFF1F5F9), thickness: 1.5),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.nights_stay_rounded, color: Color(0xFF6366F1)),
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Afternoon Shift', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF334155), fontSize: 15)),
                        const SizedBox(height: 2),
                        Text('$aStart - $aEnd', style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 48),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              label: const Text('Return to Dashboard', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 4,
                shadowColor: const Color(0xFF3B82F6).withOpacity(0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom Information Card
  Widget _buildBottomMetricsCard() {
    final shiftLabel = _currentShift == 'morning' ? 'Morning Trip (Home ➔ School)' : 'Afternoon Trip (School ➔ Home)';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: Shift & Status Badge
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _isActiveWindow ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isActiveWindow ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 14,
                      color: _isActiveWindow ? Colors.green.shade700 : Colors.orange.shade800,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _isActiveWindow ? 'BUS ON ROAD' : 'OUTSIDE SHIFT',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _isActiveWindow ? Colors.green.shade800 : Colors.orange.shade900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  shiftLabel,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1E3C72)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Divider(height: 18),

          // Metrics: Distance, ETA, Speed
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMetricColumn(
                icon: Icons.alt_route_rounded,
                iconColor: const Color(0xFF1E3C72),
                title: 'Road Distance',
                value: _roadDistanceKm > 0 ? '${_roadDistanceKm.toStringAsFixed(1)} km' : '--',
                subtitle: _targetLabel,
              ),
              Container(width: 1, height: 38, color: Colors.grey.shade300),
              _buildMetricColumn(
                icon: Icons.timer_outlined,
                iconColor: const Color(0xFFE65100),
                title: 'Est. Arrival',
                value: _etaMinutes > 0 ? '~$_etaMinutes min' : '--',
                subtitle: 'via road routing',
              ),
              Container(width: 1, height: 38, color: Colors.grey.shade300),
              _buildMetricColumn(
                icon: Icons.speed_rounded,
                iconColor: const Color(0xFF2E7D32),
                title: 'Bus Speed',
                value: _positionLive ? '${_speed.toInt()} km/h' : '--',
                subtitle: _freshLabel,
              ),
            ],
          ),

          if (_homeAddress.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.pin_drop_rounded, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Stop: $_homeAddress',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          // Locate Now Button
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: () {
                // Shown under the header: a bottom SnackBar sat on top of this very card.
                _showBanner('Locating live bus position...');
                _fetchLocation();
                setState(() => _cameraFollowBus = true);
                if (_displayBusLocation != null) {
                  _mapController.move(_displayBusLocation!, 16.5);
                } else if (_busLocation != null) {
                  _mapController.move(_busLocation!, 16.5);
                } else if (_homeLocation != null) {
                  _mapController.move(_homeLocation!, 16.5);
                }
              },
              icon: const Icon(Icons.my_location_rounded, color: Colors.white, size: 20),
              label: const Text(
                'Locate Now',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE65100), // Prominent Orange
                elevation: 3,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricColumn({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    required String subtitle,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: iconColor),
            const SizedBox(width: 4),
            Text(title, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
        Text(subtitle, style: const TextStyle(fontSize: 10, color: Colors.black45)),
      ],
    );
  }

  Widget _buildFloatingAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color color = const Color(0xFF1E3C72),
  }) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: Colors.black38,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }
}
