import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/isolate_controller.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// VM payload half of [IndexedImageBytesCache]: one file per [ImageCacheKey].
///
/// Retention and timestamps stay on [ImageBytesIndex$File$VM]. This type owns the
/// files under [directory] and the isolate that touches them.
///
/// Without a long-lived [IsolateController], each small payload write would pay
/// `compute` spawn cost, and sync `dart:io` on the UI isolate would hitch
/// scrolls. The worker runs sync IO; the host only awaits RPC.
///
/// Writes at or above [transferByteThreshold] cross the isolate boundary as
/// [TransferableTypedData] so the send itself stays O(1) after one preparation
/// copy. Smaller bodies stay plain [Uint8List] (transferable setup would cost
/// more than it saves). Writes go to `path.tmp` then rename. A crash mid-write
/// leaves a temp (or nothing), never a truncated final path that [read] would
/// treat as a hit.
///
/// When the worker dies (watchdog, `#exit`, or [debugKillWorker]), in-flight
/// RPC futures complete with [StateError] instead of hanging, the dead
/// controller is dropped, and a later op may respawn. [close] still fails
/// pending with a closed [StateError] and refuses further RPCs.
final class ImageBytesBlobStore$File$VM implements IImageBytesBlobStore {
  /// Roots the store at [directory]. The directory is created on
  /// [ensureDirectory] / first write, not in this constructor.
  ImageBytesBlobStore$File$VM({required this.directory});

  /// Metadata filename in [directory]. Not a blob key; reclaim/wipe skip it.
  static const String indexFileName = 'image_bytes_index.json';

  /// Payloads at or above this size use [TransferableTypedData] on write RPC.
  ///
  /// Below the threshold, transferable prep is usually more expensive than a
  /// normal isolate copy of a small body. Above it, avoiding a second full copy
  /// on send matters for large payloads.
  static const int transferByteThreshold = 64 * 1024;

  /// Cache root shared with [ImageBytesIndex$File$VM].
  final String directory;

  IsolateController<_BlobIoRequest, _BlobIoResponse>? _controller;
  StreamSubscription<_BlobIoResponse>? _subscription;
  Completer<void>? _spawning;
  final Map<int, Completer<_BlobIoResponse>> _pending = {};
  var _nextId = 0;
  var _closed = false;

  /// Live IO workers across all VM blob stores. Test seam for open-failure
  /// cleanup: spawn increments, [close] decrements when a worker was live.
  @visibleForTesting
  static int debugActiveWorkerCount = 0;

  /// Test seam: kill the live isolate worker without closing the store.
  ///
  /// Production death (watchdog / `#exit`) takes the same fail-pending path
  /// via stream `onDone`. Pending RPCs must fail fast; later ops may respawn.
  @visibleForTesting
  void debugKillWorker() {
    final controller = _controller;
    if (controller == null) return;
    controller.close();
    // Fail pending synchronously; do not wait for stream onDone microtask.
    _onWorkerGone();
  }

  String _pathFor(ImageCacheKey key) => p.join(directory, key.value);

