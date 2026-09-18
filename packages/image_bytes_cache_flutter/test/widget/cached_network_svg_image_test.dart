import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CachedNetworkSvgImage', () {
    late _RecordingClient httpClient;
    late HttpBytesFetcher fetcher;
    late MemoryImageBytesCache cache;
    late ImageBytesResolver resolver;

    setUp(() {
      httpClient = _RecordingClient();
      fetcher = HttpBytesFetcher(client: httpClient);
      cache = MemoryImageBytesCache();
      resolver = ImageBytesResolver(cache: cache, fetcher: fetcher);
      ImageBytesResolver.debugShared = resolver;
    });

    tearDown(() async {
      await fetcher.close();
      ImageBytesResolver.debugShared = null;
      HttpBytesFetcher.debugShared = null;
      await ImageBytesCache.resetShared();
    });

    Widget wrap(Widget child, {PageStorageBucket? bucket}) {
      final body = Scaffold(body: Center(child: child));
      return MaterialApp(
        home: switch (bucket) {
          final b? => PageStorage(bucket: b, child: body),
          null => body,
        },
      );
    }

    Future<void> settle(
      WidgetTester tester,
      bool Function() done, {
      Duration timeout = const Duration(seconds: 3),
    }) async {
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(timeout);
        while (!done() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
    }

    testWidgets('calls onError once when download throws', (tester) async {
      httpClient.throwError = Exception('connection failed');
      final errors = <Object>[];

      await tester.pumpWidget(
        wrap(
          CachedNetworkSvgImage(
            'https://cdn.example.com/on-error-once.svg',
            onError: (error, stackTrace) => errors.add(error),
            errorBuilder: (_, __, ___) => const Text('load-failed'),
          ),
        ),
      );

      await settle(tester, () => errors.isNotEmpty);

      expect(errors, hasLength(1));
      expect(find.text('load-failed'), findsOneWidget);
    });

    testWidgets('calls onError once when HTTP status is not OK', (tester) async {
      httpClient.statusCode = 404;
      final errors = <Object>[];

      await tester.pumpWidget(
        wrap(
          CachedNetworkSvgImage(
            'https://cdn.example.com/missing.svg',
            onError: (error, stackTrace) => errors.add(error),
            errorBuilder: (_, __, ___) => const Text('err'),
          ),
          bucket: PageStorageBucket(),
        ),
      );

      await settle(tester, () => errors.isNotEmpty);

      expect(errors, hasLength(1));
      expect(errors.single, isA<http.ClientException>());
      expect(find.text('err'), findsOneWidget);
    });

    testWidgets('shows placeholderBuilder while loading then SvgPicture', (
      tester,
    ) async {
      final gate = Completer<void>();
      httpClient.requestDelay = gate.future;

      await tester.pumpWidget(
        wrap(
          CachedNetworkSvgImage(
            'https://cdn.example.com/slow.svg',
            placeholderBuilder: (_) => const Text('loading…'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('loading…'), findsOneWidget);

      await tester.runAsync(() async {
        gate.complete();
      });
      await settle(tester, () => httpClient.requestCount > 0);
      await tester.pump();

      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('renders SvgPicture after successful download', (tester) async {
      await tester.pumpWidget(
        wrap(
          const CachedNetworkSvgImage(
            'https://cdn.example.com/ok.svg',
            width: 24,
            height: 24,
          ),
        ),
      );

      await settle(tester, () => httpClient.requestCount > 0);
      await tester.pump();

      expect(find.byType(SvgPicture), findsOneWidget);
      expect(httpClient.requestCount, 1);
    });

    testWidgets('cache hit skips HTTP', (tester) async {
      const url = 'https://cdn.example.com/mem-hit.svg';
      await cache.write(ImageCacheKey.fromUrl(url), utf8SvgBytes());

      await tester.pumpWidget(wrap(const CachedNetworkSvgImage(url)));
      await settle(tester, () => find.byType(SvgPicture).evaluate().isNotEmpty);
      await tester.pump();

      expect(find.byType(SvgPicture), findsOneWidget);
      expect(httpClient.requestCount, 0);
    });

    testWidgets('serves from PageStorage on remount without a second fetch', (
      tester,
    ) async {
      const url = 'https://cdn.example.com/page-storage.svg';
      final bucket = PageStorageBucket();

      await tester.pumpWidget(wrap(const CachedNetworkSvgImage(url), bucket: bucket));
      await settle(tester, () => httpClient.requestCount > 0);
      await tester.pump();
      expect(httpClient.requestCount, 1);

      await cache.evict(ImageCacheKey.fromUrl(url));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(wrap(const CachedNetworkSvgImage(url), bucket: bucket));
      await tester.pump();

      expect(find.byType(SvgPicture), findsOneWidget);
      expect(httpClient.requestCount, 1);
    });

    testWidgets('forwards request headers', (tester) async {
      await tester.pumpWidget(
        wrap(
          const CachedNetworkSvgImage(
            'https://cdn.example.com/headers.svg',
            headers: {'Authorization': 'Bearer t'},
          ),
        ),
      );

      await settle(tester, () => httpClient.requestCount > 0);

      expect(httpClient.lastHeaders?['Authorization'], 'Bearer t');
    });

    testWidgets('writes populated bytes into PageStorage under ImageCacheKey', (
      tester,
    ) async {
      const url = 'https://cdn.example.com/write-storage.svg';
      final bucket = PageStorageBucket();
      final key = GlobalKey();

      await tester.pumpWidget(
        wrap(CachedNetworkSvgImage(url, key: key), bucket: bucket),
      );

      await settle(tester, () => httpClient.requestCount > 0);
      await tester.pump();

      final stored = bucket.readState(
        key.currentContext!,
        identifier: ImageCacheKey.fromUrl(url).value,
      );
      expect(stored, isA<Uint8List>());
      expect(stored, isNotEmpty);
    });

    testWidgets('reloads when url changes', (tester) async {
      await tester.pumpWidget(
        wrap(const CachedNetworkSvgImage('https://cdn.example.com/a.svg')),
      );
      await settle(tester, () => httpClient.requestCount >= 1);
      await tester.pump();

      await tester.pumpWidget(
        wrap(const CachedNetworkSvgImage('https://cdn.example.com/b.svg')),
      );
      await settle(tester, () => httpClient.requestCount >= 2);
      await tester.pump();

      expect(httpClient.requestCount, 2);
      expect(find.byType(SvgPicture), findsOneWidget);
    });
  });
}

class _RecordingClient extends http.BaseClient {
  Exception? throwError;
  int statusCode = 200;
  Future<void>? requestDelay;
  int requestCount = 0;
  Map<String, String>? lastHeaders;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    lastHeaders = Map<String, String>.from(request.headers);

    if (requestDelay case final delay?) {
      await delay;
    }
    if (throwError case final error?) {
      throw error;
    }

    final body = statusCode == 200 ? utf8SvgBytes() : Uint8List(0);
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      statusCode,
      contentLength: body.length,
      request: request,
    );
  }
}

Uint8List utf8SvgBytes() {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>';
  return Uint8List.fromList(svg.codeUnits);
}
