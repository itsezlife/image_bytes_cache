import 'dart:convert';

import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_bytes_index_document.dart';
import 'package:image_bytes_cache/src/image_bytes_web_keys.dart';
import 'package:test/test.dart';

/// Builds UTF-8 JSON bytes without the domain index codec (fixtures only).
List<int> _jsonObjectBytes(Object? value) => const JsonEncoder().fuse(const Utf8Encoder()).convert(value);

void main() {
  group('ImageBytesIndexDocumentCodec', () {
    const codec = ImageBytesIndexDocumentCodec();

    test('round-trips records', () {
      final written = DateTime.utc(2024, 1, 2, 3, 4, 5);
      final accessed = DateTime.utc(2024, 1, 2, 3, 5, 0);
      final input = {
        'logo': ImageBytesRecord(
          key: const ImageCacheKey('logo'),
          writtenAt: written,
          accessedAt: accessed,
          byteLength: 12,
        ),
      };

      final wire = codec.encode(input);
      final decoded = codec.decode(wire);

      expect(decoded.keys, ['logo']);
      expect(decoded['logo']!.byteLength, 12);
      expect(decoded['logo']!.writtenAt, written);
      expect(decoded['logo']!.accessedAt, accessed);
    });

    test('rejects unsupported version', () {
      expect(
        () => codec.decode(
          _jsonObjectBytes({
            'v': 99,
            'e': <String, Object?>{},
          }),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects malformed root', () {
      expect(
        () => codec.decode(_jsonObjectBytes({'nope': true})),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ImageBytesWebKeys', () {
    test('blobUrl encodes key and round-trips via keyValueFromBlobUrl', () {
      const key = ImageCacheKey('host_logo_abcdef123456');
      final url = ImageBytesWebKeys.blobUrl(key);
      expect(url, startsWith('https://image-bytes.invalid/v1/blob/'));
      expect(ImageBytesWebKeys.keyValueFromBlobUrl(url), key.value);
    });

    test('keyValueFromBlobUrl ignores foreign URLs', () {
      expect(
        ImageBytesWebKeys.keyValueFromBlobUrl('https://cdn.example/logo.png'),
        isNull,
      );
      expect(
        ImageBytesWebKeys.keyValueFromBlobUrl(ImageBytesWebKeys.indexDocumentUrl),
        isNull,
      );
    });

    test('cache names stay distinct so meta scan never loads payloads', () {
      expect(
        ImageBytesWebKeys.indexCacheName,
        isNot(ImageBytesWebKeys.blobsCacheName),
      );
    });

    test('OPFS directory name is stable and distinct from the index Cache', () {
      expect(ImageBytesWebKeys.opfsBlobsDirectoryName, 'image_bytes_blobs_v1');
      expect(
        ImageBytesWebKeys.opfsBlobsDirectoryName,
        isNot(ImageBytesWebKeys.indexCacheName),
      );
    });
  });
}
