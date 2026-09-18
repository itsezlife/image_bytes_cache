import 'dart:typed_data';

import 'package:image_bytes_cache/src/environment_specific/image_bytes_blob_store_routed_js.dart';
import 'package:image_bytes_cache/src/environment_specific/image_bytes_index_cache_js.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';

/// Conditional-import hook: Cache API index + Cache/OPFS blobs by size.
///
/// [ImageBytesCache.open] forwards here on web. [directory] exists only so the
/// signature matches the VM stub; it is ignored. Browser storage already owns
/// durability; there is no IsolateController on this path. Orphan reclaim is
/// wired into [IndexedImageBytesCache] so it shares the exclusive mutate
/// domain. Hard storage failures throw so [ImageBytesCache.open] can degrade
/// to memory with a diagnostic.
///
/// On any failure after Cache/OPFS handles exist, this function closes those
/// partial resources before rethrowing so degrade / `throwOnOpenFailure` paths
/// cannot leak quota-holding handles.
Future<IImageBytesCache> $openImageBytesCache({
  String? directory,
  ImageBytesRetention retention = ImageBytesRetention.standard,
  DateTime Function()? clock,
}) async {
  ImageBytesBlobStore$Routed$JS? blobs;
  ImageBytesIndex$Cache$JS? index;
  ImageBytesCache$JS? opened;
  try {
    blobs = await ImageBytesBlobStore$Routed$JS.open();
    index = await ImageBytesIndex$Cache$JS.open(onWipe: blobs.wipeAll);

    opened = ImageBytesCache$JS(
      inner: IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: retention,
        clock: clock,
        reclaimOrphans: blobs.reclaimOrphans,
      ),
      index: index,
      blobs: blobs,
    );
    // Ownership transferred to [opened]; close goes through the wrapper.
    blobs = null;
    index = null;
    await opened.reclaimOrphans();
    return opened;
  } on Object {
    await opened?.close();
    await index?.close();
    await blobs?.close();
    rethrow;
  }
}

/// Closes Cache / OPFS handles around [IndexedImageBytesCache].
///
/// Reclaim stays on the inner brain’s exclusive gate. This wrapper does not
/// reclaim outside that domain.
final class ImageBytesCache$JS implements IImageBytesCache {
  ImageBytesCache$JS({
    required IndexedImageBytesCache inner,
    required ImageBytesIndex$Cache$JS index,
    required ImageBytesBlobStore$Routed$JS blobs,
  }) : _inner = inner,
       _index = index,
       _blobs = blobs;

  final IndexedImageBytesCache _inner;
  final ImageBytesIndex$Cache$JS _index;
  final ImageBytesBlobStore$Routed$JS _blobs;

  Future<void> reclaimOrphans() => _inner.reclaimOrphans();

  @override
  Future<Uint8List?> read(ImageCacheKey key) => _inner.read(key);

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) => _inner.write(key, bytes);

  @override
  Future<void> evict(ImageCacheKey key) => _inner.evict(key);

  @override
  Future<ImageBytesPruneReport> prune() => _inner.prune();

  @override
  Future<void> close() async {
    await _inner.close();
    await _index.close();
    await _blobs.close();
  }
}
