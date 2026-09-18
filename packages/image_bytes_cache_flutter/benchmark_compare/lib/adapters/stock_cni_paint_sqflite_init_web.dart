/// Web stubs — stock CNI paint never initializes sqflite on web.
library;

void ensureSqfliteFfi() {
  throw UnsupportedError(
    'sqflite_ffi is VM-only; stock paint uses cache_manager defaults on web',
  );
}

Future<String> createTempRoot(String prefix) async {
  throw UnsupportedError('temp roots are VM-only ($prefix)');
}

Future<void> deleteRootIfExists(String path) async {}
