/// Named bytes-ready scenarios shared across adapters.
library;

import 'package:image_bytes_cache_benchmark_compare/adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ours_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/corpus.dart';
import 'package:image_bytes_cache_benchmark_compare/measure.dart';

/// Fan-out for same-URL burst coalesce visibility.
const int burstFanOut = 8;

/// Distinct keys in the many-keys grid.
const int manyKeyCount = 16;

/// One timed row: cold miss, warm hit, burst, or many distinct keys.
final class BytesScenario {
  /// Creates a scenario.
  const BytesScenario({
    required this.name,
    required this.payloadClass,
    required this.bytes,
    required this.run,
    this.seed,
    this.beforeEach,
    this.responseDelay = Duration.zero,
  });

  /// Row name printed in Markdown tables.
  final String name;

  /// Size class for the corpus bodies.
  final PayloadClass payloadClass;

  /// Payload length (or per-key length for grids).
  final int bytes;

  /// Optional one-shot setup before warmup (e.g. seed a warm cache).
  final Future<void> Function(IBytesReadyAdapter adapter)? seed;

  /// Runs before each timed [run] but outside the stopwatch (e.g. force miss).
  final Future<void> Function(IBytesReadyAdapter adapter)? beforeEach;

  /// HTTP delay applied when opening adapters for this row (burst overlap).
  final Duration responseDelay;

  /// Runs one timed op against [adapter]; returns sink bits.
  final Future<int> Function(IBytesReadyAdapter adapter) run;
}

/// Primary scenario set for the bytes tables.
List<BytesScenario> bytesScenarios() {
  final small = payloadFor(PayloadClass.small);
  final large = payloadFor(PayloadClass.large);
  return [
    _coldMiss('cold_miss_small', PayloadClass.small, small.length),
    _coldMiss('cold_miss_large', PayloadClass.large, large.length),
    _warmHit('warm_hit_small', PayloadClass.small, small.length),
    _warmHit('warm_hit_large', PayloadClass.large, large.length),
    _sameUrlBurst('same_url_burst_small', PayloadClass.small, small.length),
    _manyKeys('many_distinct_keys_small', PayloadClass.small, small.length),
  ];
}

BytesScenario _coldMiss(String name, PayloadClass klass, int bytes) {
  final url = urlFor(klass);
  return BytesScenario(
    name: name,
    payloadClass: klass,
    bytes: bytes,
    beforeEach: (adapter) => adapter.evict(url),
    run: (adapter) async => sinkBytes(await adapter.getBytes(url)),
  );
}

BytesScenario _warmHit(String name, PayloadClass klass, int bytes) {
  final url = urlFor(klass);
  return BytesScenario(
    name: name,
    payloadClass: klass,
    bytes: bytes,
    seed: (adapter) async {
      await adapter.evict(url);
      await adapter.getBytes(url);
      await awaitOursWriteThrough(adapter, url);
    },
    run: (adapter) async => sinkBytes(await adapter.getBytes(url)),
  );
}

BytesScenario _sameUrlBurst(String name, PayloadClass klass, int bytes) {
  final url = urlFor(klass);
  return BytesScenario(
    name: name,
    payloadClass: klass,
    bytes: bytes,
    responseDelay: const Duration(milliseconds: 1),
    beforeEach: (adapter) => adapter.evict(url),
    run: (adapter) async {
      final results = await Future.wait([
        for (var i = 0; i < burstFanOut; i++) adapter.getBytes(url),
      ]);
      var sink = 0;
      for (final body in results) {
        sink ^= sinkBytes(body);
      }
      return sink;
    },
  );
}

BytesScenario _manyKeys(String name, PayloadClass klass, int bytes) {
  return BytesScenario(
    name: name,
    payloadClass: klass,
    bytes: bytes,
    beforeEach: (adapter) async {
      for (var i = 0; i < manyKeyCount; i++) {
        await adapter.evict(urlFor(klass, slot: i));
      }
    },
    run: (adapter) async {
      final urls = [
        for (var i = 0; i < manyKeyCount; i++) urlFor(klass, slot: i),
      ];
      final results = await Future.wait(urls.map(adapter.getBytes));
      var sink = 0;
      for (final body in results) {
        sink ^= sinkBytes(body);
      }
      return sink;
    },
  );
}
