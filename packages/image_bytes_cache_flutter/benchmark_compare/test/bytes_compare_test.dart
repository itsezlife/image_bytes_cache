import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/measure.dart';

import '../benchmark/bytes_compare.dart' as compare;

/// Flutter-test entry for the three-way bytes compare harness.
///
/// Not a CI merge gate — timings are machine-local. Passes when tables print
/// without throwing; sink keeps work observable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'three-way URL→bytes compare prints Markdown tables',
    () async {
      await compare.runBytesCompare();
      expect(measureSink, isNot(0x7fffffff));
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
