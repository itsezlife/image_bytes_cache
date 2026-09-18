import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

/// Listener / onError contracts for [CachedNetworkSvgImage].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HttpBytesFetcher? fetcher;

  tearDown(() async {
    if (fetcher case final active?) {
      await active.close();
      fetcher = null;
    }
    ImageBytesResolver.debugShared = null;
    HttpBytesFetcher.debugShared = null;
    await ImageBytesCache.resetShared();
  });

  test(
    'H1: ValueNotifier update before addListener does not invoke listener',
    () {
      final notifier = ValueNotifier<CachedNetworkSvgImageState>(
        const CachedNetworkSvgImageLoading(),
      );
      var listenerCalls = 0;

      notifier
        ..value = CachedNetworkSvgImageFailure(
          Exception('boom'),
          StackTrace.current,
        )
        ..addListener(() => listenerCalls++);

      expect(listenerCalls, 0);
      expect(notifier.value, isA<CachedNetworkSvgImageFailure>());
    },
  );

  test(
    'H2: loading→loading does not notify (ValueNotifier == short-circuit)',
    () {
      final notifier = ValueNotifier<CachedNetworkSvgImageState>(
        const CachedNetworkSvgImageLoading(),
      );
      var listenerCalls = 0;
      notifier
        ..addListener(() => listenerCalls++)
        ..value = const CachedNetworkSvgImageLoading();

      expect(listenerCalls, 0);
    },
  );

  testWidgets(
    'onError is invoked when download fails (user symptom)',
    (tester) async {
      fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => throw const SocketException('connection failed'),
        ),
      );
      ImageBytesResolver.debugShared = ImageBytesResolver(
        cache: const NoOpImageBytesCache(),
        fetcher: fetcher!,
      );

      Object? capturedError;
      StackTrace? capturedStack;
      final onErrorCalled = Completer<void>();

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CachedNetworkSvgImage(
                'https://cdn.example.com/logo.svg',
                onError: (error, stackTrace) {
                  capturedError = error;
                  capturedStack = stackTrace;
                  if (!onErrorCalled.isCompleted) {
                    onErrorCalled.complete();
                  }
                },
                errorBuilder: (context, error, stackTrace) => const Text('load-failed'),
              ),
            ),
          ),
        );

        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (!onErrorCalled.isCompleted && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();

      expect(onErrorCalled.isCompleted, isTrue);
      expect(capturedError, isA<SocketException>());
      expect(capturedStack, isNotNull);
    },
  );

  testWidgets(
    'onError is invoked when HTTP returns non-OK status',
    (tester) async {
      fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response('', 404),
        ),
      );
      ImageBytesResolver.debugShared = ImageBytesResolver(
        cache: const NoOpImageBytesCache(),
        fetcher: fetcher!,
      );

      final onErrorCalled = Completer<void>();

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: PageStorage(
              bucket: PageStorageBucket(),
              child: Scaffold(
                body: CachedNetworkSvgImage(
                  'https://cdn.example.com/missing.svg',
                  onError: (error, stackTrace) {
                    if (!onErrorCalled.isCompleted) {
                      onErrorCalled.complete();
                    }
                  },
                  errorBuilder: (_, __, ___) => const Text('err'),
                ),
              ),
            ),
          ),
        );

        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (!onErrorCalled.isCompleted && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();

      expect(onErrorCalled.isCompleted, isTrue);
    },
  );
}
