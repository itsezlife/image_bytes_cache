import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CachedNetworkBytesImage', () {
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

    testWidgets('paints a PNG after resolve', (tester) async {
      resolver.bytes = oneByOnePngBytes();

      await tester.pumpWidget(
        wrap(
          CachedNetworkBytesImage(
            'https://cdn.example.com/ok.png',
            resolver: resolver,
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

    testWidgets('resolve failure surfaces via errorBuilder and onError', (
      tester,
    ) async {
      resolver.error = Exception('resolve failed');
      final errorKey = UniqueKey();
      final errors = <Object>[];
      Object? caught;

      await tester.pumpWidget(
        wrap(
          CachedNetworkBytesImage(
            'https://cdn.example.com/missing.png',
            resolver: resolver,
            onError: (error, stackTrace) => errors.add(error),
            errorBuilder: (_, error, __) {
              caught = error;
              return SizedBox(key: errorKey, child: const Text('load-failed'));
            },
          ),
        ),
      );

      await settle(
        tester,
        () => find.byKey(errorKey).evaluate().isNotEmpty && errors.isNotEmpty,
      );
      await tester.pump();

      expect(find.text('load-failed'), findsOneWidget);
      expect(caught, isException);
      expect(errors, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'onError fires once per failure via provider errorListener (no double-fire)',
      (tester) async {
        resolver.error = Exception('resolve failed');
        final errors = <Object>[];

        await tester.pumpWidget(
          wrap(
            CachedNetworkBytesImage(
              'https://cdn.example.com/missing.png',
              resolver: resolver,
              onError: (error, stackTrace) => errors.add(error),
              // errorBuilder paints UI only; must not also side-report onError.
              errorBuilder: (_, __, ___) => const Text('load-failed'),
            ),
          ),
        );

        await settle(
          tester,
          () => find.text('load-failed').evaluate().isNotEmpty && errors.isNotEmpty,
        );
        // Extra pumps: a double-fire bridge would append a second error here.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(errors, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'sized decode paints display-sized bitmap through the widget path',
      (tester) async {
        resolver.bytes = eightByEightPngBytes();

        await tester.pumpWidget(
          wrap(
            CachedNetworkBytesImage(
              'https://cdn.example.com/downscale.png',
              cacheWidth: 2,
              cacheHeight: 2,
              resolver: resolver,
              width: 2,
              height: 2,
            ),
          ),
        );

        await settle(tester, () {
          final found = find.byType(RawImage);
          if (found.evaluate().isEmpty) {
            return false;
          }
          return tester.widget<RawImage>(found).image != null;
        });
        await tester.pump();

        final painted = tester.widget<RawImage>(find.byType(RawImage)).image;
        expect(painted, isNotNull);
        expect(painted!.width, 2);
        expect(painted.height, 2);
        expect(resolver.requests, hasLength(1));
      },
    );

    group('raster paint chrome', () {
      Widget wrapChrome(Widget child) {
        // Avoid Material route FadeTransitions so compose motion is observable.
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: child),
        );
      }

      Finder rasterFade() => find.byKey(RasterPaintCompose.fadeTransitionKey);

      testWidgets('placeholder then image', (tester) async {
        final gate = Completer<void>();
        resolver
          ..bytes = oneByOnePngBytes()
          ..resolveGate = gate.future;

        await tester.pumpWidget(
          wrapChrome(
            CachedNetworkBytesImage(
              'https://cdn.example.com/placeholder.png',
              resolver: resolver,
              placeholderBuilder: (_) => const Text('waiting…'),
              fadeInDuration: Duration.zero,
            ),
          ),
        );
        await tester.pump();

        expect(find.text('waiting…'), findsOneWidget);
        expect(find.byType(RawImage), findsNothing);

        await tester.runAsync(() async {
          gate.complete();
        });
        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        await tester.pump();

        expect(find.byType(RawImage), findsOneWidget);
        expect(find.text('waiting…'), findsNothing);
      });

      testWidgets('progress replaces placeholder on chunk events', (tester) async {
        final afterFirst = Completer<void>();
        final releaseBytes = Completer<void>();
        resolver
          ..bytes = oneByOnePngBytes()
          ..progressSteps = [
            (10, 40, afterFirst.future),
            (40, 40, releaseBytes.future),
          ];

        await tester.pumpWidget(
          wrapChrome(
            CachedNetworkBytesImage(
              'https://cdn.example.com/progress.png',
              resolver: resolver,
              placeholderBuilder: (_) => const Text('waiting…'),
              progressBuilder: (_, progress) => Text(
                'progress ${progress.cumulativeBytesLoaded}',
              ),
              fadeInDuration: Duration.zero,
            ),
          ),
        );

        await settle(
          tester,
          () => find.text('progress 10').evaluate().isNotEmpty,
        );
        expect(find.text('waiting…'), findsNothing);
        expect(find.text('progress 10'), findsOneWidget);

        await tester.runAsync(() async {
          afterFirst.complete();
        });
        await settle(
          tester,
          () => find.text('progress 40').evaluate().isNotEmpty,
        );

        await tester.runAsync(() async {
          releaseBytes.complete();
        });
        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        await tester.pump();

        expect(find.byType(RawImage), findsOneWidget);
        expect(find.textContaining('progress'), findsNothing);
      });

      testWidgets('quiet resolve keeps placeholder (no invented progress)', (
        tester,
      ) async {
        final gate = Completer<void>();
        resolver
          ..bytes = oneByOnePngBytes()
          ..emitProgress = false
          ..resolveGate = gate.future;

        var progressBuilds = 0;
        await tester.pumpWidget(
          wrapChrome(
            CachedNetworkBytesImage(
              'https://cdn.example.com/quiet.png',
              resolver: resolver,
              placeholderBuilder: (_) => const Text('waiting…'),
              progressBuilder: (_, __) {
                progressBuilds++;
                return const Text('progress');
              },
              fadeInDuration: Duration.zero,
            ),
          ),
        );
        await tester.pump();

        expect(find.text('waiting…'), findsOneWidget);
        expect(find.text('progress'), findsNothing);
        expect(progressBuilds, 0);

        await tester.runAsync(() async {
          gate.complete();
        });
        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        await tester.pump();

        expect(find.byType(RawImage), findsOneWidget);
        expect(progressBuilds, 0);
      });

      testWidgets('imageCache skip via synchronous frame', (tester) async {
        // Compose is the seam CachedNetworkBytesImage owns for frameBuilder.
        // Drive wasSynchronouslyLoaded: true through that same public builders
        // API (thin widget does not invent a second skip path).
        final composed = RasterPaintCompose.builders(
          fadeInDuration: const Duration(milliseconds: 300),
        );

        await tester.pumpWidget(
          wrapChrome(
            Builder(
              builder: (context) {
                return composed.frameBuilder(
                  context,
                  const Text('decoded'),
                  0,
                  true, // wasSynchronouslyLoaded
                );
              },
            ),
          ),
        );
        await tester.pump();

        expect(find.text('decoded'), findsOneWidget);
        expect(rasterFade(), findsNothing);
      });

      testWidgets('thin widget plays fade on async decode under imageCache-only policy', (
        tester,
      ) async {
        // Proves CachedNetworkBytesImage wires compose: async load must still
        // fade when only imageCache is in the skip mask.
        resolver.bytes = oneByOnePngBytes();

        await tester.pumpWidget(
          wrapChrome(
            CachedNetworkBytesImage(
              'https://cdn.example.com/async-fade.png',
              resolver: resolver,
              fadePolicy: const ImageFadePolicy(ImageFadeSkip.imageCache),
              fadeInDuration: const Duration(milliseconds: 300),
            ),
          ),
        );
        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

        expect(rasterFade(), findsOneWidget);
        final fade = tester.widget<FadeTransition>(rasterFade());
        expect(fade.opacity.value, lessThan(1.0));
      });

      testWidgets('zero fadeInDuration plays no motion', (tester) async {
        resolver.bytes = oneByOnePngBytes();

        await tester.pumpWidget(
          wrapChrome(
            CachedNetworkBytesImage(
              'https://cdn.example.com/zero-fade.png',
              resolver: resolver,
              fadeInDuration: Duration.zero,
            ),
          ),
        );
        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        await tester.pump();

        expect(find.byType(RawImage), findsOneWidget);
        expect(rasterFade(), findsNothing);
      });

      testWidgets('never policy plays no motion', (tester) async {
        resolver.bytes = oneByOnePngBytes();

        await tester.pumpWidget(
          wrapChrome(
            CachedNetworkBytesImage(
              'https://cdn.example.com/never-fade.png',
              resolver: resolver,
              fadePolicy: ImageFadePolicy.never,
              fadeInDuration: const Duration(milliseconds: 300),
            ),
          ),
        );
        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        await tester.pump();

        expect(find.byType(RawImage), findsOneWidget);
        expect(rasterFade(), findsNothing);
      });

      testWidgets('bytesCache skip: store origin skips fade under standard', (
        tester,
      ) async {
        // Async decode (wasSynchronouslyLoaded false) but resolve served from
        // the bytes store — standard must skip like a warm ImageCache hit.
        resolver
          ..bytes = oneByOnePngBytes()
          ..origin = ImageBytesOrigin.cache
          ..emitProgress = false;

        await tester.pumpWidget(
          wrapChrome(
            CachedNetworkBytesImage(
              'https://cdn.example.com/store-hit.png',
              resolver: resolver,
              fadePolicy: ImageFadePolicy.standard,
              fadeInDuration: const Duration(milliseconds: 300),
            ),
          ),
        );
        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        await tester.pump();

        expect(find.byType(RawImage), findsOneWidget);
        expect(rasterFade(), findsNothing);
      });

      testWidgets('bytesCache: network origin still fades under standard', (
        tester,
      ) async {
        resolver
          ..bytes = oneByOnePngBytes()
          ..origin = ImageBytesOrigin.network;

        await tester.pumpWidget(
          wrapChrome(
            CachedNetworkBytesImage(
              'https://cdn.example.com/network-fade.png',
              resolver: resolver,
              fadePolicy: ImageFadePolicy.standard,
              fadeInDuration: const Duration(milliseconds: 300),
            ),
          ),
        );
        await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

        expect(rasterFade(), findsOneWidget);
        final fade = tester.widget<FadeTransition>(rasterFade());
        expect(fade.opacity.value, lessThan(1.0));
      });

      test('high-level chrome xor raw builders asserts', () {
        expect(
          () => CachedNetworkBytesImage(
            'https://cdn.example.com/xor.png',
            placeholderBuilder: (_) => const SizedBox.shrink(),
            frameBuilder: (context, child, frame, sync) => child,
          ),
          throwsAssertionError,
        );
        expect(
          () => CachedNetworkBytesImage(
            'https://cdn.example.com/xor.png',
            fadeInDuration: const Duration(milliseconds: 300),
            loadingBuilder: (context, child, progress) => child,
          ),
          throwsAssertionError,
        );
      });
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

final class _FakeResolver implements IImageBytesResolver {
  Uint8List? bytes;
  Exception? error;
  bool emitProgress = true;
  Future<void>? resolveGate;
  List<(int cumulative, int? total, Future<void> gate)> progressSteps = const [];
  ImageBytesOrigin origin = ImageBytesOrigin.network;

  final requests = <ImageBytesRequest>[];

  @override
  Future<Uint8List> resolve(ImageBytesRequest request) async {
    final result = await resolveRich(request);
    return result.bytes;
  }

  @override
  Future<ImageBytesResolveResult> resolveRich(ImageBytesRequest request) async {
    requests.add(request);
    if (error case final err?) {
      throw err;
    }
    if (resolveGate case final gate?) {
      await gate;
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
      origin: origin,
    );
  }
}