  @override
  Future<Uint8List?> read(ImageCacheKey key, {int? knownByteLength}) => readPath(_pathFor(key));

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) => writePathAtomic(_pathFor(key), bytes);

  @override
  Future<void> delete(ImageCacheKey key) => deletePath(_pathFor(key));

  /// Creates [directory] (and parents) on the worker.
  Future<void> ensureDirectory() async {
    await _rpc(
      (
        id: -1,
        op: .mkdir,
        path: directory,
        bytes: null,
        indexedKeys: null,
      ),
    );
  }

  /// Reads [path] as bytes, or `null` when the file is missing.
  ///
  /// Used for the index document as well as payload keys.
  Future<Uint8List?> readPath(String path) async {
    final response = await _rpc(
      (
        id: -1,
        op: .read,
        path: path,
        bytes: null,
        indexedKeys: null,
      ),
    );
    return response.bytes;
  }

  /// Writes [bytes] to [path] via temp + rename on the worker.
  ///
  /// Large payloads are wrapped in [TransferableTypedData] before RPC so the
  /// isolate send does not copy again. The caller may keep using [bytes];
  /// [TransferableTypedData.fromList] prepares its own buffer.
  Future<void> writePathAtomic(String path, Uint8List bytes) async {
    final payload = bytes.lengthInBytes >= transferByteThreshold ? TransferableTypedData.fromList([bytes]) : bytes;
    await _rpc(
      (
        id: -1,
        op: .write,
        path: path,
        bytes: payload,
        indexedKeys: null,
      ),
    );
  }

  /// Deletes [path] if present. Missing file is not an error.
  Future<void> deletePath(String path) async {
    await _rpc(
      (
        id: -1,
        op: .delete,
        path: path,
        bytes: null,
        indexedKeys: null,
      ),
    );
  }

  /// Drops payload and `.tmp` files whose basenames are not in [indexedKeys].
  ///
  /// Skips [indexFileName]. Call after open and after prune so failed writes
  /// do not leak forever.
  Future<void> reclaimOrphans(Set<String> indexedKeys) async {
    await _rpc(
      (
        id: -1,
        op: .reclaim,
        path: directory,
        bytes: null,
        indexedKeys: indexedKeys,
      ),
    );
  }

  /// Deletes every top-level file under [directory] except [indexFileName].
  Future<void> wipeAll() async {
    await _rpc(
      (
        id: -1,
        op: .wipe,
        path: directory,
        bytes: null,
        indexedKeys: null,
      ),
    );
  }

  /// Kills the IO worker. Safe to call twice.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failPending(StateError(r'ImageBytesBlobStore$File$VM is closed'));
    await _subscription?.cancel();
    _subscription = null;
    if (_controller != null) {
      debugActiveWorkerCount--;
      _controller!.close();
      _controller = null;
    }
    _spawning = null;
  }

  Future<_BlobIoResponse> _rpc(_BlobIoRequest template) async {
    if (_closed) {
      throw StateError(r'ImageBytesBlobStore$File$VM is closed');
    }
    final controller = await _ensureSpawned();
    final id = _nextId++;
    final completer = Completer<_BlobIoResponse>();
    // Register before add so a death that lands in this window still fails
    // the completer. If the controller was already dropped, retry on a fresh
    // spawn instead of talking to a dead port.
    _pending[id] = completer;
    if (!identical(_controller, controller)) {
      _pending.remove(id);
      if (_closed) {
        throw StateError(r'ImageBytesBlobStore$File$VM is closed');
      }
      return _rpc(template);
    }
    controller.add((
      id: id,
      op: template.op,
      path: template.path,
      bytes: template.bytes,
      indexedKeys: template.indexedKeys,
    ));
    final response = await completer.future;
    return switch (response.error) {
      final error? => throw FileSystemException(error, template.path),
      null => response,
    };
  }

  Future<IsolateController<_BlobIoRequest, _BlobIoResponse>> _ensureSpawned() async {
    if (_controller case final existing?) return existing;

    if (_spawning case final spawning?) {
      await spawning.future;
      return switch (_controller) {
        final controller? => controller,
        null => throw StateError(
          r'ImageBytesBlobStore$File$VM failed to spawn worker',
        ),
      };
    }

    final completer = _spawning = Completer<void>();
    try {
      final controller = await IsolateController.spawn<void, _BlobIoRequest, _BlobIoResponse>(
        handler: _fileBlobIoHandler,
        payload: null,
        name: 'image_bytes_blob_io',
      );
      _subscription = controller.stream.listen(
        _onResponse,
        onError: (Object error, StackTrace stackTrace) {
          _onWorkerGone(error, stackTrace);
        },
        onDone: _onWorkerGone,
        cancelOnError: false,
      );
      _controller = controller;
      debugActiveWorkerCount++;
      completer.complete();
      return controller;
    } on Object catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
      rethrow;
    } finally {
      if (identical(_spawning, completer)) {
        _spawning = null;
      }
    }
  }

  void _onResponse(_BlobIoResponse response) {
    _pending.remove(response.id)?.complete(response);
  }

  /// Watchdog / `#exit` / [debugKillWorker] close the isolate stream.
  ///
  /// Without failing [_pending], hosts (and the exclusive mutate gate) hang
  /// forever on in-flight RPCs. Dropping [_controller] lets a later [_rpc]
  /// respawn; [close] still owns the closed [StateError] path.
  void _onWorkerGone([Object? error, StackTrace? stackTrace]) {
    if (_closed) return;

    final controller = _controller;
    _controller = null;
    final subscription = _subscription;
    _subscription = null;
    _spawning = null;

    subscription?.cancel().ignore();

    if (controller != null) {
      debugActiveWorkerCount--;
      // Stream may already be closed (onDone); close is still safe enough to
      // cancel watchdog / kill if we arrived via onError alone.
      controller.close();
    }

    _failPending(
      switch (error) {
        null => StateError(r'ImageBytesBlobStore$File$VM worker died'),
        final StateError e => e,
        final Object e => StateError(
          'ImageBytesBlobStore\$File\$VM worker died: $e',
        ),
      },
      stackTrace,
    );
  }

  void _failPending(Object error, [StackTrace? stackTrace]) {
    if (_pending.isEmpty) return;
    final pending = Map<int, Completer<_BlobIoResponse>>.of(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }
}

