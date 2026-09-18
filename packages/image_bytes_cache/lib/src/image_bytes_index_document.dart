import 'dart:convert';

import 'package:image_bytes_cache/src/image_bytes_cache.dart';

/// Records ↔ UTF-8 JSON bytes for the durable index document.
///
/// Shape: `{"v":1,"e":{"<key>":{"w":ms,"a":ms,"n":byteLength}}}`.
/// Unknown [version] or bad structure throws [FormatException] so open paths
/// can wipe safely.
final class ImageBytesIndexDocumentCodec extends Codec<Map<String, ImageBytesRecord>, List<int>> {
  /// Shared codec instance for durable index adapters.
  const ImageBytesIndexDocumentCodec();

  /// Wire version for the durable index document (VM file and web meta cache).
  static const int version = 1;

  static const _jsonCodec = _ImageBytesIndexDocumentJsonCodec();

  static const _utf8Codec = Utf8Codec();
  static const _jsonEncoder = JsonEncoder();
  static const _jsonDecoder = JsonDecoder();

  @override
  Converter<Map<String, ImageBytesRecord>, List<int>> get encoder =>
      _jsonCodec.encoder.fuse(_jsonEncoder).fuse(_utf8Codec.encoder);

  @override
  Converter<List<int>, Map<String, ImageBytesRecord>> get decoder =>
      _utf8Codec.decoder.fuse(_jsonDecoder).fuse(_jsonCodec.decoder);
}

/// Records ↔ JSON-compatible object (internal half of the bytes codec).
final class _ImageBytesIndexDocumentJsonCodec extends Codec<Map<String, ImageBytesRecord>, Object?> {
  const _ImageBytesIndexDocumentJsonCodec();

  @override
  Converter<Map<String, ImageBytesRecord>, Object?> get encoder => const _ImageBytesIndexDocumentEncoder();

  @override
  Converter<Object?, Map<String, ImageBytesRecord>> get decoder => const _ImageBytesIndexDocumentDecoder();
}

final class _ImageBytesIndexDocumentEncoder extends Converter<Map<String, ImageBytesRecord>, Object?> {
  const _ImageBytesIndexDocumentEncoder();

  @override
  Object? convert(Map<String, ImageBytesRecord> input) => {
    'v': ImageBytesIndexDocumentCodec.version,
    'e': {
      for (final MapEntry(:key, :value) in input.entries)
        key: {
          'w': value.writtenAt.toUtc().millisecondsSinceEpoch,
          'a': value.accessedAt.toUtc().millisecondsSinceEpoch,
          'n': value.byteLength,
        },
    },
  };
}

final class _ImageBytesIndexDocumentDecoder extends Converter<Object?, Map<String, ImageBytesRecord>> {
  const _ImageBytesIndexDocumentDecoder();

  @override
  Map<String, ImageBytesRecord> convert(Object? input) => switch (input) {
    {
      'v': final Object? version,
      'e': final Map entries,
    }
        when version == ImageBytesIndexDocumentCodec.version =>
      {
        for (final MapEntry(:key, :value) in entries.entries)
          key.toString(): _recordFromEntry(
            ImageCacheKey(key.toString()),
            value,
          ),
      },
    {'v': final Object? version} when version != ImageBytesIndexDocumentCodec.version => throw FormatException(
      'image bytes index: unsupported version $version',
    ),
    _ => throw const FormatException(
      'image bytes index: root is not a versioned entries object',
    ),
  };

  static ImageBytesRecord _recordFromEntry(ImageCacheKey key, Object? raw) => switch (raw) {
    {
      'w': final int writtenAtMs,
      'a': final int accessedAtMs,
      'n': final int byteLength,
    } =>
      ImageBytesRecord(
        key: key,
        writtenAt: DateTime.fromMillisecondsSinceEpoch(
          writtenAtMs,
          isUtc: true,
        ),
        accessedAt: DateTime.fromMillisecondsSinceEpoch(
          accessedAtMs,
          isUtc: true,
        ),
        byteLength: byteLength,
      ),
    _ => throw const FormatException(
      'image bytes index: invalid entry fields',
    ),
  };
}
