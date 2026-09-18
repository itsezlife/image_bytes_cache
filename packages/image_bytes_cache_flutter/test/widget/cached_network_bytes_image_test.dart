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

  final requests = <ImageBytesRequest>[];

  @override
  Future<Uint8List> resolve(ImageBytesRequest request) async {
    requests.add(request);
    if (error case final err?) {
      throw err;
    }
    return bytes ?? Uint8List(0);
  }
}
