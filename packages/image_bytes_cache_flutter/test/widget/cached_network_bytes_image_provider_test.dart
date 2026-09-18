import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CachedNetworkBytesImageProvider', () {
    late _FakeResolver resolver;

    setUp(() {
      resolver = _FakeResolver();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    Widget wrap(Widget child) {
      return MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );
    }

    Future<void> settle(
      WidgetTester tester,
      bool Function() done, {
      Duration timeout = const Duration(seconds: 3),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!done() && DateTime.now().isBefore(deadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    testWidgets('paints a PNG through Image after resolve', (tester) async {
      resolver.bytes = oneByOnePngBytes();

      await tester.pumpWidget(
        wrap(
          Image(
            image: CachedNetworkBytesImageProvider(
              'https://cdn.example.com/ok.png',
              resolver: resolver,
            ),
            width: 24,
            height: 24,
          ),
        ),
      );

      await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
      await tester.pump();

      expect(find.byType(RawImage), findsOneWidget);
      expect(resolver.requests, hasLength(1));
      expect(resolver.requests.single.url, 'https://cdn.example.com/ok.png');
    });

    testWidgets('paints a JPEG (non-PNG) through Image after resolve', (tester) async {
      resolver.bytes = oneByOneJpegBytes();

      await tester.pumpWidget(
        wrap(
          Image(
            image: CachedNetworkBytesImageProvider(
              'https://cdn.example.com/ok.jpg',
              resolver: resolver,
            ),
            width: 24,
            height: 24,
          ),
        ),
      );

      await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
      await tester.pump();

      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('resolve failure surfaces via errorBuilder', (tester) async {
      resolver.error = Exception('resolve failed');
      final errorKey = UniqueKey();
      Object? caught;

      await tester.pumpWidget(
        wrap(
          Image(
            image: CachedNetworkBytesImageProvider(
              'https://cdn.example.com/missing.png',
              resolver: resolver,
            ),
            errorBuilder: (_, error, __) {
              caught = error;
              return SizedBox(key: errorKey, child: const Text('load-failed'));
            },
          ),
        ),
      );

      await settle(tester, () => find.byKey(errorKey).evaluate().isNotEmpty);
      await tester.pump();

      expect(find.text('load-failed'), findsOneWidget);
      expect(caught, isException);
      expect(tester.takeException(), isNull);
    });

    testWidgets('corrupt/non-image bytes surface via errorBuilder', (tester) async {
      resolver.bytes = Uint8List.fromList('not-an-image'.codeUnits);
      final errorKey = UniqueKey();
      Object? caught;

      await tester.pumpWidget(
        wrap(
          Image(
            image: CachedNetworkBytesImageProvider(
              'https://cdn.example.com/corrupt.bin',
              resolver: resolver,
            ),
            errorBuilder: (_, error, __) {
              caught = error;
              return SizedBox(key: errorKey, child: const Text('decode-failed'));
            },
          ),
        ),
      );

      await settle(tester, () => find.byKey(errorKey).evaluate().isNotEmpty);
      await tester.pump();

      expect(find.text('decode-failed'), findsOneWidget);
      expect(caught.toString(), contains('Invalid image data'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('network-miss progress appears as ImageChunkEvents', (tester) async {
      final afterFirstProgress = Completer<void>();
      final releaseBytes = Completer<void>();
      resolver
        ..bytes = oneByOnePngBytes()
        ..progressSteps = [
          (10, 40, afterFirstProgress.future),
          (40, 40, releaseBytes.future),
        ];

      final chunks = <ImageChunkEvent>[];

      await tester.pumpWidget(
        wrap(
          Image(
            image: CachedNetworkBytesImageProvider(
              'https://cdn.example.com/progress.png',
              resolver: resolver,
            ),
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress != null) {
                chunks.add(loadingProgress);
              }
              return child;
            },
          ),
        ),
      );

      await settle(tester, () => chunks.isNotEmpty);
      await tester.pump();
      expect(chunks, hasLength(1));
      expect(chunks.single.cumulativeBytesLoaded, 10);
      expect(chunks.single.expectedTotalBytes, 40);

      await tester.runAsync(() async {
        afterFirstProgress.complete();
      });
      await settle(tester, () => chunks.length >= 2);
      await tester.pump();

      expect(
        chunks.map((e) => (e.cumulativeBytesLoaded, e.expectedTotalBytes)),
        <(int, int?)>[(10, 40), (40, 40)],
      );

      await tester.runAsync(() async {
        releaseBytes.complete();
      });
      await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('cache-hit path does not invent mid-flight percents', (tester) async {
      resolver
        ..bytes = oneByOnePngBytes()
        // Silence: fake returns without invoking onBytesProgress (durable hit).
        ..emitProgress = false;

      final chunks = <ImageChunkEvent>[];

      await tester.pumpWidget(
        wrap(
          Image(
            image: CachedNetworkBytesImageProvider(
              'https://cdn.example.com/cached.png',
              resolver: resolver,
            ),
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress != null) {
                chunks.add(loadingProgress);
              }
              return child;
            },
          ),
        ),
      );

      await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
      await tester.pump();

      expect(chunks, isEmpty);
      expect(resolver.requests, hasLength(1));
      expect(resolver.requests.single.onBytesProgress, isNotNull);
    });

    test('Flutter image-cache identity includes ImageCacheKey and scale', () {
      const a = CachedNetworkBytesImageProvider(
        'https://cdn.example.com/a.png',
        headers: {'Authorization': 't'},
        scale: 1,
      );
      const b = CachedNetworkBytesImageProvider(
        'https://cdn.example.com/a.png',
        headers: {'authorization': 't'},
        scale: 1,
      );
      const differentScale = CachedNetworkBytesImageProvider(
        'https://cdn.example.com/a.png',
        headers: {'Authorization': 't'},
        scale: 2,
      );
      const differentUrl = CachedNetworkBytesImageProvider(
        'https://cdn.example.com/b.png',
        headers: {'Authorization': 't'},
        scale: 1,
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(differentScale)));
      expect(a, isNot(equals(differentUrl)));
      expect(
        a.cacheKey,
        ImageCacheKey.fromUrl(
          'https://cdn.example.com/a.png',
          headers: const {'Authorization': 't'},
        ),
      );
    });

    testWidgets('durable resolve request stays ImageCacheKey-only (no scale)', (
      tester,
    ) async {
      resolver.bytes = oneByOnePngBytes();

      await tester.pumpWidget(
        wrap(
          Image(
            image: CachedNetworkBytesImageProvider(
              'https://cdn.example.com/scale.png',
              scale: 2.5,
              headers: const {'X-Token': '1'},
              resolver: resolver,
            ),
          ),
        ),
      );

      await settle(tester, () => resolver.requests.isNotEmpty);
      await tester.pump();

      final request = resolver.requests.single;
      expect(request.url, 'https://cdn.example.com/scale.png');
      expect(request.headers, {'X-Token': '1'});
      expect(request.cacheKey, isNull);
    });
  });
}

/// Minimal 1×1 opaque PNG.
Uint8List oneByOnePngBytes() {
  return Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    ),
  );
}

/// Minimal 1×1 JPEG — non-PNG raster fixture for decode coverage.
Uint8List oneByOneJpegBytes() {
  return Uint8List.fromList(
    base64Decode(
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8U'
      'HRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgN'
      'DRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIy'
      'MjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAU'
      'EAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAA'
      'AAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA8A/9k=',
    ),
  );
}

final class _FakeResolver implements IImageBytesResolver {
  Uint8List? bytes;
  Exception? error;
  bool emitProgress = true;
  List<(int cumulative, int? total, Future<void> gate)> progressSteps = const [];

  final requests = <ImageBytesRequest>[];

  @override
  Future<Uint8List> resolve(ImageBytesRequest request) async {
    requests.add(request);
    if (error case final err?) {
      throw err;
    }
    if (emitProgress) {
      final sink = request.onBytesProgress;
      if (sink != null) {
        for (final (cumulative, total, gate) in progressSteps) {
          sink(cumulative, total);
          await gate;
        }
      }
    }
    return bytes ?? Uint8List(0);
  }
}
