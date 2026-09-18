import 'dart:typed_data';

import 'package:image_bytes_cache/src/environment_specific/image_bytes_blob_store_cache_js.dart';
import 'package:image_bytes_cache/src/environment_specific/image_bytes_blob_store_opfs_js.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';

/// Web payload half of [IndexedImageBytesCache]: Cache API + OPFS by size.
///
/// Bodies below [opfsByteThreshold] use Cache API Responses with synthetic
/// `.invalid` URLs ([ImageBytesBlobStore$Cache$JS]). Bodies at or above the
/// threshold use OPFS files ([ImageBytesBlobStore$Opfs$JS]) so large rasters
/// avoid Cache API structured-clone cost. Meta stays on the separate Cache
/// index document; prune / LRU never scan payload bytes to decide eviction.
///
/// [write] routes by length and deletes the key from the other backend so a
/// resize across the threshold cannot leave a stale twin. [read] checks Cache
/// then OPFS. [reclaimOrphans] / [wipeAll] cover both backends under the brain's
/// exclusive domain. No IsolateController on this path.
final class ImageBytesBlobStore$Web$JS implements IImageBytesBlobStore {
  ImageBytesBlobStore$Web$JS._({
    required ImageBytesBlobStore$Cache$JS cache,
    required ImageBytesBlobStore$Opfs$JS opfs,
  }) : _cache = cache,
       _opfs = opfs;

  /// Payloads at or above this size are stored in OPFS; smaller ones in Cache API.
  ///
  /// Matches the VM transferable write threshold so "small SVG vs large raster"
  /// is one documented cut across platforms. Below it, Cache API is enough and
  /// avoids OPFS open/write ceremony for chrome assets.
  static const int opfsByteThreshold = 64 * 1024;

  final ImageBytesBlobStore$Cache$JS _cache;
  final ImageBytesBlobStore$Opfs$JS _opfs;
  var _closed = false;

  /// Opens Cache API and OPFS payload backends.
  static Future<ImageBytesBlobStore$Web$JS> open() async {
    final cache = await ImageBytesBlobStore$Cache$JS.open();
    try {
      final opfs = await ImageBytesBlobStore$Opfs$JS.open();
      return ImageBytesBlobStore$Web$JS._(cache: cache, opfs: opfs);
    } on Object {
      await cache.close();
      rethrow;
    }
  }

  @override
  Future<Uint8List?> read(ImageCacheKey key) async {
    _ensureOpen();
    final fromCache = await _cache.read(key);
    if (fromCache != null) return fromCache;
    return _opfs.read(key);
  }

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) async {
    _ensureOpen();
    // Clear the other backend first so [read] (Cache-then-OPFS) cannot return a
    // stale twin if the second half of the write fails after a successful put.
    if (bytes.lengthInBytes >= opfsByteThreshold) {
      await _cache.delete(key);
      await _opfs.write(key, bytes);
      return;
    }
    await _opfs.delete(key);
    await _cache.write(key, bytes);
  }

  @override
  Future<void> delete(ImageCacheKey key) async {
    _ensureOpen();
    await (_cache.delete(key), _opfs.delete(key)).wait;
  }

  /// Deletes Cache and OPFS entries whose key is not in [indexedKeys].
  Future<void> reclaimOrphans(Set<String> indexedKeys) async {
    _ensureOpen();
    await (
      _cache.reclaimOrphans(indexedKeys),
      _opfs.reclaimOrphans(indexedKeys),
    ).wait;
  }

  /// Wipes both payload backends (corrupt index recovery).
  Future<void> wipeAll() async {
    _ensureOpen();
    await (_cache.wipeAll(), _opfs.wipeAll()).wait;
  }

  /// Closes both backends. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await (_cache.close(), _opfs.close()).wait;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError(r'ImageBytesBlobStore$Web$JS is closed');
    }
  }
}
