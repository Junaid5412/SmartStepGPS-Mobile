import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import '../services/map_config.dart';
import '../widgets/bus_map_common.dart';
import '../widgets/google_bus_map.dart';
import '../widgets/libre_bus_map.dart';
import '../widgets/custom_loading.dart';
import '../widgets/module_gate.dart';
import '../services/app_errors.dart';

class MapScreen extends StatefulWidget {
  final Map<String, dynamic> student;

  const MapScreen({Key? key, required this.student}) : super(key: key);

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  final MapController _mapController = MapController();
  Timer? _timer;
  int _pollSec = 3;        // how soon to ask again - the server sets it: fast while moving, slow when parked
  DateTime? _lastFull;     // the last full refresh (route, crew, trip events); the polls between are light
  bool _fetching = false;  // one request at a time
  bool _paused = false;    // app in the background: no polling
  DateTime? _lastFixAt;    // when the previous NEW position arrived
  double? _gapEmaMs;       // typical time between new positions (smoothed) - the glide lasts about that long
  double? _course;         // the tracker's own heading, degrees

  /// The base map. One const widget (it follows the portal's map choice by itself), so rebuilding the screen
  /// never rebuilds the map tiles.
  static const Widget _baseMap = BaseMapLayer();

  /// The camera of the native map (official Google map or OpenFreeMap), while one of them is on screen
  /// (App Module Settings -> Map in the apps).
  BusMapCam? _gcam;
  bool get _googleOn => MapConfig.instance.value.isNative;
  String _mapKind = '';   // google | libre | tiles - a different kind of map means a fresh camera

  // Camera moves, whichever map is on screen.
  void _camMove(LatLng p, double zoom) {
    try {
      if (_googleOn) {
        _gcam?.animateTo(p, zoom);
      } else {
        _mapController.move(p, zoom);
      }
    } catch (_) {}
  }

  void _camFollow(LatLng p) {
    try {
      if (_googleOn) {
        _gcam?.follow(p);
      } else {
        _mapController.move(p, _mapController.camera.zoom);
      }
    } catch (e) {
      debugPrint('Map follow-camera move skipped: $e');
    }
  }

