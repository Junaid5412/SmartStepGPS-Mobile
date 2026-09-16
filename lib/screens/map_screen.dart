import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
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
  double _busBearing = 0.0;   // heading in degrees (0=north, 90=east)

  // Smooth marker animation
  AnimationController? _markerAnimController;
  bool _cameraFollowBus = true; // auto-pan camera to follow bus

  LatLng? _homeLocation;
  String _homeAddress = '';

  LatLng? _schoolLocation;
  String _schoolName = 'School Campus';

  LatLng? _parentLocation;

  // Road Routing
  List<LatLng> _routeStops = [];
  List<LatLng> _roadPolyline = [];
  double _roadDistanceKm = 0.0;
  int _etaMinutes = 0;
  bool _initialFitted = false;
  DateTime? _lastRouteFetchTime;
  LatLng? _lastRoutedBusPosition;

  @override
  void initState() {
    super.initState();
    _parseInitialStudentData();
    _fetchParentLocation();
    _fetchLocation();
    // Poll live location every 3 seconds
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchLocation());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _markerAnimController?.dispose();
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

        // Other route stops (not shown to parent as markers, but used for road routing)
        List<LatLng> stops = [];
        if (res['route_stops'] is List) {
          for (var stop in res['route_stops']) {
            if (stop['lat'] != null && stop['lng'] != null) {
              final lat = double.tryParse(stop['lat'].toString());
              final lng = double.tryParse(stop['lng'].toString());
              if (lat != null && lng != null) {
                stops.add(LatLng(lat, lng));
              }
            }
          }
        }

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
        }

        setState(() {
          _isActiveWindow = active;
          _currentShift = shift;
          _timings = timings;
          _schoolName = schName;
          _schoolLocation = schoolPos;
          _homeLocation = homePos;
          _homeAddress = homeAddr;
          _routeStops = stops;
          _speed = spd;
          _lastUpdated = upd;
          _isLoading = false;
        });

        // Smooth animate bus marker to new position (Uber-style glide)
        if (busPos != null) {
          _animateBusTo(busPos);
        }

        // Fetch road routing polyline if bus & destination exist (throttled to avoid OSRM rate limits)
        if (_busLocation != null && _homeLocation != null) {
          final now = DateTime.now();
          bool shouldFetchRoute = false;
          if (_roadPolyline.isEmpty || _lastRouteFetchTime == null) {
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
            _fetchRoadRoute(_busLocation!, _homeLocation!, _schoolLocation, _routeStops);
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

  /// Calculates real road-wise polyline via OSRM public routing API
  /// Includes intermediate route stops along the path without displaying them as markers to parents
  Future<void> _fetchRoadRoute(LatLng bus, LatLng home, LatLng? school, List<LatLng> stops) async {
    try {
      List<LatLng> waypoints = [bus];

      // Add intermediate stops (limit to 5 closest to keep URL fast and within limits)
      for (final s in stops.take(5)) {
        // Avoid duplicate coordinates
        if ((s.latitude - bus.latitude).abs() > 0.0002 || (s.longitude - bus.longitude).abs() > 0.0002) {
          waypoints.add(s);
        }
      }

      // Add Home Stop
      waypoints.add(home);

      // In morning shift, add School Campus as end terminus
      if (school != null && _currentShift == 'morning') {
        waypoints.add(school);
      }

      // OSRM format: lng,lat;lng,lat...
      final coordsParam = waypoints.map((p) => '${p.longitude},${p.latitude}').join(';');
      final url = Uri.parse('https://router.project-osrm.org/route/v1/driving/$coordsParam?overview=full&geometries=geojson');

      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['routes'] != null && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final coords = route['geometry']['coordinates'] as List<dynamic>;
          final points = coords.map<LatLng>((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())).toList();

          final double distMeters = (route['distance'] as num?)?.toDouble() ?? 0;
          final double durSeconds = (route['duration'] as num?)?.toDouble() ?? 0;

          if (mounted) {
            setState(() {
              _roadPolyline = points;
              _roadDistanceKm = distMeters / 1000.0;
              _etaMinutes = (durSeconds / 60.0).round();
            });
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('OSRM road routing error: $e');
    }

    // Fallback: Haversine distance if OSRM is unreachable
    if (mounted && _roadDistanceKm == 0.0) {
      const dist = Distance();
      final km = dist.as(LengthUnit.Kilometer, bus, home);
      setState(() {
        _roadDistanceKm = km;
        _etaMinutes = (km / 30.0 * 60).round().clamp(1, 120);
        if (_roadPolyline.isEmpty) {
          _roadPolyline = [bus, home];
          if (school != null) _roadPolyline.add(school);
        }
      });
    }
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

    // Calculate heading/bearing for bus icon rotation
    _busBearing = _calculateBearing(from, target);

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

      setState(() {
        _displayBusLocation = interpolated;
      });

      // Smooth camera follow (only while bus is moving at >3 km/h)
      if (_cameraFollowBus && _speed > 3 && t < 0.95) {
        // Don't fight user's manual pan — only follow during active movement
        try {
          _mapController.move(interpolated, _mapController.camera.zoom);
        } catch (_) {}
      }
    });

    // Start the glide
    _markerAnimController!.forward();
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
    final points = <LatLng>[];
    if (_busLocation != null) points.add(_busLocation!);
    if (_homeLocation != null) points.add(_homeLocation!);
    if (_schoolLocation != null) points.add(_schoolLocation!);
    if (_parentLocation != null) points.add(_parentLocation!);

    if (points.isEmpty) return;

    if (points.length == 1) {
      _mapController.move(points.first, 15.0);
    } else {
      try {
        final bounds = LatLngBounds.fromPoints(points);
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.only(top: 100, bottom: 180, left: 50, right: 50),
          ),
        );
      } catch (_) {
        _mapController.move(points.first, 15.0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final studentName = widget.student['name']?.toString() ?? 'Student';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$studentName - Bus Tracking',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _isActiveWindow ? Colors.greenAccent : Colors.orangeAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _isActiveWindow
                      ? (_currentShift == 'morning' ? 'Morning Pickup Window' : 'Afternoon Drop Window')
                      : 'Outside Shift Hours (Offline)',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E3C72),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Location',
            onPressed: () {
              _fetchLocation();
              _fetchParentLocation();
            },
          ),
        ],
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
                    // Disable follow mode when user manually pans the map (like Uber)
                    onPositionChanged: (pos, hasGesture) {
                      if (hasGesture && _cameraFollowBus) {
                        setState(() => _cameraFollowBus = false);
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.smartstepgps.app',
                    ),

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

                        // 3. Live Bus Marker (uses smoothly interpolated position)
                        if (_displayBusLocation != null)
                          Marker(
                            point: _displayBusLocation!,
                            width: 75,
                            height: 75,
                            child: _buildBusMarker(),
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
                  ],
                ),



                // 3. Floating Map Controls (Right Side)
                Positioned(
                  right: 14,
                  top: 16,
                  child: Column(
                    children: [
                      _buildFloatingAction(
                        icon: Icons.crop_free_rounded,
                        tooltip: 'Fit All Stops',
                        onTap: _fitAllMarkers,
                      ),
                      const SizedBox(height: 8),
                      // Camera follow toggle (like Uber's recenter)
                      if (_displayBusLocation != null)
                        _buildFloatingAction(
                          icon: _cameraFollowBus ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
                          tooltip: _cameraFollowBus ? 'Following Bus (Tap to unlock)' : 'Tap to follow Bus',
                          color: _cameraFollowBus ? const Color(0xFF2E7D32) : const Color(0xFF757575),
                          onTap: () {
                            setState(() => _cameraFollowBus = !_cameraFollowBus);
                            if (_cameraFollowBus && _displayBusLocation != null) {
                              _mapController.move(_displayBusLocation!, 16.5);
                            }
                          },
                        ),
                      const SizedBox(height: 8),
                      if (_displayBusLocation != null)
                        _buildFloatingAction(
                          icon: Icons.directions_bus_rounded,
                          tooltip: 'Recenter Bus',
                          color: const Color(0xFFE65100),
                          onTap: () => _mapController.move(_displayBusLocation!, 16.5),
                        ),
                      if (_homeLocation != null) ...[
                        const SizedBox(height: 8),
                        _buildFloatingAction(
                          icon: Icons.home_rounded,
                          tooltip: 'Recenter Home',
                          color: const Color(0xFF2E7D32),
                          onTap: () => _mapController.move(_homeLocation!, 16.5),
                        ),
                      ],
                      if (_schoolLocation != null) ...[
                        const SizedBox(height: 8),
                        _buildFloatingAction(
                          icon: Icons.school_rounded,
                          tooltip: 'Recenter School',
                          color: const Color(0xFF4A148C),
                          onTap: () => _mapController.move(_schoolLocation!, 16.5),
                        ),
                      ],
                      if (_parentLocation != null) ...[
                        const SizedBox(height: 8),
                        _buildFloatingAction(
                          icon: Icons.my_location_rounded,
                          tooltip: 'My Location',
                          color: const Color(0xFF0288D1),
                          onTap: () => _mapController.move(_parentLocation!, 16.5),
                        ),
                      ],
                    ],
                  ),
                ),

                // 4. Bottom Info Card (Distance, ETA, Speed & Shift info)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 16,
                  child: _buildBottomMetricsCard(),
                ),
              ],
            ),
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
                subtitle: 'to destination',
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
                value: '${_speed.toInt()} km/h',
                subtitle: _lastUpdated.isNotEmpty ? _lastUpdated.split(' ').last : 'Live',
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
                // Show a quick snackbar to assure user
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Locating live bus position...'),
                    duration: Duration(seconds: 1),
                    backgroundColor: Color(0xFF1E3C72),
                  ),
                );
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
