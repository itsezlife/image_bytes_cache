import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

    testWidgets(
      'errorListener reports resolve failure without unhandled FlutterError',
      (tester) async {
        resolver.error = Exception('resolve failed');
        final errors = <Object>[];

        final provider = CachedNetworkBytesImageProvider(
          'https://cdn.example.com/missing.png',
          resolver: resolver,
          errorListener: (error, stackTrace) => errors.add(error),
        );
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener((image, synchronousCall) {});
        stream.addListener(listener);

        await settle(tester, () => errors.isNotEmpty);
        await tester.pump();

        expect(errors, hasLength(1));
        expect(errors.single, isException);
        expect(tester.takeException(), isNull);

        stream.removeListener(listener);
        expect(stream.completer, isNotNull);
        expect(stream.completer!.hasListeners, isFalse);
      },
    );

    testWidgets(
      'errorListener reports empty-body failure without unhandled FlutterError',
      (tester) async {
        resolver.bytes = Uint8List(0);
        final errors = <Object>[];

        final provider = CachedNetworkBytesImageProvider(
          'https://cdn.example.com/empty.png',
          resolver: resolver,
          errorListener: (error, stackTrace) => errors.add(error),
        );
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener((image, synchronousCall) {});
        stream.addListener(listener);

        await settle(tester, () => errors.isNotEmpty);
        await tester.pump();

        expect(errors, hasLength(1));
        expect(errors.single, isA<StateError>());
        expect(tester.takeException(), isNull);

        stream.removeListener(listener);
        expect(stream.completer!.hasListeners, isFalse);
      },
    );

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

      // Callback identity must not split Flutter ImageCache keys.
      final withListener = CachedNetworkBytesImageProvider(
        'https://cdn.example.com/a.png',
        headers: const {'Authorization': 't'},
        scale: 1,
        errorListener: (error, stackTrace) {},
      );
      final otherListener = CachedNetworkBytesImageProvider(
        'https://cdn.example.com/a.png',
        headers: const {'Authorization': 't'},
        scale: 1,
        errorListener: (error, stackTrace) {},
      );
      expect(a, equals(withListener));
      expect(withListener, equals(otherListener));
      expect(withListener.hashCode, otherListener.hashCode);
    });

    test(
      'Flutter image-cache identity splits when decode size differs for same URL',
      () {
        const fullRes = CachedNetworkBytesImageProvider(
          'https://cdn.example.com/photo.png',
          headers: {'Authorization': 't'},
        );
        const avatar = CachedNetworkBytesImageProvider.sized(
          'https://cdn.example.com/photo.png',
          cacheWidth: 32,
          cacheHeight: 32,
          headers: {'Authorization': 't'},
        );
        const preview = CachedNetworkBytesImageProvider.sized(
          'https://cdn.example.com/photo.png',
          cacheWidth: 512,
          headers: {'Authorization': 't'},
        );
        const sameAvatar = CachedNetworkBytesImageProvider(
          'https://cdn.example.com/photo.png',
          cacheWidth: 32,
          cacheHeight: 32,
          headers: {'authorization': 't'},
        );
        const upscaled = CachedNetworkBytesImageProvider.sized(
          'https://cdn.example.com/photo.png',
          cacheWidth: 32,
          cacheHeight: 32,
          allowUpscaling: true,
          headers: {'Authorization': 't'},
        );

        expect(avatar, equals(sameAvatar));
        expect(avatar.hashCode, sameAvatar.hashCode);
        expect(fullRes, isNot(equals(avatar)));
        expect(avatar, isNot(equals(preview)));
        expect(avatar, isNot(equals(upscaled)));

        final durable = ImageCacheKey.fromUrl(
          'https://cdn.example.com/photo.png',
          headers: const {'Authorization': 't'},
        );
        expect(fullRes.cacheKey, durable);
        expect(avatar.cacheKey, durable);
        expect(preview.cacheKey, durable);
        expect(upscaled.cacheKey, durable);
      },
    );

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

    testWidgets(
      'sized decode does not fork durable resolve identity (still ImageCacheKey-only)',
      (tester) async {
        resolver.bytes = oneByOnePngBytes();

        await tester.pumpWidget(
          wrap(
            Image(
              image: CachedNetworkBytesImageProvider.sized(
                'https://cdn.example.com/sized.png',
                cacheWidth: 48,
                scale: 2,
                headers: const {'X-Token': '1'},
                resolver: resolver,
              ),
            ),
          ),
        );

        await settle(tester, () => resolver.requests.isNotEmpty);
        await tester.pump();

        final request = resolver.requests.single;
        expect(request.url, 'https://cdn.example.com/sized.png');
        expect(request.headers, {'X-Token': '1'});
        expect(request.cacheKey, isNull);
      },
    );

    testWidgets('sized provider paints after resolve', (tester) async {
      resolver.bytes = oneByOnePngBytes();

      await tester.pumpWidget(
        wrap(
          Image(
            image: CachedNetworkBytesImageProvider.sized(
              'https://cdn.example.com/avatar.png',
              cacheWidth: 24,
              cacheHeight: 24,
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
    });

    testWidgets(
      'sized decode stores display-sized bitmap (not full-res body) in ImageCache',
      (tester) async {
        resolver.bytes = eightByEightPngBytes();

        Future<ui.Image?> paintedImage() async {
          await settle(tester, () {
            final found = find.byType(RawImage);
            if (found.evaluate().isEmpty) {
              return false;
            }
            return tester.widget<RawImage>(found).image != null;
          });
          await tester.pump();
          return tester.widget<RawImage>(find.byType(RawImage)).image;
        }

        await tester.pumpWidget(
          wrap(
            Image(
              image: CachedNetworkBytesImageProvider.sized(
                'https://cdn.example.com/downscale.png',
                cacheWidth: 2,
                cacheHeight: 2,
                resolver: resolver,
              ),
              width: 2,
              height: 2,
            ),
          ),
        );

        final sized = await paintedImage();
        expect(sized, isNotNull);
        expect(sized!.width, 2);
        expect(sized.height, 2);

        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        resolver.requests.clear();

        await tester.pumpWidget(
          wrap(
            Image(
              image: CachedNetworkBytesImageProvider(
                'https://cdn.example.com/downscale.png',
                resolver: resolver,
              ),
              width: 8,
              height: 8,
            ),
          ),
        );

        final full = await paintedImage();
        expect(full, isNotNull);
        expect(full!.width, 8);
        expect(full.height, 8);
      },
    );

    testWidgets(
      'ResizeImage wrapping an unsized provider remains a valid composition path',
      (tester) async {
        resolver.bytes = oneByOnePngBytes();

        await tester.pumpWidget(
          wrap(
            Image(
              image: ResizeImage(
                CachedNetworkBytesImageProvider(
                  'https://cdn.example.com/resize.png',
                  resolver: resolver,
                ),
                width: 16,
                height: 16,
              ),
              width: 16,
              height: 16,
            ),
          ),
        );

        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        await tester.pump();

        expect(find.byType(RawImage), findsOneWidget);
        expect(resolver.requests, hasLength(1));
      },
    );

    test('decodeSizePolicy splits identity only for a two-axis decode box', () {
      const exactBox = CachedNetworkBytesImageProvider.sized(
        'https://cdn.example.com/photo.png',
        cacheWidth: 32,
        cacheHeight: 32,
      );
      const coverBox = CachedNetworkBytesImageProvider.sized(
        'https://cdn.example.com/photo.png',
        cacheWidth: 32,
        cacheHeight: 32,
        decodeSizePolicy: ImageDecodeSizePolicy.cover,
      );
      const exactWidth = CachedNetworkBytesImageProvider.sized(
        'https://cdn.example.com/photo.png',
        cacheWidth: 32,
      );
      const coverWidth = CachedNetworkBytesImageProvider.sized(
        'https://cdn.example.com/photo.png',
        cacheWidth: 32,
        decodeSizePolicy: ImageDecodeSizePolicy.cover,
      );
      const unsizedFit = CachedNetworkBytesImageProvider(
        'https://cdn.example.com/photo.png',
        decodeSizePolicy: ImageDecodeSizePolicy.fit,
      );
      const unsized = CachedNetworkBytesImageProvider(
        'https://cdn.example.com/photo.png',
      );

      expect(exactBox, isNot(equals(coverBox)));
      expect(exactWidth, equals(coverWidth));
      expect(exactWidth.hashCode, coverWidth.hashCode);
      expect(unsized, equals(unsizedFit));
      expect(unsized.hashCode, unsizedFit.hashCode);
    });

    for (final (policy, width, height) in [
      (ImageDecodeSizePolicy.exact, 2, 2),
      (ImageDecodeSizePolicy.fit, 2, 1),
      (ImageDecodeSizePolicy.cover, 4, 2),
    ]) {
      testWidgets('${policy.name} decodes an 8×4 image in a 2×2 box at $width×$height', (tester) async {
        resolver.bytes = eightByFourPngBytes();

        await tester.pumpWidget(
          wrap(
            Image(
              image: CachedNetworkBytesImageProvider.sized(
                'https://cdn.example.com/${policy.name}.png',
                cacheWidth: 2,
                cacheHeight: 2,
                decodeSizePolicy: policy,
                resolver: resolver,
              ),
            ),
          ),
        );

        await settle(tester, () {
          final found = find.byType(RawImage);
          return found.evaluate().isNotEmpty && tester.widget<RawImage>(found).image != null;
        });
        await tester.pump();

        final image = tester.widget<RawImage>(find.byType(RawImage)).image;
        expect(image, isNotNull);
        expect(image!.width, width);
        expect(image.height, height);
      });
    }

    group('cancellation', () {
      final listener = ImageStreamListener((_, _) {});

      /// Resolves [provider], listens until its request lands, then stops.
      Future<CancelToken?> loadThenStopListening(CachedNetworkBytesImageProvider provider) async {
        final stream = provider.resolve(ImageConfiguration.empty)..addListener(listener);
        await pumpEventQueue();
        stream.removeListener(listener);
        await pumpEventQueue();
        return resolver.requests.single.cancelToken;
      }

      test('a pending load stays alive while the image cache holds it', () async {
        resolver.hold = Completer<void>();

        final token = await loadThenStopListening(
          CachedNetworkBytesImageProvider('https://cdn.example.com/pending.png', resolver: resolver),
        );

        expect(token, isNotNull);
        expect(token!.isCancelled, isFalse);
      });

      test('evicting a pending load nobody listens to cancels its request', () async {
        resolver.hold = Completer<void>();
        final provider = CachedNetworkBytesImageProvider('https://cdn.example.com/evicted.png', resolver: resolver);

        final token = await loadThenStopListening(provider);
        await provider.evict();

        expect(token?.isCancelled, isTrue);
      });

      test('the errorListener does not see the cancellation of its load', () async {
        resolver.hold = Completer<void>();
        final errors = <Object>[];
        final provider = CachedNetworkBytesImageProvider(
          'https://cdn.example.com/quiet.png',
          resolver: resolver,
          errorListener: (error, _) => errors.add(error),
        );

        await loadThenStopListening(provider);
        await provider.evict();
        await pumpEventQueue();

        expect(errors, isEmpty);
      });
    });
  });

  group('ImageDecodeSizePolicy.targetSize', () {
    ui.TargetImageSize target(
      ImageDecodeSizePolicy policy, {
      int? width,
      int? height,
      bool allowUpscaling = false,
    }) {
      return policy.targetSize(
        intrinsicWidth: 400,
        intrinsicHeight: 200,
        width: width,
        height: height,
        allowUpscaling: allowUpscaling,
      );
    }

    void expectTarget(ui.TargetImageSize actual, {int? width, int? height}) {
      expect((actual.width, actual.height), (width, height));
    }

    test('exact keeps both box dims', () {
      expectTarget(target(ImageDecodeSizePolicy.exact, width: 100, height: 100), width: 100, height: 100);
    });

    test('fit drives the tighter axis', () {
      expectTarget(target(ImageDecodeSizePolicy.fit, width: 100, height: 100), width: 100);
      expectTarget(target(ImageDecodeSizePolicy.fit, width: 400, height: 50), height: 50);
    });

    test('cover drives the looser axis', () {
      expectTarget(target(ImageDecodeSizePolicy.cover, width: 100, height: 100), height: 100);
      expectTarget(target(ImageDecodeSizePolicy.cover, width: 400, height: 50), width: 400);
    });

    test('a single axis passes through for every policy', () {
      for (final policy in ImageDecodeSizePolicy.values) {
        expectTarget(target(policy, width: 100), width: 100);
        expectTarget(target(policy, height: 50), height: 50);
      }
    });

    test('clamps the driving axis to intrinsic unless allowUpscaling', () {
      expectTarget(target(ImageDecodeSizePolicy.cover, width: 1000, height: 1000), height: 200);
      expectTarget(target(ImageDecodeSizePolicy.exact, width: 1000, height: 1000), width: 400, height: 200);
      expectTarget(
        target(ImageDecodeSizePolicy.cover, width: 1000, height: 1000, allowUpscaling: true),
        height: 1000,
      );
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

/// Opaque 8×8 RGB PNG — large enough to prove display-sized decode.
Uint8List eightByEightPngBytes() {
  return Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFWEXHbQSACj/P8Fu7N9hAAAAAElFTkSuQmCC',
    ),
  );
}

/// Opaque 8×4 RGB PNG — non-square fixture for aspect-preserving decode.
Uint8List eightByFourPngBytes() {
  return Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAIAAAA8r+mnAAAAEUlEQVR4nGNwaDiAFTFQTwIAUOswAfJrQPMAAAAASUVORK5CYII=',
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

  /// Holds every resolve until completed; a cancelled request token fails it
  /// with [HttpBytesException$Cancelled] instead.
  Completer<void>? hold;

  final requests = <ImageBytesRequest>[];

  @override
  Future<Uint8List> resolve(ImageBytesRequest request) async {
    final result = await resolveRich(request);
    return result.bytes;
  }

  @override
  Future<ImageBytesResolveResult> resolveRich(ImageBytesRequest request) async {
    requests.add(request);
    if (hold case final gate?) {
      final token = request.cancelToken;
      await Future.any([gate.future, ?token?.whenCancel]);
      if (token?.isCancelled ?? false) throw const HttpBytesException$Cancelled();
    }
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
    return ImageBytesResolveResult(
      bytes: bytes ?? Uint8List(0),
      origin: ImageBytesOrigin.network,
    );
  }
}
