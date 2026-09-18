import 'dart:typed_data';

import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('IndexedImageBytesCache', () {
    late _FakeIndex index;
    late _FakeBlobs blobs;
    late IndexedImageBytesCache cache;
    late DateTime now;

    setUp(() {
      now = DateTime.utc(2024, 1, 1, 12);
      index = _FakeIndex();
      blobs = _FakeBlobs();
      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.unlimited(),
        clock: () => now,
      );
    });

    test('write then read returns the same bytes', () async {
      const key = ImageCacheKey('logo');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      await cache.write(key, bytes);

      expect(await cache.read(key), bytes);
      expect(blobs.store[key.value], bytes);
      expect(index.records[key.value]?.byteLength, 4);
    });

    test('empty write is not retained as capacity waste', () async {
      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.maxEntries(1),
        clock: () => now,
      );
      const emptyKey = ImageCacheKey('empty');
      const keepKey = ImageCacheKey('keep');

      await cache.write(emptyKey, Uint8List(0));
      expect(await cache.read(emptyKey), isNull);
      expect(blobs.store.containsKey(emptyKey.value), isFalse);
      expect(index.records.containsKey(emptyKey.value), isFalse);

      await cache.write(keepKey, Uint8List.fromList([1]));
      expect(await cache.read(keepKey), Uint8List.fromList([1]));
    });

    test('empty write evicts a previously stored payload for the same key', () async {
      const key = ImageCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1, 2]));

      await cache.write(key, Uint8List(0));

      expect(await cache.read(key), isNull);
      expect(blobs.store.containsKey(key.value), isFalse);
      expect(index.records.containsKey(key.value), isFalse);
    });

    test('read of sticky empty payload misses and scrubs the entry', () async {
      const key = ImageCacheKey('sticky');
      // Simulate a legacy empty durable row that predates empty-write rejection.
      blobs.store[key.value] = Uint8List(0);
      index.records[key.value] = ImageBytesRecord(
        key: key,
        writtenAt: now,
        accessedAt: now,
        byteLength: 0,
      );

      expect(await cache.read(key), isNull);
      expect(blobs.store.containsKey(key.value), isFalse);
      expect(index.records.containsKey(key.value), isFalse);
    });

    test('read does not persist access to the index (soft LRU)', () async {
      const key = ImageCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1]));
      final putsBefore = index.putCount;
      final commitsBefore = index.commitCount;
      now = now.add(const Duration(seconds: 5));

      await cache.read(key);

      expect(index.putCount, putsBefore);
      expect(index.commitCount, commitsBefore);
      expect(index.records[key.value]?.accessedAt, DateTime.utc(2024, 1, 1, 12));
    });

    test('soft-LRU flush + capacity trim in one write commits meta once', () async {
      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.maxEntries(2),
        clock: () => now,
      );

      await cache.write(const ImageCacheKey('a'), Uint8List.fromList([1]));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const ImageCacheKey('b'), Uint8List.fromList([2]));
      now = now.add(const Duration(seconds: 1));
      await cache.read(const ImageCacheKey('a'));
      now = now.add(const Duration(seconds: 1));
      final commitsBefore = index.commitCount;

      await cache.write(const ImageCacheKey('c'), Uint8List.fromList([3]));

      // Flush touches a, put c, delete b: many RAM puts/deletes, one durable commit.
      expect(index.commitCount, commitsBefore + 1);
      expect(index.putCount, greaterThan(1));
    });

    test('concurrent reads overlap when no mutate is in flight', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      blobs.readHook = () async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        inFlight--;
      };

      await cache.write(const ImageCacheKey('a'), Uint8List.fromList([1]));
      await cache.write(const ImageCacheKey('b'), Uint8List.fromList([2]));

      final results = await (
        cache.read(const ImageCacheKey('a')),
        cache.read(const ImageCacheKey('b')),
      ).wait;

      expect(results.$1, Uint8List.fromList([1]));
      expect(results.$2, Uint8List.fromList([2]));
      expect(maxInFlight, greaterThan(1));
    });

    test('TTL cleanup re-checks under exclusive so a racing write survives', () async {
      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.maxAge(Duration(hours: 1)),
        clock: () => now,
      );
      const key = ImageCacheKey('race-ttl');
      await cache.write(key, Uint8List.fromList([1]));
      now = now.add(const Duration(hours: 2));
      index.opDelay = const Duration(milliseconds: 10);
      blobs.opDelay = const Duration(milliseconds: 10);

      // Shared probe sees expired while write waits for readers; write refreshes
      // before the exclusive cleanup. Without re-check, cleanup would tear the
      // refreshed pair.
      await (
        cache.read(key),
        cache.write(key, Uint8List.fromList([9, 9])),
      ).wait;

      expect(await cache.read(key), Uint8List.fromList([9, 9]));
      expect(index.records.containsKey(key.value), isTrue);
      expect(blobs.store[key.value], Uint8List.fromList([9, 9]));
    });

    test('reclaim and write cannot tear an index/blob pair', () async {
      const orphanKey = ImageCacheKey('orphan-blob');
      blobs.store[orphanKey.value] = Uint8List.fromList([7]);
      blobs.opDelay = const Duration(milliseconds: 20);
      index.opDelay = const Duration(milliseconds: 20);

      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.unlimited(),
        clock: () => now,
        reclaimOrphans: blobs.reclaimOrphans,
      );

      const liveKey = ImageCacheKey('live');
      final liveBytes = Uint8List.fromList([1, 2, 3]);

      await (
        cache.write(liveKey, liveBytes),
        cache.reclaimOrphans(),
      ).wait;

      expect(await cache.read(liveKey), liveBytes);
      expect(index.records.containsKey(liveKey.value), isTrue);
      expect(blobs.store.containsKey(liveKey.value), isTrue);
      expect(blobs.store.containsKey(orphanKey.value), isFalse);
    });

    test('write flushes pending access before capacity trim', () async {
      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.maxEntries(2),
        clock: () => now,
      );

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

    test('TTL: read after maxAge returns null and deletes both stores', () async {
      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.maxAge(Duration(hours: 1)),
        clock: () => now,
      );
      const key = ImageCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1]));
      now = now.add(const Duration(hours: 2));

      expect(await cache.read(key), isNull);
      expect(index.records.containsKey(key.value), isFalse);
      expect(blobs.store.containsKey(key.value), isFalse);
    });

    test('prune removes expired entries', () async {
      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.maxAge(Duration(days: 1)),
        clock: () => now,
      );
      await cache.write(const ImageCacheKey('old'), Uint8List.fromList([1]));
      now = now.add(const Duration(days: 2));
      await cache.write(const ImageCacheKey('fresh'), Uint8List.fromList([2]));

      final report = await cache.prune();

      expect(report.evictedKeys, [const ImageCacheKey('old')]);
      expect(await cache.read(const ImageCacheKey('old')), isNull);
      expect(
        await cache.read(const ImageCacheKey('fresh')),
        Uint8List.fromList([2]),
      );
    });

    test('evict removes index and blob', () async {
      const key = ImageCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1]));

      await cache.evict(key);

      expect(await cache.read(key), isNull);
      expect(index.records.containsKey(key.value), isFalse);
      expect(blobs.store.containsKey(key.value), isFalse);
    });

    test('orphan index without blob is cleaned on read', () async {
      const key = ImageCacheKey('orphan');
      await index.put(
        ImageBytesRecord(
          key: key,
          writtenAt: now,
          accessedAt: now,
          byteLength: 1,
        ),
      );

      expect(await cache.read(key), isNull);
      expect(index.records.containsKey(key.value), isFalse);
    });

    test('maxBytes: write evicts LRU after soft-access flush', () async {
      cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.maxBytes(5),
        clock: () => now,
      );

      await cache.write(const ImageCacheKey('a'), Uint8List.fromList([1, 2]));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const ImageCacheKey('b'), Uint8List.fromList([3, 4]));
      now = now.add(const Duration(seconds: 1));
      await cache.read(const ImageCacheKey('a'));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const ImageCacheKey('c'), Uint8List.fromList([5, 6]));

      expect(await cache.read(const ImageCacheKey('a')), Uint8List.fromList([1, 2]));
      expect(await cache.read(const ImageCacheKey('b')), isNull);
      expect(await cache.read(const ImageCacheKey('c')), Uint8List.fromList([5, 6]));
    });

    test('concurrent mutate leaves index and blob pairs intact', () async {
      index.opDelay = const Duration(milliseconds: 5);
      blobs.opDelay = const Duration(milliseconds: 5);
      const key = ImageCacheKey('race');
      final bytes = Uint8List.fromList([9, 9, 9]);

      await Future.wait([
        cache.write(key, bytes),
        cache.evict(key),
        cache.write(key, bytes),
        cache.prune(),
      ]);

      final hasIndex = index.records.containsKey(key.value);
      final hasBlob = blobs.store.containsKey(key.value);
      expect(hasIndex, hasBlob);
      if (hasIndex) {
        expect(blobs.store[key.value], bytes);
        expect(index.records[key.value]?.byteLength, bytes.length);
      }
    });

    test('close is idempotent and rejects later operations', () async {
      await cache.write(const ImageCacheKey('logo'), Uint8List.fromList([1]));
      await cache.close();
      await cache.close();

      await expectLater(
        cache.read(const ImageCacheKey('logo')),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        cache.write(const ImageCacheKey('logo'), Uint8List.fromList([2])),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        cache.evict(const ImageCacheKey('logo')),
        throwsA(isA<StateError>()),
      );
      await expectLater(cache.prune(), throwsA(isA<StateError>()));
    });

    test('commit failure rolls RAM back — no optimistic durable hit', () async {
      const priorKey = ImageCacheKey('prior');
      const failedKey = ImageCacheKey('failed');
      final priorBytes = Uint8List.fromList([1, 1]);
      final failedBytes = Uint8List.fromList([2, 2, 2]);

      await cache.write(priorKey, priorBytes);
      index.commitError = StateError('durable index commit failed');

      await expectLater(cache.write(failedKey, failedBytes), throwsA(isA<StateError>()));

      // Must not treat the optimistic RAM put as a durable hit.
      expect(await cache.read(failedKey), isNull);
      expect(index.records.containsKey(failedKey.value), isFalse);
      // Last good commit snapshot stays readable.
      expect(await cache.read(priorKey), priorBytes);
      expect(index.records.containsKey(priorKey.value), isTrue);
    });

    test('commit failure on evict restores the index row', () async {
      const key = ImageCacheKey('keep');
      final bytes = Uint8List.fromList([7]);
      await cache.write(key, bytes);
      index.commitError = StateError('durable index commit failed');

      await expectLater(cache.evict(key), throwsA(isA<StateError>()));

      // Blob may already be gone. Index must not stay deleted after a failed
      // commit as if durable eviction had succeeded. Restore last-good meta
      // so the store does not claim the eviction completed.
      expect(index.records.containsKey(key.value), isTrue);
    });
  });
}

