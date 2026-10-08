import 'dart:io';
import 'dart:typed_data';

/// A minimal reader for PMTiles v3 archives stored as a local file.
///
/// Written here instead of using the `pmtiles` package because no release of it can be installed
/// next to vector_map_tiles 9 and flutter_map 8 (see pubspec.yaml). The format is small and fully
/// specified - https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md - and this reads only
/// what the app needs: one tile at a time, by z/x/y, from a gzip-compressed vector archive.
class PmTilesReader {
  PmTilesReader._(this._file, this._header);

  final RandomAccessFile _file;
  final _Header _header;

  /// Directories already parsed, keyed by their byte offset. The root and the few leaf
  /// directories a map view touches are reused rather than decompressed again for every tile.
  final Map<int, List<_Entry>> _dirCache = {};

  /// Reads are queued, because a RandomAccessFile allows one operation at a time and the map asks
  /// for many tiles at once.
  Future<void> _queue = Future.value();

  int get minZoom => _header.minZoom;
  int get maxZoom => _header.maxZoom;

  static Future<PmTilesReader> open(String path) async {
    final file = await File(path).open();
    final h = _Header.parse(await _readAt(file, 0, 127));
    return PmTilesReader._(file, h);
  }

  Future<void> close() => _file.close();

  /// The uncompressed bytes of the tile at z/x/y, or null when the archive has no tile there
  /// (outside the extracted area, or empty sea).
  Future<Uint8List?> tile(int z, int x, int y) {
    final result = _queue.then((_) => _find(zxyToTileId(z, x, y)));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List?> _find(int tileId) async {
    var dirOffset = _header.rootDirOffset;
    var dirLength = _header.rootDirLength;
    for (var depth = 0; depth < 4; depth++) {
      final entries = await _directory(dirOffset, dirLength);
      final e = _findEntry(entries, tileId);
      if (e == null) return null;
      if (e.runLength > 0) {
        final raw = await _readAt(_file, _header.tileDataOffset + e.offset, e.length);
        return _decompress(raw, _header.tileCompression);
      }
      // runLength 0: a pointer to a leaf directory.
      dirOffset = _header.leafDirsOffset + e.offset;
      dirLength = e.length;
    }
    return null;
  }

  Future<List<_Entry>> _directory(int offset, int length) async {
    final cached = _dirCache[offset];
    if (cached != null) return cached;
    final raw = await _readAt(_file, offset, length);
    final entries = _parseDirectory(_decompress(raw, _header.internalCompression));
    _dirCache[offset] = entries;
    return entries;
  }

  /// The entry covering [tileId]: the last one starting at or before it, if its run reaches it.
  static _Entry? _findEntry(List<_Entry> entries, int tileId) {
    var lo = 0, hi = entries.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final c = entries[mid].tileId;
      if (c == tileId) return entries[mid];
      if (c < tileId) { lo = mid + 1; } else { hi = mid - 1; }
    }
    if (hi >= 0) {
      final e = entries[hi];
      if (e.runLength == 0) return e; // leaf directory: the tile may be inside it
      if (tileId - e.tileId < e.runLength) return e;
    }
    return null;
  }

  static List<_Entry> _parseDirectory(Uint8List b) {
    final r = _VarintReader(b);
    final n = r.next();
    final ids = List<int>.filled(n, 0), runs = List<int>.filled(n, 0);
    final lens = List<int>.filled(n, 0), offs = List<int>.filled(n, 0);
    var last = 0;
    for (var i = 0; i < n; i++) { last += r.next(); ids[i] = last; }
    for (var i = 0; i < n; i++) { runs[i] = r.next(); }
    for (var i = 0; i < n; i++) { lens[i] = r.next(); }
    for (var i = 0; i < n; i++) {
      final v = r.next();
      // 0 means "straight after the previous entry"; anything else is offset + 1.
      offs[i] = (v == 0 && i > 0) ? offs[i - 1] + lens[i - 1] : v - 1;
    }
    return List.generate(n, (i) => _Entry(ids[i], offs[i], lens[i], runs[i]));
  }

  static Uint8List _decompress(Uint8List data, int compression) {
    switch (compression) {
      case 0: // unknown - treat as none
      case 1: // none
        return data;
      case 2: // gzip
        return Uint8List.fromList(gzip.decode(data));
      default:
        throw UnsupportedError('PMTiles compression $compression is not supported (expected gzip)');
    }
  }

  static Future<Uint8List> _readAt(RandomAccessFile f, int offset, int length) async {
    await f.setPosition(offset);
    return f.read(length);
  }

  /// PMTiles tile id: tiles of all lower zoom levels, plus the position along the Hilbert curve.
  static int zxyToTileId(int z, int x, int y) {
    var acc = 0;
    for (var t = 0; t < z; t++) { acc += (1 << t) * (1 << t); }
    var tx = x, ty = y, d = 0;
    for (var s = (1 << z) >> 1; s > 0; s >>= 1) {
      final rx = (tx & s) > 0 ? 1 : 0;
      final ry = (ty & s) > 0 ? 1 : 0;
      d += s * s * ((3 * rx) ^ ry);
      if (ry == 0) {
        if (rx == 1) { tx = s - 1 - tx; ty = s - 1 - ty; }
        final t = tx; tx = ty; ty = t;
      }
    }
    return acc + d;
  }
}

class _Entry {
  const _Entry(this.tileId, this.offset, this.length, this.runLength);
  final int tileId, offset, length, runLength;
}

class _Header {
  _Header.parse(Uint8List b)
      : rootDirOffset = _u64(b, 8),
        rootDirLength = _u64(b, 16),
        leafDirsOffset = _u64(b, 40),
        tileDataOffset = _u64(b, 56),
        internalCompression = b[97],
        tileCompression = b[98],
        minZoom = b[100],
        maxZoom = b[101] {
    if (String.fromCharCodes(b.sublist(0, 7)) != 'PMTiles' || b[7] != 3) {
      throw const FormatException('Not a PMTiles v3 archive');
    }
  }

  final int rootDirOffset, rootDirLength, leafDirsOffset, tileDataOffset;
  final int internalCompression, tileCompression, minZoom, maxZoom;

  static int _u64(Uint8List b, int o) => ByteData.sublistView(b, o, o + 8).getUint64(0, Endian.little);
}

class _VarintReader {
  _VarintReader(this._b);
  final Uint8List _b;
  int _pos = 0;

  int next() {
    var result = 0, shift = 0;
    while (true) {
      final byte = _b[_pos++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }
}