  void _camFit(List<LatLng> points) {
    if (_googleOn) {
      _gcam?.fit(points, padding: 56, maxZoom: 17);
      return;
    }
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.only(top: 90, bottom: 300, left: 50, right: 70),
        maxZoom: 17,
      ),
    );
  }

  void _camNorth() {
    try {
      if (_googleOn) {
        _gcam?.north();
      } else {
        _mapController.rotate(0);
      }
    } catch (_) {}
  }

  /// The bus marker's animated position. The glide runs at 60 fps; it used to call setState on every
  /// frame and so rebuilt the whole screen - map included - sixty times a second. Now only the bus
  /// marker layer listens to this.
  final ValueNotifier<LatLng?> _busPos = ValueNotifier<LatLng?>(null);
  final ValueNotifier<double> _rotation = ValueNotifier<double>(0); // the map's turn, in degrees (0 = north up)

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
  String _busState = ''; // from the server: moving | idle | parked | nosignal | offline ('' = old server)
  /// Why the server shows no speed: gps_weak (the GPS dropped out - the last good position is shown), stale,
  /// parked, idle, nosignal, offline; '' when the speed is live. And where the bus is: road | parking | gps | held.
  String _speedNote = '';
  String _place = '';
  int? _ageSec;       // how old the bus position was when fetched (server clock), null if unknown
  DateTime? _ageAt;   // when that was
  bool _full = false; // full-screen map
  String? _moduleOff; // the school switched Bus Tracking off: its message
  bool? _cardOpenChoice; // trip card details: the parent's choice; until then open on taller screens
  bool get _cardOpen => _cardOpenChoice ?? false; // small by default; a tap opens the details above
  String? _pickedAt, _droppedAt, _otherEvent; // this trip's times (HH:mm) and absent / leave / by_parent
  Map<String, dynamic>? _crew; // the bus monitor: name and phone (parents are not shown the driver)
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
  String _locSource = ''; // tracker | monitor - a switch re-draws the line at once
  int? _stopsBefore; // full-route view: stops the bus makes before this parent's (school setting)
  bool _routeHidden = false; // "Bus and home only" (school setting): no line, no arrival time, no distance
  bool _showSpeed = true; // school setting: the speed and the Stopped / Parked tag on the bus
  bool _showLive = true; // school setting: the Live badge and the last-updated time
  /// Every part of this screen the school can switch off (App Module Settings -> Parent map -> What parents see).
  /// A part not listed - an older portal - is shown.
  final Map<String, bool> _pv = {};
  bool _on(String k) => _pv[k] ?? true;
  /// The speed / Stopped tag on the bus: its own switch; before it existed, the speed switch.
  bool get _showBusTag => _pv['bus_tag'] ?? _showSpeed;

  @override
  void initState() {
    super.initState();
    AppErrors.screen = 'parent_map';
    // Which map to draw (App Module Settings on the portal): the saved choice at once, then the current one.
    MapConfig.instance.addListener(_onMapSource);
    MapConfig.instance.refresh().whenComplete(_kickMap);
    _parseInitialStudentData();
    _fetchParentLocation();
    WidgetsBinding.instance.addObserver(this);
    _fetchLocation(full: true).whenComplete(_schedule);
  }

  /// The portal switched the map: the zoom limit and the credit line follow it.
  void _onMapSource() {
    if (!mounted) return;
    final s = MapConfig.instance.value;
    final kind = s.isGoogleSdk ? 'google' : s.isLibre ? 'libre' : 'tiles';
    final changedKind = _mapKind.isNotEmpty && kind != _mapKind;
    _mapKind = kind;
    setState(() {});
    // Only a different KIND of map starts from scratch (and is shown the bus, stop and school again); a new look
    // of the same kind keeps its camera - re-fitting on every change made the map jump.
    if (changedKind) {
      _gcam = null;
      _rotation.value = 0;
      if (_initialFitted) Future.delayed(const Duration(milliseconds: 600), () { if (mounted) _fitNow(); });
    }
  }

  /// Ask again after the interval the server asked for (3 s while the bus moves, longer when it is parked or
  /// silent). One request at a time, and none while the app is in the background.
  void _schedule() {
    _timer?.cancel();
    if (!mounted || _paused || _moduleOff != null) return;
    _timer = Timer(Duration(seconds: _pollSec), () async {
      await _fetchLocation();
      _schedule();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_paused) return;
      _paused = false;
      _fetchLocation(full: true).whenComplete(_schedule); // back on screen: catch up at once
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _paused = true;
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    MapConfig.instance.removeListener(_onMapSource);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _bannerTimer?.cancel();
    _markerAnimController?.dispose();
    _busPos.dispose();
    _rotation.dispose();
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

  /// [full]: everything (route, crew, trip events). Otherwise - when a full answer is under 15 s old - only the
  /// bus's position and state, which is all that changes from one poll to the next.
  Future<void> _fetchLocation({bool full = false}) async {
    if (_fetching) return;
    final deviceId = int.tryParse(widget.student['device_id']?.toString() ?? '0') ?? 0;
    final studentId = int.tryParse(widget.student['id']?.toString() ?? '0');

    if (deviceId == 0 && studentId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    _fetching = true;
    try {
      final lite = !full && !_isLoading && _lastFull != null && DateTime.now().difference(_lastFull!).inSeconds < 15;
      final res = await ApiService.getBusLocation(deviceId, studentId: studentId, lite: lite);
      if (res['success'] == true && mounted) {
        if (res['lite'] == true) {
          _applyLive(res);
          return;
        }
        _lastFull = DateTime.now();
        final pw = res['poll_sec'];
        if (pw is num) _pollSec = pw.toInt().clamp(2, 90).toInt();
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
        final ev = res['child_events'];
        if (ev is Map) {
          String? v(dynamic x) => x == null || '$x'.isEmpty ? null : '$x';
          _pickedAt = v(ev['pickup']);
          _droppedAt = v(ev['dropoff']);
          _otherEvent = v(ev['other']);
        }
        if (res['crew'] is Map) _crew = Map<String, dynamic>.from(res['crew'] as Map);
        _childStage = (stage == 'on_bus' || stage == 'done') ? stage : 'waiting';

        // Bus location (use active location, or last_known_location if outside active window)
        final locData = active ? res['location'] : (res['last_known_location'] ?? res['location']);
        if (locData is Map) {
          _locSource = '${locData['source'] ?? ''}';
          _speedNote = '${locData['speed_note'] ?? ''}';
          _place = '${locData['place'] ?? ''}';
        }
        final bs = res['bus_status'];
        _busState = bs is Map ? '${bs['state'] ?? ''}' : '';
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
          _course = double.tryParse('${locData['course'] ?? ''}');
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
          _animateBusTo(_onRoad(busPos), path: _pathOf(locData is Map ? locData['path'] : null));
          if (_course != null && spd > 3) _busBearing = _course!;
        }

        // The school shows parents the bus's full route (App Module Settings -> Parent map): the
        // server sends the line through every stop still to make - no other family's details - and
        // this parent's own arrival time, counting the stops before theirs. Drawn as it comes.
        final rt = res['route'];
        if (rt is Map && rt['line'] is List && (rt['line'] as List).length > 1) {
          final line = [
            for (final p in rt['line'] as List)
              if (p is List && p.length >= 2) LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          ];
          final eta = (rt['eta_sec'] as num?)?.toInt() ?? 0;
          final sb = rt['stops_before'];
          setState(() {
            _roadPolyline = line;
            _etaMinutes = eta <= 0 ? 0 : (eta / 60).ceil();
            _roadDistanceKm = ((rt['distance_m'] as num?)?.toDouble() ?? 0) / 1000.0;
            _targetLabel = rt['target'] == 'school' ? 'to school' : 'to your stop';
            _stopsBefore = sb is num ? sb.toInt() : null;
          });
          _routedSig = 'server'; // switching back to the direct view re-draws at once
        } else {
          _stopsBefore = null;
        }
        // What the school shows parents besides the map (App Module Settings -> Parent map). Shown unless switched off.
        final pv = res['parent_view'];
        final next = <String, bool>{
          if (pv is Map)
            for (final e in pv.entries)
              if (e.value is bool) '${e.key}': e.value as bool,
        };
        final showSpeed = next['speed_tile'] ?? next['speed'] ?? true;
        final showLive = next['live'] ?? true;
        if (showSpeed != _showSpeed || showLive != _showLive || next.toString() != _pv.toString()) {
          setState(() {
            _showSpeed = showSpeed;
            _showLive = showLive;
            _pv
              ..clear()
              ..addAll(next);
          });
        }

        // "Bus and home only": the server sends an empty route. Clear whatever an earlier view drew.
        final hidden = rt is Map && rt['hidden'] == true;
        if (hidden != _routeHidden || (hidden && _roadPolyline.isNotEmpty)) {
          setState(() {
            _routeHidden = hidden;
            if (hidden) {
              _roadPolyline = [];
              _etaMinutes = 0;
              _roadDistanceKm = 0;
            }
          });
        }

        // The road line: where the bus is going for this child. Re-drawn at once when the trip
        // changes (picked up, dropped) or the position switches between tracker and monitor phone;
        // within 3 s when the bus is off the line (another road, or a setting changed on the
        // portal); and every 15 s once the bus has moved ~45 m.
        if (_busLocation != null && rt is! Map) {
          final now = DateTime.now();
          final sig = '$_currentShift|$_childStage|$_locSource';
          final sinceLast = _lastRouteFetchTime == null ? 1 << 30 : now.difference(_lastRouteFetchTime!).inSeconds;
          bool shouldFetchRoute = false;
          if (sig != _routedSig || _lastRouteFetchTime == null) {
            shouldFetchRoute = true;
          } else if (sinceLast >= 3 && _roadPolyline.length > 1 && _nearestOnLine(_busLocation!).$3 > 60) {
            shouldFetchRoute = true;
          } else if (sinceLast >= 15) {
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
        if (mounted) {
          setState(() {
            _isLoading = false;
            // Switched off on the portal while this map was open: say so, and stop asking.
            if (res['module_off'] == true) {
              _moduleOff = '${res['error'] ?? 'Bus tracking is not available.'}';
              _timer?.cancel();
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching bus location: $e');
      if (mounted) setState(() => _isLoading = false);
    } finally {
      _fetching = false;
    }
  }

  /// The light answer: where the bus is and what it is doing. Applied without touching anything else on the
  /// screen. If something bigger changed (shift, trip window, position source) the next poll is a full one.
  void _applyLive(Map<String, dynamic> res) {
    final active = res['is_active_window'] ?? true;
    final shift = res['current_shift']?.toString() ?? _currentShift;
    final pw = res['poll_sec'];
    if (pw is num) _pollSec = pw.toInt().clamp(2, 90).toInt();
    final bs = res['bus_status'];
    _busState = bs is Map ? '${bs['state'] ?? ''}' : '';
    final locData = res['location'];
    if (locData is! Map) return;
    final src = '${locData['source'] ?? ''}';
    if (active != _isActiveWindow || shift != _currentShift || src != _locSource) _lastFull = null;
    if (!active) return;
    final lat = double.tryParse('${locData['lat']}');
    final lng = double.tryParse('${locData['lng']}');
    final spd = double.tryParse('${locData['speed'] ?? 0}') ?? 0.0;
    _course = double.tryParse('${locData['course'] ?? ''}');
    final a = locData['age_sec'];
    _ageSec = a is num ? a.toInt() : int.tryParse('${a ?? ''}');
    _ageAt = DateTime.now();
    _locSource = src;
    _speedNote = '${locData['speed_note'] ?? ''}';
    _place = '${locData['place'] ?? ''}';
    setState(() {
      _speed = spd;
      _lastUpdated = locData['updated_at']?.toString() ?? '';
    });
    if (lat != null && lng != null) {
      _animateBusTo(_onRoad(LatLng(lat, lng)), path: _pathOf(locData['path']));
      if (_course != null && spd > 3) _busBearing = _course!;
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
    final (snap, _, d) = _nearestOnLine(p);
    return d <= 25 ? snap : p;
  }

  /// The nearest point of the route line to [p]: (that point, the segment it is on, metres away).
  (LatLng, int, double) _nearestOnLine(LatLng p) {
    final line = _roadPolyline;
    if (line.length < 2) return (p, 0, double.infinity);
    const mPerDegLat = 111320.0;
    final mPerDegLng = 111320.0 * math.cos(p.latitude * math.pi / 180);
    double bestD = double.infinity;
    LatLng best = p;
    var bestI = 0;
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
        bestI = i;
        best = LatLng(a.latitude + t * (b.latitude - a.latitude), a.longitude + t * (b.longitude - a.longitude));
      }
    }
    return (best, bestI, bestD);
  }

  /// The line from the bus onwards - the part already driven is not drawn behind it.
  List<LatLng> get _lineAhead {
    final line = _roadPolyline;
    final bus = _busLocation;
    if (bus == null || line.length < 2) return line;
    final (snap, i, d) = _nearestOnLine(bus);
    if (d > 60) return line;
    return [snap, ...line.sublist(i + 1)];
  }

  /// How old the bus position is now, in seconds, or null when unknown.
  int? get _ageNow => _ageSec == null || _ageAt == null ? null : _ageSec! + DateTime.now().difference(_ageAt!).inSeconds;

  /// The bus is standing still with its engine off - a parked tracker only reports every few minutes, so
  /// a quiet bus is not a lost one.
  bool get _busParked => _busState == 'parked';

  /// The label above a bus that is not driving: why it shows no speed.
  String get _standLabel {
    if (_speedNote == 'gps_weak') return 'GPS WEAK';
    if (_speedNote == 'nosignal' || _busState == 'nosignal') return 'NO GPS';
    if (_busParked || _place == 'parking') return 'PARKED';
    if (_speedNote == 'stale' || _busState == 'offline') return 'NO SIGNAL';
    return 'STOPPED';
  }

  /// The bus has really stopped reporting (tracker off / no data). Trusts the server's verdict; only an
  /// older server that does not send one falls back to the age of the last position.
  bool get _busSilent {
    if (_busState.isNotEmpty) return _busState == 'offline' || _busState == 'nosignal';
    final a = _ageNow;
    return a != null && a > 180;
  }

  bool get _positionLive => (_ageNow ?? 0) <= 60;

  /// Under the speed: "Live", or how long ago the bus last reported - never a bare clock time.
  String get _freshLabel {
    if (_busParked) return 'Parked';
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
  /// The road from the last position to this one, as the server matched it ([[lat, lng], ...]); empty when none.
  static List<LatLng> _pathOf(dynamic p) => [
        if (p is List)
          for (final q in p)
            if (q is List && q.length >= 2 && q[0] is num && q[1] is num) LatLng((q[0] as num).toDouble(), (q[1] as num).toDouble()),
      ];

  /// [path]: the road from the last position to [target] (server road matching). When it fits - it ends at the target
  /// and starts near where the bus is drawn - the bus glides ALONG it, round the bends, instead of in a straight line
  /// across the buildings between two positions.
  void _animateBusTo(LatLng target, {List<LatLng> path = const []}) {
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

    // The glide lasts about as long as the TYPICAL gap between new positions (smoothed, not just the last one),
    // a touch longer, so the next position normally arrives before the bus has finished the last stretch: it
    // keeps rolling at a steady pace instead of running to the point and waiting there. When the next one does
    // arrive the bus carries on from where it is now, so there is no jump.
    final nowT = DateTime.now();
    if (_lastFixAt != null) {
      final g = nowT.difference(_lastFixAt!).inMilliseconds.toDouble();
      if (g <= 20000) _gapEmaMs = _gapEmaMs == null ? g : _gapEmaMs! * 0.6 + g * 0.4;
    }
    _lastFixAt = nowT;
    final glideMs = ((_gapEmaMs ?? 3000.0) * 1.1).clamp(1500.0, 15000.0).toInt();
    // Save previous → new positions
    _previousBusLocation = from;
    _busLocation = target;
    const dist = Distance();
    final road = path.length >= 2 && dist.as(LengthUnit.Meter, path.last, target) <= 20 && dist.as(LengthUnit.Meter, from, path.first) <= 60
        ? [from, ...path.sublist(0, path.length - 1), target]
        : null;
    final cum = <double>[0];
    if (road != null) {
      for (var i = 1; i < road.length; i++) {
        cum.add(cum.last + dist.as(LengthUnit.Meter, road[i - 1], road[i]));
      }
    }

    // Stop any running animation
    _markerAnimController?.stop();
    _markerAnimController?.dispose();

    _markerAnimController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: glideMs),
    );

    // Constant speed along the glide, like a delivery-app courier (an ease-out made it surge and pause).
    final curved = CurvedAnimation(
      parent: _markerAnimController!,
      curve: Curves.linear,
    );

    // On each frame: interpolate position and optionally pan camera
    curved.addListener(() {
      if (!mounted) return;
      final t = curved.value;
      final LatLng interpolated;
      if (road != null && cum.last > 0) {
        // Along the road: the point t of the way along it, by distance.
        final want = cum.last * t;
        var i = 1;
        while (i < cum.length - 1 && cum[i] < want) {
          i++;
        }
        final seg = cum[i] - cum[i - 1];
        interpolated = _lerpLatLng(road[i - 1], road[i], seg <= 0 ? 1 : ((want - cum[i - 1]) / seg).clamp(0.0, 1.0));
      } else {
        interpolated = _lerpLatLng(_previousBusLocation!, _busLocation!, t);
      }

      _displayBusLocation = interpolated;
      _busPos.value = interpolated; // repaints only the bus marker layer

      // Smooth camera follow (only while bus is moving at >3 km/h)
      if (_cameraFollowBus && _speed > 3) {
        // Don't fight user's manual pan — only follow during active movement
        _camFollow(interpolated);
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
      if (mounted) {
        _fitNow();
        _kickMap();
      }
    });
  }

  /// The bundled vector layer asks for its tiles when the camera changes, and the first fit - or the layer
  /// swapping in - can happen before the map has its size. That left part of the screen blank until the
  /// parent dragged the map left and right. A tiny zoom nudge, repeated while the first frames settle, makes
  /// it request every visible tile. Skipped once the parent has touched the map.
  void _kickMap() {
    // Only the built-in offline map needs this; every other map loads its own tiles - and the nudges made the
    // map visibly jitter while the screen opened.
    if (!MapConfig.instance.value.isOffline) return;
    for (final ms in const [300, 1100, 2600]) {
      Future.delayed(Duration(milliseconds: ms), () {
        if (!mounted || !_cameraFollowBus || _isLoading) return;
        try {
          final cam = _mapController.camera;
          _mapController.move(cam.center, cam.zoom + 0.02);
          Future.delayed(const Duration(milliseconds: 120), () {
            if (!mounted || !_cameraFollowBus) return;
            try {
              _mapController.move(cam.center, cam.zoom);
            } catch (_) {}
          });
        } catch (_) {}
      });
    }
  }

  void _fitNow() {
    final points = <LatLng>[];
    if (_busLocation != null) points.add(_busLocation!);
    if (_homeLocation != null) points.add(_homeLocation!);
    if (_schoolLocation != null) points.add(_schoolLocation!);
    if (_parentLocation != null) points.add(_parentLocation!);

    if (points.isEmpty) return;

    if (points.length == 1) {
      _camMove(points.first, 15.0);
    } else {
      try {
        _camFit(points);
      } catch (_) {
        _camMove(points.first, 15.0);
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
    // Switched off on the portal while this screen is open: it is replaced at once by a short notice.
    return ModuleGate(moduleKey: 'bus_tracking', title: 'Bus Tracking', child: _buildScreen(context));
  }

  Widget _buildScreen(BuildContext context) {
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
          _on('title') ? _busTitle : 'Bus Tracking',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF1E3C72),
        elevation: 0,
      ),
      body: _moduleOff != null
          ? _buildModuleOff()
          : _isLoading
          ? const CustomLoading(message: 'Connecting to live bus GPS...')
          : (!_isActiveWindow)
              ? _buildOutOfShiftScreen()
              : Stack(
              children: [
                // 1. The map: the official Google map, or one of the other maps (App Module Settings on the portal).
                if (_googleOn)
                  _googleMap(topInset)
                else
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _displayBusLocation ?? _busLocation ?? _homeLocation ?? _schoolLocation ?? const LatLng(25.2854, 51.5310),
                    initialZoom: 15.0,
                    // Street detail goes to zoom 15 and is drawn larger up to 18; closer than that
                    // the map would go blank.
                    minZoom: 8,
                    maxZoom: MapConfig.instance.value.maxZoom,
                    // Two fingers turn the map a full 360 degrees; the compass button (top right) snaps it back to north.
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
                    // The map has its size now: make sure the offline tiles cover the whole screen.
                    onMapReady: _kickMap,
                    // Disable follow mode when user manually pans the map (like Uber)
                    onPositionChanged: (pos, hasGesture) {
                      _rotation.value = pos.rotation;
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
                    _baseMap,

                    // Road-wise Polyline (following real road geometry via OSRM)
                    if (_roadPolyline.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _lineAhead,
                            strokeWidth: 6.0,
                            color: const Color(0xFF2563EB),
                            borderColor: Colors.white,
                            borderStrokeWidth: 2.5,
                            strokeCap: StrokeCap.round,
                            strokeJoin: StrokeJoin.round,
                          ),
                        ],
                      ),

                    // 4 Distinct Markers: School, Home, Bus, Parent. They stay upright and readable however the map is turned.
                    MarkerLayer(
                      rotate: true,
                      markers: [
                        // 1. School Marker
                        if (_schoolLocation != null && _on('school'))
                          Marker(
                            point: _schoolLocation!,
                            width: 170,
                            height: 96,
                            child: _buildMarkerItem(
                              icon: Icons.school_rounded,
                              iconColor: Colors.white,
                              bgColor: const Color(0xFF4A148C),
                              label: _schoolName,
                              wide: true,
                            ),
                          ),

                        // 2. Student Home Marker
                        if (_homeLocation != null && _on('home'))
                          Marker(
                            point: _homeLocation!,
                            width: 70,
                            height: 70,
                            child: _buildMarkerItem(
                              icon: Icons.home_rounded,
                              iconColor: Colors.white,
                              bgColor: const Color(0xFF2E7D32),
                              label: 'Your stop',
                            ),
                          ),

                        // 4. Parent's Own Location Marker
                        if (_parentLocation != null && _on('me'))
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
                              // The bus itself. Moving: an arrow that turns with the map, so it always points the way the
                              // bus drives. Stopped: the bus icon, kept upright.
                              Marker(point: pos, width: 56, height: 56, rotate: _speed <= 3, child: _buildBusIcon()),
                              // Its speed label: always upright, above the bus (unless the school hides the speed).
                              if (_showBusTag)
                                Marker(point: pos, width: 110, height: 104, rotate: true,
                                    child: Align(alignment: Alignment.topCenter, child: _buildBusPill())),
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
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            child: Text(
                              MapConfig.instance.value.credit,
                              style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
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
                      if (_on('fullscreen'))
                      _buildFloatingAction(
                        icon: _full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                        tooltip: _full ? 'Exit full screen' : 'Full screen',
                        onTap: () => _setFull(!_full),
                      ),
                      // Compass: appears once the map is turned; one tap brings north back up.
                      if (_on('compass'))
                      ValueListenableBuilder<double>(
                        valueListenable: _rotation,
                        builder: (context, rot, _) {
                          final turned = rot % 360;
                          final off = turned > 1 && turned < 359;
                          return AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: !off
                                ? const SizedBox(key: ValueKey('nocompass'), height: 0)
                                : Padding(
                                    key: const ValueKey('compass'),
                                    padding: const EdgeInsets.only(top: 10),
                                    child: Material(
                                      color: Colors.white,
                                      shape: const CircleBorder(),
                                      elevation: 4,
                                      shadowColor: Colors.black38,
                                      child: InkWell(
                                        customBorder: const CircleBorder(),
                                        onTap: _camNorth,
                                        child: Tooltip(
                                          message: 'Point north up',
                                          child: Padding(
                                            padding: const EdgeInsets.all(10),
                                            // North on screen is the map's turn, clockwise; the needle follows it.
                                            child: Transform.rotate(
                                              angle: rot * math.pi / 180,
                                              child: const Icon(Icons.navigation_rounded, color: Color(0xFFDC2626), size: 22),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                          );
                        },
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

  Widget _buildModuleOff() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(color: Color(0xFFF1F5F9), shape: BoxShape.circle),
              child: const Icon(Icons.location_off_rounded, size: 34, color: _muted),
            ),
            const SizedBox(height: 16),
            Text(_moduleOff!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF0F172A))),
            const SizedBox(height: 6),
            const Text('Please contact the school for details.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _muted)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: FilledButton.styleFrom(backgroundColor: _navy),
              child: const Text('Back to home'),
            ),
          ]),
        ),
      );

  /// Full screen hides the header, so the status bar sits on the light map: dark icons there.
  void _setFull(bool on) {
    setState(() => _full = on);
    SystemChrome.setSystemUIOverlayStyle(on ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light);
  }

  Widget _fullPill() {
    final parts = [
      if (_etaMinutes > 0 && _on('eta')) '~$_etaMinutes min $_targetLabel',
      if (_positionLive && _showSpeed) '${_speed.toInt()} km/h' else if (!_positionLive && _showLive) _freshLabel,
    ];
    if (parts.isEmpty) parts.add(_status.$1);
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

  /// The official Google map: the same pins, bus and road line as the other maps.
  Widget _googleMap(double topInset) {
    final pins = <GPin>[
      if (_schoolLocation != null && _on('school'))
        GPin(id: 'school', pos: _schoolLocation!, style: PinStyle(size: 34, color: const Color(0xFF4A148C), icon: Icons.school_rounded, label: _schoolName)),
      if (_homeLocation != null && _on('home'))
        GPin(id: 'home', pos: _homeLocation!, style: const PinStyle(size: 34, color: Color(0xFF2E7D32), icon: Icons.home_rounded, label: 'Your stop')),
      if (_parentLocation != null && _on('me'))
        GPin(id: 'me', pos: _parentLocation!, style: const PinStyle(size: 30, color: Color(0xFF0288D1), icon: Icons.person_pin_circle_rounded, label: 'You')),
    ];
    final src = MapConfig.instance.value;
    final center = _displayBusLocation ?? _busLocation ?? _homeLocation ?? _schoolLocation ?? const LatLng(25.2854, 51.5310);
    final lines = [
      if (_roadPolyline.isNotEmpty) GLine(id: 'route', points: _lineAhead, color: const Color(0xFF2563EB)),
    ];
    // Room for the header buttons and the trip card, so the map's logo and a fitted view stay visible.
    final pad = EdgeInsets.only(top: topInset + 56, bottom: _full ? 72 : 210);
    void ready(BusMapCam cam) {
      _gcam = cam;
      if (_initialFitted) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _fitNow(); });
    }
    void gesture() {
      if (_cameraFollowBus) setState(() => _cameraFollowBus = false);
    }
    if (src.isLibre) {
      return LibreBusMap(
        key: ValueKey('lmap-${src.signature}'),
        styleUrl: src.url,
        initialCenter: center,
        initialZoom: 15,
        pins: pins,
        lines: lines,
        bus: _busPos,
        busLook: _busLook,
        padding: pad,
        onReady: ready,
        onUserGesture: gesture,
        onRotation: (r) => _rotation.value = r,
      );
    }
    return GoogleBusMap(
      key: ValueKey('gmap-${src.signature}'),
      initialCenter: center,
      initialZoom: 15,
      hybrid: src.googleHybrid,
      pins: pins,
      lines: lines,
      bus: _busPos,
      busLook: _busLook,
      padding: pad,
      onReady: ready,
      onUserGesture: gesture,
      onRotation: (r) => _rotation.value = r,
    );
  }

  /// The bus on the official Google map: arrow facing the way it drives while moving, bus icon when stopped,
  /// and the status pill above it.
  BusLook _busLook() {
    final moving = _speed > 3;
    final active = _isActiveWindow;
    final color = active ? (moving ? const Color(0xFFFF8F00) : const Color(0xFF78909C)) : Colors.blueGrey;
    return BusLook(
      body: PinStyle(
        size: 40,
        color: color,
        border: 2.5,
        icon: moving ? Icons.navigation_rounded : Icons.directions_bus_rounded,
        halo: moving ? const Color(0x33FF8F00) : null,
      ),
      heading: _busBearing,
      rotate: moving,
      pill: !_showBusTag
          ? null
          : PillStyle(
              text: !active ? 'OFFLINE' : (moving ? '${_speed.toInt()} km/h' : _standLabel),
              color: active ? const Color(0xFF1E3C72) : const Color(0xFF616161),
              dot: active ? (moving ? Colors.greenAccent : Colors.orangeAccent) : null,
            ),
    );
  }

  /// Marker builder for School, Home, and Parent
  Widget _buildMarkerItem({
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required String label,
    bool wide = false, // the school: its full name, up to two lines
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
          constraints: BoxConstraints(maxWidth: wide ? 160 : 90),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: wide ? 2 : 1,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: bgColor, height: 1.2),
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

  /// The speed / status label above the bus (kept upright on screen however the map is turned).
  Widget _buildBusPill() {
    final bool isMoving = _speed > 3;
    return Container(
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
                  isMoving ? '${_speed.toInt()} km/h' : _standLabel,
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ] else
                const Text(
                  'OFFLINE',
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                ),
            ],
          ),
        );
  }

  /// The bus: an arrow facing the direction of travel while moving, the bus icon when stopped.
  Widget _buildBusIcon() {
    final bool isMoving = _speed > 3;
    return Center(
        child: Transform.rotate(
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
          if (_on('shift_times'))
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

  // ─── Trip card ────────────────────────────────────────────────────────────────────────────────
  static const _navy = Color(0xFF1E3C72);
  static const _green = Color(0xFF15803D);
  static const _blue = Color(0xFF2563EB);
  static const _muted = Color(0xFF64748B);

  /// "13:05" -> "1:05 PM".
  String _t12(String? hm) {
    if (hm == null || hm.isEmpty) return '';
    final p = hm.split(':');
    final h = int.tryParse(p[0]) ?? 0;
    final m = p.length > 1 ? p[1].padLeft(2, '0') : '00';
    return '${h % 12 == 0 ? 12 : h % 12}:$m ${h >= 12 ? 'PM' : 'AM'}';
  }

  String _clock(DateTime t) => _t12('${t.hour}:${t.minute}');

  bool get _travelling => _childStage != 'done' && _otherEvent == null;

  /// What is happening for this child on this trip: (words, colour, icon).
  (String, Color, IconData) get _status {
    final morning = _currentShift == 'morning';
    if (_otherEvent != null && _childStage == 'done') {
      return switch (_otherEvent) {
        'absent' => ('Marked absent for this trip', _muted, Icons.event_busy_rounded),
        'by_parent' => (morning ? 'Dropped at school by parent' : 'Collected by parent', _muted, Icons.family_restroom_rounded),
        'leave' => ('On leave for this trip', _muted, Icons.event_busy_rounded),
        _ => ('Not travelling this trip', _muted, Icons.event_busy_rounded),
      };
    }
    // The bus has stopped reporting: say so, rather than describe a position that is out of date.
    final silent = _busSilent;
    // Close and about to get there: within about two minutes and a short distance.
    final near = !silent && _etaMinutes > 0 && _etaMinutes <= 2 && _roadDistanceKm > 0 && _roadDistanceKm < 1.2;
    const amber = Color(0xFFD97706);
    if (morning) {
      switch (_childStage) {
        case 'on_bus':
          if (near && _targetLabel == 'to school') return ('Arriving at school', amber, Icons.school_rounded);
          return ('Picked up${_pickedAt != null ? ' at ${_t12(_pickedAt)}' : ''}', _green, Icons.directions_bus_rounded);
        case 'done':
          return ('Reached school${_droppedAt != null ? ' at ${_t12(_droppedAt)}' : ''}', _green, Icons.school_rounded);
        default:
          if (silent) return ('Waiting for the bus signal', _muted, Icons.wifi_off_rounded);
          if (_busParked) return ('Bus has not started yet', _muted, Icons.local_parking_rounded);
          if (near) return ('Bus is arriving at your stop', amber, Icons.notifications_active_rounded);
          // With no arrival time to go by ("Bus and home only"), a bus that is live and not parked is on its way.
          return (_etaMinutes > 0 || _routeHidden || !_on('eta') ? 'Bus is on the way to your home' : 'Waiting for the bus', _blue, Icons.near_me_rounded);
      }
    }
    switch (_childStage) {
      case 'on_bus':
        if (near && _targetLabel != 'to school') return ('Bus is arriving at your stop', amber, Icons.notifications_active_rounded);
        return ('On the bus${_pickedAt != null ? ' since ${_t12(_pickedAt)}' : ''}', _green, Icons.directions_bus_rounded);
      case 'done':
        return ('Dropped home${_droppedAt != null ? ' at ${_t12(_droppedAt)}' : ''}', _green, Icons.home_rounded);
      default:
        return ('Waiting to board at school', _blue, Icons.school_rounded);
    }
  }

  /// The line under the status: which trip this is and where the bus is heading right now.
  ///   Morning: on the way to the home for pickup -> picked up, on the way to school -> at school.
  ///   Afternoon: school pickup -> on the way home -> home.
  String get _phaseLine {
    final morning = _currentShift == 'morning';
    final trip = morning ? 'Morning trip' : 'Afternoon trip';
    String phase;
    if (_otherEvent != null && _childStage == 'done') {
      phase = 'Not travelling';
    } else if (morning) {
      switch (_childStage) {
        case 'on_bus':
          phase = 'On the way to school';
          break;
        case 'done':
          phase = 'Trip complete';
          break;
        default:
          phase = 'Heading to your home for pickup';
      }
    } else {
      switch (_childStage) {
        case 'on_bus':
          phase = 'On the way home';
          break;
        case 'done':
          phase = 'Trip complete';
          break;
        default:
          phase = 'School pickup, then home';
      }
    }
    String? stops;
    if (_stopsBefore != null && _travelling) {
      stops = _stopsBefore == 0
          ? (_targetLabel == 'to school' ? 'school is next' : 'your stop is next')
          : '$_stopsBefore stop${_stopsBefore == 1 ? '' : 's'} before ${_targetLabel == 'to school' ? 'school' : 'yours'}';
    }
    final gps = !_travelling ? null
        : _speedNote == 'gps_weak' ? 'GPS weak - last known position'
        : (_place == 'parking' && !_busParked ? 'in a car park' : null);
    return [trip, phase, if (stops != null) stops, if (gps != null) gps].join(' · ');
  }
  void _locateBus() {
    _showBanner('Locating live bus position...');
    _fetchLocation(full: true);
    setState(() => _cameraFollowBus = true);
    final p = _displayBusLocation ?? _busLocation ?? _homeLocation;
    if (p != null) {
      _camMove(p, 16.5);
    }
  }

  Future<void> _call(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), ''));
    try {
      await launchUrl(uri);
    } catch (e) {
      debugPrint('Call failed: $e');
    }
  }

  Widget _buildBottomMetricsCard() {
    final (text, color, icon) = _status;
    final eta = _travelling && _etaMinutes > 0 && _on('eta') ? DateTime.now().add(Duration(minutes: _etaMinutes)) : null;
    final live = _positionLive;
    void toggle() => setState(() => _cardOpenChoice = !_cardOpen);

    return Material(
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Handle, and the status row: a tap shows or hides the details (they open above).
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: toggle,
                child: Column(children: [
                  Container(
                    width: 34,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(4)),
                  ),
                  Row(children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
                      child: Icon(icon, color: color, size: 17),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (_on('status'))
                        Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
                        if (_on('phase') || !_on('status'))
                        Text(
                            _on('phase') ? _phaseLine : (_currentShift == 'morning' ? 'Morning trip' : 'Afternoon trip'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: _muted)),
                      ]),
                    ),
                    const SizedBox(width: 6),
                    if (_showLive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: live ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(width: 6, height: 6, decoration: BoxDecoration(color: live ? const Color(0xFF16A34A) : const Color(0xFF94A3B8), shape: BoxShape.circle)),
                        const SizedBox(width: 4),
                        Text(live ? 'Live' : _freshLabel.replaceFirst('Updated ', ''),
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: live ? _green : _muted)),
                      ]),
                    ),
                    Icon(_cardOpen ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded, color: _muted, size: 22),
                  ]),
                ]),
              ),

              // Details - above the arrival bar, so the card grows upwards.
              if (_cardOpen) ...[
                if (_on('timeline')) ...[
                  const SizedBox(height: 12),
                  _timeline(),
                ],
                // Speed, distance and last update - each only when the school shows it.
                if (_showSpeed || (!_routeHidden && _on('distance')) || _showLive) ...[
                const SizedBox(height: 10),
                Row(children: [
                  for (final t in [
                    if (_showSpeed) _tile(Icons.speed_rounded, live ? '${_speed.toInt()} km/h' : '--', 'Speed'),
                    if (!_routeHidden && _on('distance'))
                      _tile(Icons.alt_route_rounded, _travelling && _roadDistanceKm > 0 ? '${_roadDistanceKm.toStringAsFixed(1)} km' : '--',
                          _travelling ? _targetLabel : 'Distance'),
                    if (_showLive) _tile(Icons.update_rounded, live ? 'Live' : _freshLabel.replaceFirst('Updated ', '').replaceFirst('Last seen ', ''), 'Updated'),
                  ].indexed) ...[if (t.$1 > 0) const SizedBox(width: 6), t.$2],
                ]),
                ],
                ..._crewRow(),
              ],

              // Arrival, as a clock time - or a locate button when there is none.
              const SizedBox(height: 10),
              if (eta != null)
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF1E3C72), Color(0xFF2A5298)]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(children: [
                    const Icon(Icons.schedule_rounded, color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: _targetLabel == 'to school' ? 'School at ' : 'Your stop at ',
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
                          TextSpan(text: '~${_clock(eta)}', style: const TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w800)),
                          TextSpan(text: '  ·  $_etaMinutes min', style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_on('locate')) _roundButton(Icons.my_location_rounded, _locateBus, light: true),
                  ]),
                )
              else if (_on('locate'))
                SizedBox(
                  height: 38,
                  child: OutlinedButton.icon(
                    onPressed: _locateBus,
                    icon: const Icon(Icons.my_location_rounded, size: 17),
                    label: const Text('Locate bus', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _navy,
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roundButton(IconData icon, VoidCallback onTap, {bool light = false, Color color = _navy}) => Material(
        color: light ? Colors.white : color.withValues(alpha: 0.1),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(7), child: Icon(icon, color: color, size: 18)),
        ),
      );

  /// Three steps of the trip, with the times they happened.
  Widget _timeline() {
    final morning = _currentShift == 'morning';
    final step = _childStage == 'done' ? 2 : (_childStage == 'on_bus' ? 1 : 0);
    final labels = morning ? ['Pickup', 'On the way', 'At school'] : ['Boarding', 'On the way', 'Home'];
    final times = !_on('times')
        ? const ['', '', '']
        : [
            morning ? (_pickedAt != null ? _t12(_pickedAt) : '') : '',
            _pickedAt != null ? _t12(_pickedAt) : '',
            _droppedAt != null ? _t12(_droppedAt) : '',
          ];
    Widget dot(int i) {
      final done = i < step || (i == step && _childStage == 'done');
      final current = i == step && !done;
      return Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: done ? _green : (current ? Colors.white : const Color(0xFFF1F5F9)),
          shape: BoxShape.circle,
          border: Border.all(color: done ? _green : (current ? _blue : const Color(0xFFCBD5E1)), width: current ? 3 : 2),
        ),
        child: done ? const Icon(Icons.check_rounded, size: 12, color: Colors.white) : null,
      );
    }

    Widget bar(int i) => Expanded(
          child: Container(height: 3, margin: const EdgeInsets.symmetric(horizontal: 4), color: i < step ? _green : const Color(0xFFE2E8F0)),
        );

    Widget label(int i) => Expanded(
          child: Column(
            crossAxisAlignment: i == 0 ? CrossAxisAlignment.start : (i == 2 ? CrossAxisAlignment.end : CrossAxisAlignment.center),
            children: [
              Text(labels[i], style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: i <= step ? const Color(0xFF0F172A) : _muted)),
              if (times[i].isNotEmpty) Text(times[i], style: const TextStyle(fontSize: 10, color: _muted)),
            ],
          ),
        );

    if (!_travelling && _otherEvent != null) return const SizedBox.shrink();
    return Column(children: [
      Row(children: [dot(0), bar(0), dot(1), bar(1), dot(2)]),
      const SizedBox(height: 5),
      Row(children: [label(0), label(1), label(2)]),
    ]);
  }

  Widget _tile(IconData icon, String value, String caption) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE2E8F0))),
          child: Column(children: [
            Icon(icon, size: 14, color: _navy),
            const SizedBox(height: 2),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
            Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: _muted)),
          ]),
        ),
      );

  /// Who the parent may call: the bus monitor, if the school allows it (App Module Settings) - on a full-width
  /// row with a labelled Call button. The driver is never shown to parents.
  List<Widget> _crewRow() {
    final c = _crew;
    if (c == null) return const [];
    String s(String k) => '${c[k] ?? ''}'.trim();
    final people = [
      if (s('monitor_name').isNotEmpty) ('Bus monitor', s('monitor_name'), s('monitor_phone')),
    ];
    if (people.isEmpty) return const [];

    Widget who((String, String, String) p, {bool single = false}) => Container(
          padding: EdgeInsets.fromLTRB(10, 5, single ? 6 : 2, 5),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0))),
          child: Row(children: [
            if (single) ...[
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(color: Color(0xFFEFF6FF), shape: BoxShape.circle),
                child: const Icon(Icons.person_rounded, color: _navy, size: 17),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.$1, style: const TextStyle(fontSize: 10, color: _muted)),
                Text(p.$2, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF0F172A))),
              ]),
            ),
            if (p.$3.isNotEmpty)
              single
                  ? FilledButton.icon(
                      onPressed: () => _call(p.$3),
                      icon: const Icon(Icons.call_rounded, size: 16),
                      label: const Text('Call', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      style: FilledButton.styleFrom(
                        backgroundColor: _green,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    )
                  : _roundButton(Icons.call_rounded, () => _call(p.$3), color: _green),
          ]),
        );

    return [
      const SizedBox(height: 8),
      if (people.length == 1)
        who(people.first, single: true)
      else
        Row(children: [
          Expanded(child: who(people[0])),
          const SizedBox(width: 6),
          Expanded(child: who(people[1])),
        ]),
    ];
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