// --- Isolate protocol -------------------------------------------------------

enum _BlobIoOp { read, write, delete, reclaim, wipe, mkdir }

/// [bytes] is [Uint8List], [TransferableTypedData], or null (non-write ops).
typedef _BlobIoRequest = ({
  int id,
  _BlobIoOp op,
  String path,
  Object? bytes,
  Set<String>? indexedKeys,
});

typedef _BlobIoResponse = ({
  int id,
  Uint8List? bytes,
  String? error,
});

/// Isolate entry for [ImageBytesBlobStore$File$VM].
///
/// Sync `dart:io` here is intentional: the UI isolate must not hitch on FS,
/// and `avoid_slow_async_io` prefers sync once work is already off-thread.
Future<void> _fileBlobIoHandler(
  void _,
  Stream<_BlobIoRequest> messages,
  void Function(_BlobIoResponse out) send,
) async {
  await for (final request in messages) {
    try {
      switch (request.op) {
        case .read:
          send((id: request.id, bytes: _readFile(request.path), error: null));
        case .write:
          _writeAtomic(request.path, _materializeWriteBytes(request.bytes));
          send((id: request.id, bytes: null, error: null));
        case .delete:
          _deleteIfExists(request.path);
          send((id: request.id, bytes: null, error: null));
        case .reclaim:
          _reclaimOrphans(
            request.path,
            request.indexedKeys ?? const <String>{},
          );
          send((id: request.id, bytes: null, error: null));
        case .wipe:
          _wipePayloads(request.path);
          send((id: request.id, bytes: null, error: null));
        case .mkdir:
          Directory(request.path).createSync(recursive: true);
          send((id: request.id, bytes: null, error: null));
      }
    } on Object catch (error) {
      send((id: request.id, bytes: null, error: error.toString()));
    }
  }
}

/// Resolves write RPC payload to bytes the worker can sync-write.
///
/// [TransferableTypedData] must be materialized exactly once on this isolate.
Uint8List _materializeWriteBytes(Object? bytes) => switch (bytes) {
  final TransferableTypedData transferable => transferable.materialize().asUint8List(),
  final Uint8List list => list,
  null => throw ArgumentError.notNull('bytes'),
  _ => throw ArgumentError.value(bytes, 'bytes', 'Uint8List or TransferableTypedData'),
};

/// Miss is normal: try read, map [FileSystemException] to null.
///
/// An `existsSync` first would double the syscall cost on every hit for no
/// extra information the catch does not already give.
Uint8List? _readFile(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException {
    return null;
  }
}

void _writeAtomic(String path, Uint8List bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final temp = File('$path.tmp')..writeAsBytesSync(bytes, flush: true);
  // POSIX rename replaces atomically. Windows refuses an existing target, so
  // fall back to delete-then-rename. Still no truncated final from a partial
  // writeAsBytes: that only ever lands in the temp path.
  try {
    temp.renameSync(path);
  } on FileSystemException {
    try {
      file.deleteSync();
    } on FileSystemException {
      // Target already gone.
    }
    temp.renameSync(path);
  }
}

void _deleteIfExists(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Absent is the desired end state.
  }
}

void _reclaimOrphans(String directory, Set<String> indexedKeys) {
  _forEachTopLevelFile(directory, (file, name) {
    if (name == ImageBytesBlobStore$File$VM.indexFileName) return;
    if (name.endsWith('.tmp') || !indexedKeys.contains(name)) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Next open/prune retries.
      }
    }
  });
}

void _wipePayloads(String directory) {
  _forEachTopLevelFile(directory, (file, name) {
    if (name == ImageBytesBlobStore$File$VM.indexFileName) return;
    try {
      file.deleteSync();
    } on FileSystemException {
      // Open still returns an empty index.
    }
  });
}

void _forEachTopLevelFile(
  String directory,
  void Function(File file, String basename) visit,
) {
  final dir = Directory(directory);
  try {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity case File(:final path)) {
        visit(entity, p.basename(path));
      }
    }
  } on FileSystemException {
    // Directory missing: nothing to reclaim or wipe.
  }
}
