import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import 'api_service.dart';
import 'offline_map.dart';

/// True when this build carries a Google Maps API key (CI passes --dart-define=GMAPS_KEY_PRESENT=true when the
/// GOOGLE_MAPS_API_KEY secret is set). Without a key the official Google map cannot work - on iOS it would
/// even stop the app - so "Google Maps - official" then falls back to the online Google picture tiles.
const bool kGoogleMapsKey = bool.fromEnvironment('GMAPS_KEY_PRESENT');

/// One base map the apps can draw. Chosen on the portal (App Module Settings -> Map in the apps) and sent
/// with the module switches (api/mobile/modules.php).
///
/// Online maps are ready-made 256 px pictures the phone downloads and keeps in its cache: far quicker to show
/// than the built-in offline map, which the phone has to draw itself from vector data.
@immutable
class MapSource {
  final String type;               // google, carto_voyager, esri_street, offline, custom ...
  final String url;                // tile address with {z} {x} {y} (and {s}); empty for the offline map
  final List<String> subdomains;
  final int maxNativeZoom;         // closer than this the last tiles are drawn larger
  final String attribution;

  const MapSource({
    required this.type,
    required this.url,
    this.subdomains = const [],
    this.maxNativeZoom = 19,
    this.attribution = '',
  });

  /// Until the portal's choice has arrived (first start, no signal): the same default the server uses -
  /// OpenFreeMap, free with no key and no usage limit.
  static const MapSource fallback = MapSource(
    type: 'openfreemap',
    url: 'https://tiles.openfreemap.org/styles/liberty',
    maxNativeZoom: 19,
    attribution: 'OpenFreeMap © OpenMapTiles Data from OpenStreetMap',
  );

  bool get isOffline => !isGoogleSdk && !isLibre && (type == 'offline' || url.isEmpty);

  /// OpenFreeMap: a vector map style drawn natively by MapLibre ([url] is the style address).
  bool get isLibre => type.startsWith('openfreemap') && url.startsWith('https://');

  /// Drawn by a native map component (Google or MapLibre) rather than flutter_map.
  bool get isNative => isGoogleSdk || isLibre;

  /// The official Google Maps component (needs the key in this build; otherwise [url] - Google's tiles - is used).
  bool get isGoogleSdk => kGoogleMapsKey && type.startsWith('google_sdk');

  /// Satellite photos with names (official Google map).
  bool get googleHybrid => type == 'google_sdk_hybrid';

  /// How close the map may zoom: the offline data stops at street level, online maps go further.
  double get maxZoom => isGoogleSdk ? 20 : isLibre ? 19.5 : isOffline ? 18 : (maxNativeZoom + 1).clamp(16, 20).toDouble();

  /// The licence credit shown on the map.
  String get credit {
    final a = (isOffline ? OfflineMap.attribution : attribution).trim();
    if (a.isEmpty) return '';
    return a.startsWith('©') || a.toLowerCase().startsWith('map') || a.toLowerCase().startsWith('tiles') || a.toLowerCase().startsWith('imagery')
        ? a
        : '© $a';
  }

  String get signature => '$type|$url|${subdomains.join(',')}|$maxNativeZoom';

  factory MapSource.fromJson(Map<dynamic, dynamic> m) {
    final subs = m['subdomains'];
    return MapSource(
      type: '${m['type'] ?? 'google'}',
      url: '${m['url'] ?? ''}',
      subdomains: subs is List ? subs.map((e) => '$e').toList() : const [],
      maxNativeZoom: (m['max_native_zoom'] is num) ? (m['max_native_zoom'] as num).toInt().clamp(1, 22).toInt() : 19,
      attribution: '${m['attribution'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'url': url,
        'subdomains': subdomains,
        'max_native_zoom': maxNativeZoom,
        'attribution': attribution,
      };
}

/// The base map in use. Remembered on the phone, so the next start shows the right map at once, and
/// updated whenever the portal's choice arrives (the parent app re-reads it every few seconds).
class MapConfig extends ValueNotifier<MapSource> {
  MapConfig._() : super(MapSource.fallback);
  static final MapConfig instance = MapConfig._();

  static const String _prefsKey = 'app_map_source_v1';
  bool _restored = false;

  /// Read the choice saved on this phone. Called once at app start, so the first map already draws the right
  /// map instead of starting with the default and switching a moment later (that switch made the map jump).
  Future<void> restore() => _restore();

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final p = await SharedPreferences.getInstance();
      final j = p.getString(_prefsKey);
      if (j != null && j.isNotEmpty) {
        final s = MapSource.fromJson(jsonDecode(j) as Map);
        if (s.signature != value.signature) value = s;
      }
    } catch (e) {
      debugPrint('MapConfig: could not read the saved map: $e');
    }
  }

  /// Read the saved choice, then ask the server for the current one.
  Future<void> refresh() async {
    await _restore();
    try {
      final res = await ApiService.getModules();
      final m = res['map'];
      if (res['success'] == true && m is Map) apply(m);
    } catch (e) {
      debugPrint('MapConfig: could not fetch the map choice: $e');
    }
  }

  /// Take the choice from a modules response.
  void apply(Map<dynamic, dynamic> m) {
    final s = MapSource.fromJson(m);
    // Only a secure (https) tile address with {z} {x} {y} is accepted, whatever the server sends.
    final okUrl = s.url.startsWith('https://') &&
        (s.type.startsWith('openfreemap') || (s.url.contains('{z}') && s.url.contains('{x}') && s.url.contains('{y}')));
    if (!okUrl && (s.url.isNotEmpty || s.type != 'offline')) return;
    if (s.signature == value.signature) return;
    value = s;
    SharedPreferences.getInstance()
        .then((p) => p.setString(_prefsKey, jsonEncode(s.toJson())))
        .catchError((Object e) {
      debugPrint('MapConfig: could not save the map: $e');
      return false;
    });
  }
}

/// The base map as a flutter_map layer: an online tile layer, or the built-in offline map. Follows the portal's
/// choice while the screen is open.
class BaseMapLayer extends StatefulWidget {
  const BaseMapLayer({super.key});

  @override
  State<BaseMapLayer> createState() => _BaseMapLayerState();
}

class _BaseMapLayerState extends State<BaseMapLayer> {
  Widget? _offline;

  @override
  void initState() {
    super.initState();
    MapConfig.instance.addListener(_changed);
    _prepareOffline();
  }

  @override
  void dispose() {
    MapConfig.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _prepareOffline();
  }

  /// The offline map is only opened when it is the one chosen.
  void _prepareOffline() {
    if (!MapConfig.instance.value.isOffline || _offline != null) return;
    OfflineMap.load().then((m) {
      if (!mounted) return;
      setState(() => _offline = VectorTileLayer(
            theme: m.theme,
            tileProviders: TileProviders({OfflineMap.sourceName: m.provider}),
            maximumTileSubstitutionDifference: 3,
            maximumZoom: 20,
          ));
    }).catchError((Object e) {
      debugPrint('Offline map failed to load: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = MapConfig.instance.value;
    if (s.isOffline) {
      return _offline ?? const ColoredBox(color: Color(0xFFF2F0EB), child: SizedBox.expand());
    }
    return TileLayer(
      key: ValueKey(s.signature), // a different map: start a fresh layer, never mix tiles of two maps
      urlTemplate: s.url,
      subdomains: s.subdomains,
      maxNativeZoom: s.maxNativeZoom,
      maxZoom: 22,
      userAgentPackageName: 'com.smartstep.gps',
      // Keep tiles just off screen ready, so panning and following the bus never shows empty squares.
      keepBuffer: 4,
      panBuffer: 1,
    );
  }
}
