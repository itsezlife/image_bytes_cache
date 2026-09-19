// Benchmark entry lives under benchmark/ (not test/), so the analyzer does not
// treat @visibleForTesting shared resets as in-test use.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:test/test.dart';

import 'compare.dart';

/// Pure-Dart entry for store + ladder microbenches.
///
/// Not a correctness suite and not a CI merge gate. Prints paste-ready tables.
/// Optional `--dart-define=MEMORY_LANE=true` adds an RSS fill/prune table.
///
/// Process-wide shared cache / resolver / client are cleared around the suite
/// so a leaked configure from another harness cannot poison rows. Scenario
/// bodies use local instances only.
///
/// ```shell
/// dart test benchmark/compare_test.dart --dart-define=SAVE_BASELINE=true
/// dart test benchmark/compare_test.dart
/// dart test benchmark/compare_test.dart --dart-define=MEMORY_LANE=true
/// ```
void main() {
  setUp(() async {
    await ImageBytesCache.resetShared();
    HttpBytesClient.debugShared = null;
    ImageBytesResolver.debugShared = null;
  });

  tearDown(() async {
    await ImageBytesCache.resetShared();
    HttpBytesClient.debugShared = null;
    ImageBytesResolver.debugShared = null;
  });

  test(
    'image_bytes_cache store + ladder microbench',
    () async {
      await runCompare();
    },
    timeout: Timeout.none,
  );
}
