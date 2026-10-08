import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' show Theme, ThemeReader;

import 'pmtiles_reader.dart';

/// The English street map of Qatar that ships inside the app.
///
/// The tiles are a Protomaps extract of OpenStreetMap (ODbL - the map must show
/// "© OpenStreetMap"), and the style is the official Protomaps "light" flavour reduced to English
/// labels. Nothing is fetched from a third-party tile server, so there is no usage policy to
/// break and the map keeps working with no signal.
///
/// To refresh the map data: extract a new qatar.pmtiles (see tool/map/README.md), replace the asset
/// and bump [_tilesVersion] so installed apps copy the new file instead of keeping the old one.
class OfflineMap {
  OfflineMap._(this.theme, this.provider);

  static const String sourceName = 'protomaps';
  /// SimpleAttributionWidget puts the '©' in front itself.
  static const String attribution = 'OpenStreetMap contributors';

  static const String _tilesAsset = 'assets/map/qatar.pmtiles';
  static const String _styleAsset = 'assets/map/protomaps_light_en.json';
  static const String _tilesVersion = '20261008';

  final Theme theme;
  final VectorTileProvider provider;

  static Future<OfflineMap>? _loading;

  /// Loads once per app run; every map screen after the first reuses it.
  static Future<OfflineMap> load() {
    return _loading ??= _load().catchError((Object e) {
      _loading = null; // let the next attempt try again rather than caching the failure
      throw e;
    });
  }

  static Future<OfflineMap> _load() async {
    final path = await _ensureTilesOnDisk();
    final archive = await PmTilesReader.open(path);
    final styleJson = jsonDecode(await rootBundle.loadString(_styleAsset)) as Map<String, dynamic>;
    final theme = ThemeReader().read(styleJson);
    return OfflineMap._(theme, _PmTilesProvider(archive));
  }

  /// PMTiles needs random access to a real file, and assets are not files on Android, so the
  /// bundled archive is copied out once. A versioned name means an app update with new map data
  /// writes a fresh copy, and older copies are deleted so they do not pile up.
  static Future<String> _ensureTilesOnDisk() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/maps');
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File('${dir.path}/qatar-$_tilesVersion.pmtiles');

    if (!await target.exists()) {
      final data = await rootBundle.load(_tilesAsset);
      final tmp = File('${target.path}.part');
      await tmp.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      await tmp.rename(target.path); // never leave a half-written archive under the real name
    }

    await for (final f in dir.list()) {
      if (f is File && f.path != target.path && f.path.endsWith('.pmtiles')) {
        try { await f.delete(); } catch (_) { /* in use or already gone - harmless */ }
      }
    }
    return target.path;
  }
}

/// Serves vector tiles straight out of the bundled PMTiles archive.
class _PmTilesProvider extends VectorTileProvider {
  _PmTilesProvider(this.archive);

  final PmTilesReader archive;

  @override
  int get maximumZoom => archive.maxZoom;

  @override
  int get minimumZoom => archive.minZoom;

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final data = await archive.tile(tile.z, tile.x, tile.y);
    // Outside Qatar, or open sea with nothing in it: an empty tile, not an error.
    if (data == null) {
      throw ProviderException(message: 'No tile at $tile', retryable: Retryable.none, statusCode: 404);
    }
    return data;
  }
}
