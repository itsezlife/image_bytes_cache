// Driver for the profile-mode image-feed benchmark.
//
// Collects TimelineSummary reportData from scroll_perf_test.dart into
// build/integration_response_data.json.
//
//   flutter drive \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/scroll_perf_test.dart \
//     --profile -d <device>
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
