// Checks lib/services/pmtiles_reader.dart against the official pmtiles CLI.
//
// Reference tiles were written by `pmtiles tile assets/map/qatar.pmtiles z x y` into the folder
// named by PMTILES_REF (one file per tile, named z-x-y.bin). Without that folder only the
// structural checks run.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_step_gps/services/pmtiles_reader.dart';

void main() {
  late PmTilesReader reader;
  setUpAll(() async => reader = await PmTilesReader.open('assets/map/qatar.pmtiles'));
  tearDownAll(() => reader.close());

  test('header', () {
    expect(reader.minZoom, 0);
    expect(reader.maxZoom, 15);
  });

  test('tile ids follow the PMTiles spec examples', () {
    // From the spec: z0 -> 0, z1 tiles -> 1..4, first z2 tile -> 5.
    expect(PmTilesReader.zxyToTileId(0, 0, 0), 0);
    expect(PmTilesReader.zxyToTileId(1, 0, 0), 1);
    expect(PmTilesReader.zxyToTileId(1, 0, 1), 2);
    expect(PmTilesReader.zxyToTileId(1, 1, 1), 3);
    expect(PmTilesReader.zxyToTileId(1, 1, 0), 4);
    expect(PmTilesReader.zxyToTileId(2, 0, 0), 5);
  });

  test('a tile outside Qatar is absent, not an error', () async {
    expect(await reader.tile(15, 0, 0), isNull);
  });

  test('every reference tile matches the official CLI byte for byte', () async {
    final dir = Directory(Platform.environment['PMTILES_REF'] ?? '');
    if (!dir.existsSync()) {
      markTestSkipped('PMTILES_REF not set');
      return;
    }
    var checked = 0;
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.bin'))) {
      final p = f.uri.pathSegments.last.replaceAll('.bin', '').split('-').map(int.parse).toList();
      var expected = f.readAsBytesSync();
      if (expected.length > 2 && expected[0] == 0x1f && expected[1] == 0x8b) {
        expected = Uint8List.fromList(gzip.decode(expected)); // the CLI may hand back the stored gzip
      }
      final got = await reader.tile(p[0], p[1], p[2]);
      expect(got, isNotNull, reason: 'tile ${p.join('/')} missing');
      expect(got, equals(expected), reason: 'tile ${p.join('/')} differs');
      checked++;
    }
    expect(checked, greaterThan(10));
    // ignore: avoid_print
    print('matched $checked reference tiles');
  });
}
