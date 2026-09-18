// Integration coverage for ImageBytesCache.open on web (Cache API + OPFS).
//
// Run with:
// dart test -p chrome test/open/image_bytes_cache_open_web_test.dart
//
// Skipped on the VM compiler: package:web / Cache Storage / OPFS are browser-only.
@TestOn('chrome')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:image_bytes_cache/src/environment_specific/image_bytes_blob_store_routed_js.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_bytes_web_keys.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

Future<void> _wipeDurableWebStorage() async {
  await web.window.caches.delete(ImageBytesWebKeys.indexCacheName).toDart;
  await web.window.caches.delete(ImageBytesWebKeys.blobsCacheName).toDart;
  final root = await web.window.navigator.storage.getDirectory().toDart;
  try {
    await root
        .removeEntry(
          ImageBytesWebKeys.opfsBlobsDirectoryName,
          web.FileSystemRemoveOptions(recursive: true),
        )
        .toDart;
  } on Object {
    // Missing directory is fine between tests.
  }
}

Future<bool> _cacheHas(ImageCacheKey key) async {
  final blobs = await web.window.caches.open(ImageBytesWebKeys.blobsCacheName).toDart;
  final match = await blobs.match(ImageBytesWebKeys.blobUrl(key).toJS).toDart;
  return match != null;
}

Future<bool> _opfsHas(ImageCacheKey key) async {
  final root = await web.window.navigator.storage.getDirectory().toDart;
  try {
    final dir = await root.getDirectoryHandle(ImageBytesWebKeys.opfsBlobsDirectoryName).toDart;
    await dir.getFileHandle(key.value).toDart;
    return true;
  } on Object {
    return false;
  }
}

Uint8List _filled(int length, int fill) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (fill + i) & 0xff;
  }
  return bytes;
}

void main() {
  tearDown(_wipeDurableWebStorage);

  group('ImageBytesCache.open (web)', () {
    test('directory argument is ignored and small payload round-trips via Cache API', () async {
      const key = ImageCacheKey('small_svg');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      final first = await ImageBytesCache.open(
        directory: '/ignored/on/web',
        retention: const ImageBytesRetention.unlimited(),
      );
      await first.write(key, bytes);
      await first.close();

      expect(await _cacheHas(key), isTrue);
      expect(await _opfsHas(key), isFalse);

      final second = await ImageBytesCache.open(
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(second.close);

      expect(await second.read(key), bytes);
    });

    test('payload at or above threshold round-trips via OPFS', () async {
      const key = ImageCacheKey('large_raster');
      final bytes = _filled(ImageBytesBlobStore$Routed$JS.opfsByteThreshold, 7);

      final first = await ImageBytesCache.open(
        retention: const ImageBytesRetention.unlimited(),
      );
      await first.write(key, bytes);
      await first.close();

      expect(await _opfsHas(key), isTrue);
      expect(await _cacheHas(key), isFalse);

      final second = await ImageBytesCache.open(
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(second.close);

      expect(await second.read(key), bytes);
    });

    test('rewrite across threshold moves the body between backends', () async {
      const key = ImageCacheKey('resize');
      final small = Uint8List.fromList([9, 8, 7]);
      final large = _filled(ImageBytesBlobStore$Routed$JS.opfsByteThreshold, 3);

      final cache = await ImageBytesCache.open(
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      await cache.write(key, small);
      expect(await _cacheHas(key), isTrue);
      expect(await _opfsHas(key), isFalse);

      await cache.write(key, large);
      expect(await _opfsHas(key), isTrue);
      expect(await _cacheHas(key), isFalse);
      expect(await cache.read(key), large);

      await cache.write(key, small);
      expect(await _cacheHas(key), isTrue);
      expect(await _opfsHas(key), isFalse);
      expect(await cache.read(key), small);
    });

    test('orphan Cache blob without index is reclaimed on open', () async {
      final blobs = await web.window.caches.open(ImageBytesWebKeys.blobsCacheName).toDart;
      await blobs
          .put(
            ImageBytesWebKeys.blobUrl(const ImageCacheKey('orphan')).toJS,
            web.Response(Uint8List.fromList([1, 2, 3]).toJS),
          )
          .toDart;

      final cache = await ImageBytesCache.open(
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const ImageCacheKey('orphan')), isNull);
      final leftover = await blobs.match(ImageBytesWebKeys.blobUrl(const ImageCacheKey('orphan')).toJS).toDart;
      expect(leftover, isNull);
    });

    test('orphan OPFS blob without index is reclaimed on open', () async {
      final root = await web.window.navigator.storage.getDirectory().toDart;
      final dir = await root
          .getDirectoryHandle(
            ImageBytesWebKeys.opfsBlobsDirectoryName,
            web.FileSystemGetDirectoryOptions(create: true),
          )
          .toDart;
      final handle = await dir
          .getFileHandle(
            'opfs_orphan',
            web.FileSystemGetFileOptions(create: true),
          )
          .toDart;
      final writable = await handle.createWritable().toDart;
      await writable.write(Uint8List.fromList([5, 5, 5]).toJS).toDart;
      await writable.close().toDart;

      final cache = await ImageBytesCache.open(
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const ImageCacheKey('opfs_orphan')), isNull);
      expect(await _opfsHas(const ImageCacheKey('opfs_orphan')), isFalse);
    });

    test('orphan blob without index is reclaimed on prune', () async {
      final cache = await ImageBytesCache.open(
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      await cache.write(const ImageCacheKey('kept'), Uint8List.fromList([4]));

      final blobs = await web.window.caches.open(ImageBytesWebKeys.blobsCacheName).toDart;
      await blobs
          .put(
            ImageBytesWebKeys.blobUrl(const ImageCacheKey('stray')).toJS,
            web.Response(Uint8List.fromList([5, 6]).toJS),
          )
          .toDart;

      await cache.prune();

      expect(await cache.read(const ImageCacheKey('kept')), Uint8List.fromList([4]));
      final leftover = await blobs.match(ImageBytesWebKeys.blobUrl(const ImageCacheKey('stray')).toJS).toDart;
      expect(leftover, isNull);
    });

    test('close is idempotent and rejects later ops', () async {
      final cache = await ImageBytesCache.open(
        retention: const ImageBytesRetention.unlimited(),
      );
      await cache.write(const ImageCacheKey('a'), Uint8List.fromList([1]));
      await cache.close();
      await cache.close();

      await expectLater(
        cache.read(const ImageCacheKey('a')),
        throwsA(isA<StateError>()),
      );
    });
  });
}
