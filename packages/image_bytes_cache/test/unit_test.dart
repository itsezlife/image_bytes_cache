import 'package:test/test.dart';

import 'cache/cache_test.dart' as cache_test;
import 'cache/indexed_cache_test.dart' as indexed_cache_test;
import 'open/open_test.dart' as open_test;
import 'resolve/bearer_middleware_test.dart' as bearer_middleware_test;
import 'resolve/fetcher_test.dart' as fetcher_test;
import 'resolve/pipeline_test.dart' as pipeline_test;
import 'resolve/resolver_test.dart' as resolver_test;
import 'storage/blob_store_vm_test.dart' as blob_store_vm_test;
import 'storage/web_store_test.dart' as web_store_test;

/// Single aggregate entrypoint for VM unit + integration suites.
///
/// Chrome-only open coverage stays out of this file — run
/// `test/open/open_web_test.dart` with `--platform chrome`.
void main() => group('Unit', () {
  cache_test.main();
  indexed_cache_test.main();
  open_test.main();
  resolver_test.main();
  fetcher_test.main();
  pipeline_test.main();
  bearer_middleware_test.main();
  blob_store_vm_test.main();
  web_store_test.main();
});
