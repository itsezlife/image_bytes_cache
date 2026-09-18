import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image_bytes_cache/src/environment_specific/image_bytes_blob_store_file_vm.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_bytes_diagnostics.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('image_bytes_cache_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ImageBytesCache.open (VM)', () {
    test('close then reopen returns committed bytes and meta', () async {
      const key = ImageCacheKey('logo');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      final first = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      await first.write(key, bytes);
      await first.close();

      final second = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(second.close);

      expect(await second.read(key), bytes);
    });

    test('multi-key mutate epoch survives close/reopen', () async {
      var now = DateTime.utc(2024, 1, 1);
      final first = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.maxEntries(2),
        clock: () => now,
      );

      await first.write(const ImageCacheKey('a'), Uint8List.fromList([1]));
      now = now.add(const Duration(seconds: 1));
      await first.write(const ImageCacheKey('b'), Uint8List.fromList([2]));
      now = now.add(const Duration(seconds: 1));
      await first.read(const ImageCacheKey('a'));
      now = now.add(const Duration(seconds: 1));
      // Soft-LRU flush + put c + delete b in one exclusive epoch / one commit.
      await first.write(const ImageCacheKey('c'), Uint8List.fromList([3]));
      await first.close();

      final second = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.maxEntries(2),
        clock: () => now,
      );
      addTearDown(second.close);

      expect(await second.read(const ImageCacheKey('a')), Uint8List.fromList([1]));
      expect(await second.read(const ImageCacheKey('b')), isNull);
      expect(await second.read(const ImageCacheKey('c')), Uint8List.fromList([3]));
      expect(
        File(p.join(tempDir.path, ImageBytesBlobStore$File$VM.indexFileName)).existsSync(),
        isTrue,
      );
    });

    test('large write round-trips after close/reopen', () async {
      const key = ImageCacheKey('raster');
      final bytes = Uint8List(96 * 1024);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = i & 0xff;
      }

      final first = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      await first.write(key, bytes);
      await first.close();

      final second = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(second.close);

      expect(await second.read(key), bytes);
    });

    test('open failure degrades to memory and reports a warning', () async {
      final blocker = File(p.join(tempDir.path, 'not_a_directory'))..writeAsBytesSync([1]);
      final events = <ImageBytesLogEvent>[];

      final cache = await ImageBytesCache.open(
        directory: p.join(blocker.path, 'nested'),
        retention: const ImageBytesRetention.unlimited(),
        diagnostics: ImageBytesDiagnostics.onEvent(events.add),
      );
      addTearDown(cache.close);

      expect(cache, isA<MemoryImageBytesCache>());
      expect(events, hasLength(1));
      expect(events.single.level, ImageBytesLogLevel.warning);
      expect(events.single.op, ImageBytesLogOp.openDegraded);

      const key = ImageCacheKey('in_memory');
      final bytes = Uint8List.fromList([9]);
      await cache.write(key, bytes);
      expect(await cache.read(key), bytes);
    });

    test('open failure throws when throwOnOpenFailure is true', () async {
      final blocker = File(p.join(tempDir.path, 'not_a_directory'))..writeAsBytesSync([1]);

      await expectLater(
        ImageBytesCache.open(
          directory: p.join(blocker.path, 'nested'),
          throwOnOpenFailure: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('missing VM directory throws ArgumentError without degrading', () async {
      await expectLater(
        ImageBytesCache.open(directory: null),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        ImageBytesCache.open(directory: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('soft LRU: capacity trim after read flush on write', () async {
      var now = DateTime.utc(2024, 1, 1);
      final cache = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.maxEntries(2),
        clock: () => now,
      );
      addTearDown(cache.close);

      await cache.write(const ImageCacheKey('a'), Uint8List.fromList([1]));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const ImageCacheKey('b'), Uint8List.fromList([2]));
      now = now.add(const Duration(seconds: 1));
      await cache.read(const ImageCacheKey('a'));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const ImageCacheKey('c'), Uint8List.fromList([3]));

      expect(await cache.read(const ImageCacheKey('a')), Uint8List.fromList([1]));
      expect(await cache.read(const ImageCacheKey('b')), isNull);
      expect(await cache.read(const ImageCacheKey('c')), Uint8List.fromList([3]));
    });

    test('orphan blob without index is reclaimed on open', () async {
      File(p.join(tempDir.path, 'orphan')).writeAsBytesSync([1, 2, 3]);

      final cache = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(File(p.join(tempDir.path, 'orphan')).existsSync(), isFalse);
      expect(await cache.read(const ImageCacheKey('orphan')), isNull);
    });

    test('orphan blob without index is reclaimed on prune', () async {
      final cache = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      await cache.write(const ImageCacheKey('kept'), Uint8List.fromList([4]));
      File(p.join(tempDir.path, 'stray')).writeAsBytesSync([5, 6]);

      await cache.prune();

      expect(File(p.join(tempDir.path, 'stray')).existsSync(), isFalse);
      expect(await cache.read(const ImageCacheKey('kept')), Uint8List.fromList([4]));
    });

    test('temp-only blob file is not a cache hit', () async {
      File(p.join(tempDir.path, 'logo.tmp')).writeAsBytesSync([1, 2, 3]);

      final cache = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const ImageCacheKey('logo')), isNull);
    });

    test('corrupt index recovers by wiping without crash-looping', () async {
      File(p.join(tempDir.path, ImageBytesBlobStore$File$VM.indexFileName)).writeAsBytesSync(
        const Utf8Encoder().convert('not-json'),
      );
      File(p.join(tempDir.path, 'stale')).writeAsBytesSync([9]);

      final cache = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const ImageCacheKey('stale')), isNull);
      expect(File(p.join(tempDir.path, 'stale')).existsSync(), isFalse);

      const key = ImageCacheKey('fresh');
      final bytes = Uint8List.fromList([1, 2]);
      await cache.write(key, bytes);
      expect(await cache.read(key), bytes);
    });

    test('unrecognized index version recovers by wiping', () async {
      File(p.join(tempDir.path, ImageBytesBlobStore$File$VM.indexFileName)).writeAsBytesSync(
        const JsonEncoder().fuse(const Utf8Encoder()).convert({
          'v': 99,
          'e': {
            'old': {'w': 1, 'a': 1, 'n': 1},
          },
        }),
      );
      File(p.join(tempDir.path, 'old')).writeAsBytesSync([7]);

      final cache = await ImageBytesCache.open(
        directory: tempDir.path,
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const ImageCacheKey('old')), isNull);
      expect(File(p.join(tempDir.path, 'old')).existsSync(), isFalse);
    });

    test('close is idempotent and rejects later ops', () async {
      final cache = await ImageBytesCache.open(
        directory: tempDir.path,
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
