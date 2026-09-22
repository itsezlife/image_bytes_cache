import 'dart:convert';

import 'package:image_bytes_cache/src/image_bytes_cache.dart';

/// Records ↔ UTF-8 JSON bytes for the durable index document.
///
/// Shape: `{"v":1,"e":{"<key>":{"w":ms,"a":ms,"n":byteLength,"h"?:{…}}}}`.
/// Optional `h` is [ImageHttpCacheMeta] on the wire (`et`, `lm`, `d`, `x`,
/// `cc`, `ag`, `lv`). Missing `h`, or missing keys inside it, decode as null
/// meta. Old documents stay valid. Unknown [version] or a broken structure
/// throws [FormatException] so open can wipe.
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
          if (value.httpCacheMeta case final meta? when !meta.isEmpty) 'h': _encodeHttpMeta(meta),
        },
    },
  };

  static Map<String, Object> _encodeHttpMeta(ImageHttpCacheMeta meta) => {
    'et': ?meta.etag,
    'lm': ?meta.lastModified,
    'd': ?meta.date?.toUtc().millisecondsSinceEpoch,
    'x': ?meta.expires?.toUtc().millisecondsSinceEpoch,
    'cc': ?meta.cacheControl,
    'ag': ?meta.age?.inMilliseconds,
    'lv': ?meta.lastValidatedAt?.toUtc().millisecondsSinceEpoch,
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
        } &&
        final Map map =>
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
        httpCacheMeta: _httpMetaFrom(map['h']),
      ),
    _ => throw const FormatException(
      'image bytes index: invalid entry fields',
    ),
  };

  /// Missing or null `h` becomes null meta. Wrong `h` type or field types throw
  /// [FormatException] so open can wipe instead of keeping half-parsed validators.
  static ImageHttpCacheMeta? _httpMetaFrom(Object? raw) => switch (raw) {
    null => null,
    final Map map => _httpMetaFromMap(map),
    _ => throw const FormatException('image bytes index: invalid HTTP cache meta'),
  };

  static ImageHttpCacheMeta? _httpMetaFromMap(Map map) {
    final etag = switch (map['et']) {
      null => null,
      final String s => s,
      _ => throw const FormatException('image bytes index: invalid etag'),
    };
    final lastModified = switch (map['lm']) {
      null => null,
      final String s => s,
      _ => throw const FormatException('image bytes index: invalid lastModified'),
    };
    final date = _optionalUtcMs(map['d'], 'date');
    final expires = _optionalUtcMs(map['x'], 'expires');
    final cacheControl = switch (map['cc']) {
      null => null,
      final String s => s,
      _ => throw const FormatException('image bytes index: invalid cacheControl'),
    };
    final age = switch (map['ag']) {
      null => null,
      final int ms => Duration(milliseconds: ms),
      _ => throw const FormatException('image bytes index: invalid age'),
    };
    final lastValidatedAt = _optionalUtcMs(map['lv'], 'lastValidatedAt');
    final meta = ImageHttpCacheMeta(
      etag: etag,
      lastModified: lastModified,
      date: date,
      expires: expires,
      cacheControl: cacheControl,
      age: age,
      lastValidatedAt: lastValidatedAt,
    );
    return meta.isEmpty ? null : meta;
  }

  static DateTime? _optionalUtcMs(Object? raw, String field) => switch (raw) {
    null => null,
    final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
    _ => throw FormatException('image bytes index: invalid $field'),
  };
}
