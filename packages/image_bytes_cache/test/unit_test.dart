import 'package:test/test.dart';

import 'cache/image_bytes_cache_test.dart' as image_bytes_cache_test;
import 'cache/indexed_image_bytes_cache_test.dart' as indexed_image_bytes_cache_test;
import 'open/image_bytes_cache_open_test.dart' as image_bytes_cache_open_test;
import 'resolve/http_bytes_fetcher_test.dart' as http_bytes_fetcher_test;
import 'resolve/image_bytes_resolver_test.dart' as image_bytes_resolver_test;
import 'storage/image_bytes_web_store_test.dart' as image_bytes_web_store_test;

/// Single aggregate entrypoint for VM unit + integration suites.
///
/// Chrome-only open coverage stays out of this file — run
/// `test/open/image_bytes_cache_open_web_test.dart` with `--platform chrome`.
void main() => group('Unit', () {
  image_bytes_cache_test.main();
  indexed_image_bytes_cache_test.main();
  image_bytes_cache_open_test.main();
  image_bytes_resolver_test.main();
  http_bytes_fetcher_test.main();
  image_bytes_web_store_test.main();
});
