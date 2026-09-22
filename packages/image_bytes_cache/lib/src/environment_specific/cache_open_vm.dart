import 'dart:typed_data';

import 'package:image_bytes_cache/src/environment_specific/blob_store_file_vm.dart';
import 'package:image_bytes_cache/src/environment_specific/index_file_vm.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';

/// VM hook behind [ImageBytesCache.open].
///
/// Wires [ImageBytesIndex$File$VM] + [ImageBytesBlobStore$File$VM] into
/// [IndexedImageBytesCache] with orphan reclaim inside the brain’s exclusive
/// domain, reclaims once at open, and closes the isolate worker with the cache.
/// Call [ImageBytesCache.open] from app code, not this symbol. [directory] is
/// required. Degraded open (Memory + diagnostic) is handled by
/// [ImageBytesCache.open], not here.
///
/// On any failure after a blob store (and its isolate worker) exists, this
/// function closes those partial resources before rethrowing so
/// [ImageBytesCache.open] degrade / `throwOnOpenFailure` paths cannot leak
/// workers. Missing [directory] still throws [ArgumentError] before any spawn.
Future<IImageBytesCache> $openImageBytesCache({
  String? directory,
  ImageBytesRetention retention = ImageBytesRetention.standard,
  DateTime Function()? clock,
}) async {
  final root = switch (directory) {
    final d? when d.isNotEmpty => d,
    _ => throw ArgumentError.value(directory, 'directory', 'required on VM'),
  };

  ImageBytesBlobStore$File$VM? blobs;
  ImageBytesCache$VM? opened;
  try {
    blobs = ImageBytesBlobStore$File$VM(directory: root);
    await blobs.ensureDirectory();
    final index = await ImageBytesIndex$File$VM.open(
      directory: root,
      io: blobs,
      onWipe: blobs.wipeAll,
    );

    opened = ImageBytesCache$VM(
      inner: IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: retention,
        clock: clock,
        reclaimOrphans: blobs.reclaimOrphans,
      ),
      blobs: blobs,
    );
    // Ownership of [blobs] transferred to [opened]; close goes through the wrapper.
    blobs = null;
    await opened.reclaimOrphans();
    return opened;
  } on Object {
    await opened?.close();
    await blobs?.close();
    rethrow;
  }
}

/// Closes the isolate worker around [IndexedImageBytesCache].
///
/// Orphan reclaim on open/prune stays on the inner brain’s exclusive
/// gate. This wrapper does not reclaim outside that domain.
final class ImageBytesCache$VM implements IImageBytesCache {
  ImageBytesCache$VM({
    required IndexedImageBytesCache inner,
    required ImageBytesBlobStore$File$VM blobs,
  }) : _inner = inner,
       _blobs = blobs;

  final IndexedImageBytesCache _inner;
  final ImageBytesBlobStore$File$VM _blobs;

  Future<void> reclaimOrphans() => _inner.reclaimOrphans();

  @override
  Future<Uint8List?> read(ImageCacheKey key) => _inner.read(key);

  @override
  Future<void> write(
    ImageCacheKey key,
    Uint8List bytes, {
    ImageHttpCacheMeta? httpCacheMeta,
  }) => _inner.write(key, bytes, httpCacheMeta: httpCacheMeta);

  @override
  Future<void> evict(ImageCacheKey key) => _inner.evict(key);

  @override
  Future<ImageBytesPruneReport> prune() => _inner.prune();

  @override
  Future<void> close() async {
    await _inner.close();
    await _blobs.close();
  }
}
