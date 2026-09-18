import 'dart:io';
import 'dart:typed_data';

import 'package:image_bytes_cache/src/environment_specific/image_bytes_blob_store_file_vm.dart';
import 'package:image_bytes_cache/src/environment_specific/image_bytes_index_file_vm.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('image_bytes_blob_vm_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group(r'ImageBytesBlobStore$File$VM isolate death', () {
    test('pending RPC fails when the worker is killed (no hang)', () async {
      final store = ImageBytesBlobStore$File$VM(directory: tempDir.path);
      addTearDown(store.close);
      await store.ensureDirectory();

      final fifoPath = p.join(tempDir.path, 'block.fifo');
      final mkfifo = await Process.run('mkfifo', [fifoPath]);
      expect(mkfifo.exitCode, 0, reason: '${mkfifo.stderr}');

      final pending = store.readPath(fifoPath);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Listen before kill so completeError is not an unhandled async error.
      final failed = expectLater(
        pending.timeout(const Duration(seconds: 2)),
        throwsA(isA<StateError>()),
      );
      store.debugKillWorker();
      await _releaseFifo(fifoPath);
      await failed;
    });

    test('after worker death, a later op respawns and succeeds', () async {
      final store = ImageBytesBlobStore$File$VM(directory: tempDir.path);
      addTearDown(store.close);
      await store.ensureDirectory();

      final fifoPath = p.join(tempDir.path, 'block.fifo');
      expect((await Process.run('mkfifo', [fifoPath])).exitCode, 0);

      final pending = store.readPath(fifoPath);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final failed = expectLater(
        pending.timeout(const Duration(seconds: 2)),
        throwsA(isA<StateError>()),
      );
      store.debugKillWorker();
      await _releaseFifo(fifoPath);
      await failed;

      final path = p.join(tempDir.path, 'ok.bin');
      final bytes = Uint8List.fromList([7, 8, 9]);
      await store.writePathAtomic(path, bytes).timeout(const Duration(seconds: 2));
      expect(await store.readPath(path), bytes);
    });

    test('dead worker mid-read does not stall the exclusive mutate gate', () async {
      final blobs = ImageBytesBlobStore$File$VM(directory: tempDir.path);
      addTearDown(blobs.close);
      await blobs.ensureDirectory();
      final index = await ImageBytesIndex$File$VM.open(
        directory: tempDir.path,
        io: blobs,
        onWipe: blobs.wipeAll,
      );
      final cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      const hungKey = ImageCacheKey('hung');
      const okKey = ImageCacheKey('ok');
      final payload = Uint8List.fromList([1, 2, 3]);
      await cache.write(hungKey, payload);

      final blobPath = p.join(tempDir.path, hungKey.value);
      File(blobPath).deleteSync();
      expect((await Process.run('mkfifo', [blobPath])).exitCode, 0);

      final hungRead = cache.read(hungKey);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Exclusive write waits for the shared reader that is blocked on the FIFO.
      final nextWrite = cache.write(okKey, Uint8List.fromList([9]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final failedRead = expectLater(
        hungRead.timeout(const Duration(seconds: 2)),
        throwsA(isA<StateError>()),
      );
      blobs.debugKillWorker();
      await _releaseFifo(blobPath);
      await failedRead;
      await nextWrite.timeout(const Duration(seconds: 2));
      expect(await cache.read(okKey), Uint8List.fromList([9]));
    });
  });
}

/// Unblocks a worker stuck in sync FIFO read so [Isolate.kill] can reap it.
///
/// Kill alone does not interrupt a blocking `readAsBytesSync` on a FIFO; the
/// test runner then hangs waiting for the isolate to check in.
Future<void> _releaseFifo(String path) async {
  try {
    await (File(path).openWrite()..add(const [0])).close();
  } on Object {
    // Reader already gone or path removed.
  }
}
