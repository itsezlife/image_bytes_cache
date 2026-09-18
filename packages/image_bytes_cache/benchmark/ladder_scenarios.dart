import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

import 'payloads.dart';
import 'scenarios.dart';
import 'sink.dart';

/// Resolve-ladder microbench rows (fake HTTP, no public internet).
///
/// Each [StoreScenario.prepare] owns a local [MemoryImageBytesCache] and
/// [HttpBytesFetcher] — never [ImageBytesCache.shared] /
/// [ImageBytesResolver.shared] / [HttpBytesFetcher.shared]. The compare test
/// entry resets process-wide shareds around the suite so a leaked configure
/// from another harness cannot poison rows.
List<StoreScenario> ladderScenarios() {
  final small = payloadOf(smallBytes);
  return [
    _missThenHit('ladder_miss_then_hit_small', small),
    _sameUrlBurst('ladder_same_url_burst_small', small),
    _distinctKeyGrid('ladder_distinct_grid_small', small),
  ];
}

const _burstFanOut = 8;
const _gridKeys = 8;
const _gridMaxConcurrent = 2;

/// Optional RSS lane around fill-to-[ImageBytesRetention.standard] capacity
/// and prune. Not timed for us/op; printed separately. See [runMemoryLane].
///
/// Caveats (document in tables/docs): [ProcessInfo.currentRss] is process-wide
/// (includes VM heap, isolates, OS allocator freelists). GC timing and OS
/// reclaim make absolute bytes noisy; use before/after deltas on one machine
/// only. Not a baseline key and not a CI gate.
Future<MemoryLaneReport> runMemoryLane() async {
  final payload = payloadOf(smallBytes);
  final maxEntries = ImageBytesRetention.standard.limits.maxEntries!;
  final maxAge = ImageBytesRetention.standard.limits.maxAge!;
  // Injectable clock so prune can drop the filled set after we advance past
  // standard maxAge (a same-instant prune at exact capacity frees nothing).
  var now = DateTime.utc(2024, 1, 1);
  final cache = MemoryImageBytesCache(
    retention: ImageBytesRetention.standard,
    clock: () => now,
  );

  final beforeFillRss = ProcessInfo.currentRss;
  for (var i = 0; i < maxEntries; i++) {
    await cache.write(ImageCacheKey('fill_$i'), payload);
  }
  // Touch every key so soft-LRU and warm-read paths are exercised before prune.
  var warmSink = 0;
  for (var i = 0; i < maxEntries; i++) {
    warmSink ^= sinkBytes(await cache.read(ImageCacheKey('fill_$i')));
  }
  final afterFillRss = ProcessInfo.currentRss;

  now = now.add(maxAge).add(const Duration(seconds: 1));
  final pruneReport = await cache.prune();
  final afterPruneRss = ProcessInfo.currentRss;

  await cache.close();

  // Keep warm reads observable to the optimizer.
  if (warmSink == 0x7fffffff) {
    stderr.writeln('(unreachable memory-lane sink)');
  }

  return MemoryLaneReport(
    beforeFillRss: beforeFillRss,
    afterFillRss: afterFillRss,
    afterPruneRss: afterPruneRss,
    filledEntries: maxEntries,
    payloadBytes: payload.length,
    pruneFreedBytes: pruneReport.freedBytes,
    pruneEvicted: pruneReport.evictedKeys.length,
  );
}

/// Snapshot trio from [runMemoryLane].
final class MemoryLaneReport {
  /// Creates a memory-lane report.
  const MemoryLaneReport({
    required this.beforeFillRss,
    required this.afterFillRss,
    required this.afterPruneRss,
    required this.filledEntries,
    required this.payloadBytes,
    required this.pruneFreedBytes,
    required this.pruneEvicted,
  });

  /// [ProcessInfo.currentRss] before writing [filledEntries] keys.
  final int beforeFillRss;

  /// RSS after fill + many-key warm reads.
  final int afterFillRss;

  /// RSS after [IImageBytesCache.prune].
  final int afterPruneRss;

  /// Keys written (standard [ImageBytesRetention] maxEntries).
  final int filledEntries;

  /// Body size per key.
  final int payloadBytes;