final class _FakeIndex implements IImageBytesIndex {
  final Map<String, ImageBytesRecord> records = {};
  int putCount = 0;
  int commitCount = 0;
  Duration opDelay = Duration.zero;
  Error? commitError;

  Future<void> _delay() async {
    if (opDelay > Duration.zero) {
      await Future<void>.delayed(opDelay);
    }
  }

  @override
  Future<ImageBytesRecord?> get(ImageCacheKey key) async {
    await _delay();
    return records[key.value];
  }

  @override
  Future<void> put(ImageBytesRecord record) async {
    await _delay();
    putCount++;
    records[record.key.value] = record;
  }

  @override
  Future<void> delete(ImageCacheKey key) async {
    await _delay();
    records.remove(key.value);
  }

  @override
  Future<Iterable<ImageBytesRecord>> values() async {
    await _delay();
    return records.values;
  }

  @override
  Future<void> commit() async {
    await _delay();
    final error = commitError;
    if (error != null) {
      throw error;
    }
    commitCount++;
  }
}

final class _FakeBlobs implements IImageBytesBlobStore {
  final Map<String, Uint8List> store = {};
  Duration opDelay = Duration.zero;
  Future<void> Function()? readHook;

  Future<void> _delay() async {
    if (opDelay > Duration.zero) {
      await Future<void>.delayed(opDelay);
    }
  }

  @override
  Future<Uint8List?> read(ImageCacheKey key) async {
    await readHook?.call();
    await _delay();
    return store[key.value];
  }

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) async {
    await _delay();
    store[key.value] = bytes;
  }

  @override
  Future<void> delete(ImageCacheKey key) async {
    await _delay();
    store.remove(key.value);
  }

  Future<void> reclaimOrphans(Set<String> indexedKeys) async {
    await _delay();
    store.removeWhere((key, _) => !indexedKeys.contains(key));
  }
}
