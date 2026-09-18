import 'dart:js_interop';
import 'dart:typed_data';

import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_bytes_web_keys.dart';
import 'package:web/web.dart' as web;

/// Cache API half of the web blob store: Responses for small payloads.
///
/// Owned by [ImageBytesBlobStore$Web$JS], which routes large bodies to OPFS.
/// Retention and timestamps stay on [ImageBytesIndex$Cache$JS]. This type owns
/// one named Cache ([ImageBytesWebKeys.blobsCacheName]). Keys are synthetic
/// absolute URLs from [ImageBytesWebKeys.blobUrl] so payloads never share
/// identity with real network fetches and stay out of a resident Dart heap map.
///
/// [reclaimOrphans] enumerates [web.Cache.keys] and deletes entries whose
/// [ImageCacheKey] is not in the index. [close] drops the handle; later ops
/// throw [StateError].
final class ImageBytesBlobStore$Cache$JS implements IImageBytesBlobStore {
  ImageBytesBlobStore$Cache$JS._(this._cache);

  web.Cache? _cache;
  var _closed = false;

  /// Opens (or creates) the payload Cache.
  static Future<ImageBytesBlobStore$Cache$JS> open() async {
    final cache = await web.window.caches.open(ImageBytesWebKeys.blobsCacheName).toDart;
    return ImageBytesBlobStore$Cache$JS._(cache);
  }

  @override
  Future<Uint8List?> read(ImageCacheKey key) async {
    final cache = _ensureOpen();
    final match = await cache.match(ImageBytesWebKeys.blobUrl(key).toJS).toDart;
    return switch (match) {
      null => null,
      final response => await _$responseBytes(response),
    };
  }

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) async {
    final cache = _ensureOpen();
    await cache
        .put(
          ImageBytesWebKeys.blobUrl(key).toJS,
          web.Response(bytes.toJS),
        )
        .toDart;
  }

  @override
  Future<void> delete(ImageCacheKey key) async {
    final cache = _ensureOpen();
    await cache.delete(ImageBytesWebKeys.blobUrl(key).toJS).toDart;
  }

  /// Deletes blob entries whose key is not in [indexedKeys].
  Future<void> reclaimOrphans(Set<String> indexedKeys) async {
    final cache = _ensureOpen();
    final requests = (await cache.keys().toDart).toDart;
    for (final request in requests) {
      final keyValue = ImageBytesWebKeys.keyValueFromBlobUrl(request.url);
      if (keyValue == null || indexedKeys.contains(keyValue)) continue;
      await cache.delete(request).toDart;
    }
  }

  /// Deletes every entry in the payload Cache.
  Future<void> wipeAll() async {
    final cache = _ensureOpen();
    final requests = (await cache.keys().toDart).toDart;
    for (final request in requests) {
      await cache.delete(request).toDart;
    }
  }

  /// Drops the Cache handle. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cache = null;
  }

  web.Cache _ensureOpen() {
    if (_closed) {
      throw StateError(r'ImageBytesBlobStore$Cache$JS is closed');
    }
    return switch (_cache) {
      final cache? => cache,
      null => throw StateError(r'ImageBytesBlobStore$Cache$JS is closed'),
    };
  }
}

Future<Uint8List> _$responseBytes(web.Response response) async {
  final jsBytes = await response.bytes().toDart;
  return jsBytes.toDart;
}