  /// [ImageBytesPruneReport.freedBytes] from the timed prune.
  final int pruneFreedBytes;

  /// Evicted key count from prune.
  final int pruneEvicted;
}

StoreScenario _missThenHit(String name, Uint8List payload) => StoreScenario(
  name: name,
  bytes: payload.length,
  prepare: () async {
    final harness = _openLadder(payload: payload);
    const url = 'https://bench.invalid/miss-hit.svg';
    final key = ImageCacheKey.fromUrl(url);
    const request = ImageBytesRequest(url: url);
    return PreparedScenario(
      op: () async {
        // Each iteration starts cold so miss→write-through→hit stays honest
        // across calibrated batches (a warm cache would skip the network).
        await harness.cache.evict(key);
        final miss = await harness.resolver.resolve(request);
        await _awaitWriteThrough(harness.cache, key);
        final hit = await harness.resolver.resolve(request);
        return sinkBytes(miss) ^ sinkBytes(hit);
      },
      dispose: harness.dispose,
    );
  },
);

StoreScenario _sameUrlBurst(String name, Uint8List payload) => StoreScenario(
  name: name,
  bytes: payload.length,
  prepare: () async {
    // Small delay so concurrent callers overlap while the first GET is open;
    // coalesce must collapse them to one MockClient hit.
    final harness = _openLadder(
      payload: payload,
      responseDelay: const Duration(milliseconds: 1),
    );
    const url = 'https://bench.invalid/burst.svg';
    final key = ImageCacheKey.fromUrl(url);
    const request = ImageBytesRequest(url: url);
    return PreparedScenario(
      op: () async {
        await harness.cache.evict(key);
        final results = await Future.wait([
          for (var i = 0; i < _burstFanOut; i++) harness.resolver.resolve(request),
        ]);
        var sink = 0;
        for (final bytes in results) {
          sink ^= sinkBytes(bytes);
        }
        return sink ^ harness.fetchCount();
      },
      dispose: harness.dispose,
    );
  },
);

StoreScenario _distinctKeyGrid(String name, Uint8List payload) => StoreScenario(
  name: name,
  bytes: payload.length,
  prepare: () async {
    final harness = _openLadder(
      payload: payload,
      maxConcurrent: _gridMaxConcurrent,
    );
    var generation = 0;
    return PreparedScenario(
      op: () async {
        final g = generation++;
        final requests = <ImageBytesRequest>[
          for (var i = 0; i < _gridKeys; i++) ImageBytesRequest(url: 'https://bench.invalid/grid/$g/$i.svg'),
        ];
        final results = await Future.wait(
          requests.map(harness.resolver.resolve),
        );
        var sink = 0;
        for (final bytes in results) {
          sink ^= sinkBytes(bytes);
        }
        return sink ^ harness.fetchCount();
      },
      dispose: harness.dispose,
    );
  },
);

({
  IImageBytesCache cache,
  ImageBytesResolver resolver,
  HttpBytesFetcher fetcher,
  int Function() fetchCount,
  Future<void> Function() dispose,
})
_openLadder({
  required Uint8List payload,
  int maxConcurrent = 6,
  Duration responseDelay = Duration.zero,
}) {
  var fetches = 0;
  final client = MockClient((request) async {
    fetches++;
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    return http.Response.bytes(payload, 200);
  });
  final fetcher = HttpBytesFetcher(
    client: client,
    maxConcurrent: maxConcurrent,
  );
  final cache = MemoryImageBytesCache(retention: ImageBytesRetention.standard);
  final resolver = ImageBytesResolver(cache: cache, fetcher: fetcher);
  return (
    cache: cache,
    resolver: resolver,
    fetcher: fetcher,
    fetchCount: () => fetches,
    dispose: () async {
      await fetcher.close();
      await cache.close();
    },
  );
}

/// Waits until fire-and-forget write-through has landed a non-empty body.
Future<void> _awaitWriteThrough(IImageBytesCache cache, ImageCacheKey key) async {
  for (var i = 0; i < 2000; i++) {
    final bytes = await cache.read(key);
    if (bytes != null && bytes.isNotEmpty) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('write-through did not land for ${key.value}');
}
