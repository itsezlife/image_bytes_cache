/// Warmup + calibrate + min-of-batches timing for async bytes-ready ops.
library;

import 'dart:typed_data';

/// DCE guard — accumulate a byte of each result so work cannot be optimized away.
int measureSink = 0;

/// Minimum per-op microseconds for [op] after warmup and batch calibration.
///
/// Optional [beforeEach] runs before every timed [op] (and during warmup) but
/// is excluded from the stopwatch — use it to force a cold cache without
/// folding eviction into the measured path.
Future<double> measureUsPerOp(
  Future<int> Function() op, {
  Future<void> Function()? beforeEach,
  int warmupMs = 200,
  int batches = 25,
  int minBatchMs = 8,
}) async {
  final warmupSw = Stopwatch()..start();
  while (warmupSw.elapsedMilliseconds < warmupMs) {
    await beforeEach?.call();
    measureSink ^= await op();
  }

  var iters = 1;
  while (true) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < iters; i++) {
      await beforeEach?.call();
      // beforeEach is inside the calibrate loop intentionally: we only need a
      // batch long enough; absolute calibrate time need not be pure op cost.
      measureSink ^= await op();
    }
    sw.stop();
    if (sw.elapsedMicroseconds >= minBatchMs * 1000) break;
    iters = iters < 2 ? 2 : (iters * 2);
    if (iters > 1 << 16) break;
  }

  var best = double.infinity;
  for (var b = 0; b < batches; b++) {
    var totalUs = 0;
    for (var i = 0; i < iters; i++) {
      await beforeEach?.call();
      final sw = Stopwatch()..start();
      measureSink ^= await op();
      sw.stop();
      totalUs += sw.elapsedMicroseconds;
    }
    final us = totalUs / iters;
    if (us < best) best = us;
  }
  return best;
}

/// XOR of payload bytes for the measure sink (keeps reads observable).
int sinkBytes(Uint8List? bytes) => switch (bytes) {
  final b? when b.isNotEmpty => _hashBytes(b),
  _ => 0,
};

int _hashBytes(Uint8List bytes) {
  var h = bytes.length;
  final step = bytes.length < 64 ? 1 : bytes.length ~/ 64;
  for (var i = 0; i < bytes.length; i += step) {
    h = (h * 31) ^ bytes[i];
  }
  return h;
}
