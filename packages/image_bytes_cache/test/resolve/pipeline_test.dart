import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:test/test.dart';

/// End-to-end coverage for the real [HttpBytesFetcher] + middleware pipeline
/// (Retry → Timeout → http) over a [MockClient], mirroring api_client's
/// `http_pipeline_test.dart` for the image-GET surface.
void main() {
  const fastBackoff = HttpBytesRetryBackoff(
    maxRetries: 2,
    initialDelay: Duration(milliseconds: 1),
    maxDelay: Duration(milliseconds: 1),
  );

  HttpBytesFetcher buildFetcher({
    required http.Client client,
    bool Function(Object error, int attempt)? retryEvaluator,
    Duration connectTimeout = const Duration(seconds: 5),
    Duration receiveTimeout = const Duration(seconds: 5),
    bool Function(int statusCode)? validateStatus,
    List<HttpBytesMiddleware>? extraOuter,
  }) {
    final fetcher = HttpBytesFetcher(
      client: client,
      validateStatus: validateStatus,
      middlewares: <HttpBytesMiddleware>[
        ...?extraOuter,
        HttpBytesRetryMiddleware(
          backoff: fastBackoff,
          retryEvaluator: retryEvaluator,
          random: math.Random(1),
        ),
        HttpBytesTimeoutMiddleware(
          connectTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
        ),
      ],
    );
    addTearDown(fetcher.close);
    return fetcher;
  }

  group('HttpBytesRetryMiddleware', () {
    test('retries a 503 then succeeds', () async {
      var attempts = 0;
      final fetcher = buildFetcher(
        client: MockClient((_) async {
          attempts++;
          return attempts == 1 ? http.Response('busy', 503) : http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );

      final bytes = await fetcher.getBytes(Uri.parse('https://cdn.test/data'));
      expect(bytes, Uint8List.fromList([1]));
      expect(attempts, 2);
    });

    test('retries a network failure then succeeds', () async {
      var attempts = 0;
      final fetcher = buildFetcher(
        client: MockClient((_) async {
          attempts++;
          if (attempts == 1) {
            throw http.ClientException('socket hung up');
          }
          return http.Response.bytes(Uint8List.fromList([7]), 200);
        }),
      );

      final bytes = await fetcher.getBytes(Uri.parse('https://cdn.test/data'));
      expect(bytes, Uint8List.fromList([7]));
      expect(attempts, 2);
    });

    test('does not retry a non-transient 404 (default policy)', () async {
      var attempts = 0;
      final fetcher = buildFetcher(
        client: MockClient((_) async {
          attempts++;
          return http.Response('missing', 404);
        }),
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/data')),
        throwsA(isA<HttpBytesException$Request>()),
      );
      expect(attempts, 1, reason: '4xx client errors are not transient');
    });

    test('a custom retryEvaluator overrides the default policy', () async {
      var attempts = 0;
      final fetcher = buildFetcher(
        client: MockClient((_) async {
          attempts++;
          return attempts == 1 ? http.Response('missing', 404) : http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
        retryEvaluator: (_, _) => true,
      );

      final bytes = await fetcher.getBytes(Uri.parse('https://cdn.test/data'));
      expect(bytes, Uint8List.fromList([1]));
      expect(attempts, 2);
    });

    test('skips retry when no-retry context is set', () async {
      var attempts = 0;
      final fetcher = buildFetcher(
        client: MockClient((_) async {
          attempts++;
          return http.Response('busy', 503);
        }),
      );

      await expectLater(
        fetcher.send(
          HttpBytesRequest(
            http.Request('GET', Uri.parse('https://cdn.test/once')),
          ),
          context: {HttpBytesContextKeys.noRetry: true},
        ),
        throwsA(isA<HttpBytesException$Server>()),
      );
      expect(attempts, 1);
    });

    test('honors delta-seconds Retry-After on 503', () async {
      var attempts = 0;
      final sw = Stopwatch();
      final fetcher = buildFetcher(
        client: MockClient((_) async {
          attempts++;
          if (attempts == 1) {
            sw.start();
            return http.Response(
              'busy',
              503,
              headers: {'retry-after': '0'},
            );
          }
          sw.stop();
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );

      await fetcher.getBytes(Uri.parse('https://cdn.test/data'));
      expect(attempts, 2);
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('the total budget (maxElapsed) stops retries early', () async {
      var attempts = 0;
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async {
          attempts++;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response('busy', 503);
        }),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesRetryMiddleware(
            backoff: const HttpBytesRetryBackoff(
              maxRetries: 3,
              initialDelay: Duration(milliseconds: 1),
              maxDelay: Duration(milliseconds: 1),
              maxElapsed: Duration(milliseconds: 10),
            ),
            random: math.Random(1),
          ),
        ],
      );
      addTearDown(fetcher.close);

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/data')),
        throwsA(isA<HttpBytesException$Server>()),
      );
      expect(attempts, 1, reason: 'budget exhausted after the first attempt — no retry');
    });
  });

  group('HttpBytesRetryMiddleware.defaultRetryEvaluator', () {
    test('retries only transient network/5xx/429 errors', () {
      HttpBytesException ex(int code) => switch (code) {
        0 => HttpBytesException$Network(
          code: 'x',
          message: 'x',
          statusCode: code,
        ),
        401 || 403 => HttpBytesException$Authentication(
          code: 'x',
          message: 'x',
          statusCode: code,
        ),
        >= 500 => HttpBytesException$Server(
          code: 'x',
          message: 'x',
          statusCode: code,
        ),
        _ => HttpBytesException$Request(
          code: 'x',
          message: 'x',
          statusCode: code,
        ),
      };
      for (final code in [0, 408, 425, 429, 500, 502, 503, 504, 509]) {
        expect(
          HttpBytesRetryMiddleware.defaultRetryEvaluator(ex(code), 0),
          isTrue,
          reason: 'transient $code',
        );
      }
      for (final code in [400, 401, 403, 404, 409, 422, 501]) {
        expect(
          HttpBytesRetryMiddleware.defaultRetryEvaluator(ex(code), 0),
          isFalse,
          reason: 'non-transient $code',
        );
      }
    });

    test('never retries auth / cancelled / timeout', () {
      expect(
        HttpBytesRetryMiddleware.defaultRetryEvaluator(
          const HttpBytesException$Authentication(
            code: 'unauthorized',
            message: 'x',
            statusCode: 401,
          ),
          0,
        ),
        isFalse,
      );
      expect(
        HttpBytesRetryMiddleware.defaultRetryEvaluator(
          const HttpBytesException$Cancelled(),
          0,
        ),
        isFalse,
      );
      expect(
        HttpBytesRetryMiddleware.defaultRetryEvaluator(
          const HttpBytesException$Timeout(
            code: 'timeout',
            message: 'x',
            statusCode: 408,
            duration: Duration(milliseconds: 1),
          ),
          0,
        ),
        isFalse,
      );
    });
  });

  group('Timeout', () {
    test(r'throws $Timeout, does not retry, and aborts the socket', () async {
      var attempts = 0;
      var aborted = false;
      final fetcher = buildFetcher(
        connectTimeout: const Duration(milliseconds: 30),
        client: MockClient.streaming((request, _) async {
          attempts++;
          (request as http.Abortable).abortTrigger?.then((_) => aborted = true).ignore();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
        }),
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/slow')),
        throwsA(isA<HttpBytesException$Timeout>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(attempts, 1, reason: 'timeout is not retried');
      expect(aborted, isTrue, reason: 'timeout cancels the request token');
    });

    test('receive timeout fires when the body stalls mid-stream and aborts', () async {
      final body = StreamController<List<int>>();
      var aborted = false;
      final fetcher = HttpBytesFetcher(
        client: MockClient.streaming((request, _) async {
          (request as http.Abortable).abortTrigger?.then((_) => aborted = true).ignore();
          body.add(const [1, 2]);
          return http.StreamedResponse(body.stream, 200, contentLength: 10);
        }),
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesTimeoutMiddleware(
            connectTimeout: Duration(seconds: 5),
            receiveTimeout: Duration(milliseconds: 30),
          ),
        ],
      );
      addTearDown(fetcher.close);

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/slow')),
        throwsA(
          isA<HttpBytesException$Timeout>().having(
            (e) => e.code,
            'code',
            'receive_timeout',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(aborted, isTrue, reason: 'receive timeout cancels the request token');
      await body.close();
    });
  });

  group('Cancellation', () {
    test(r'cancel() surfaces $Cancelled to the caller', () async {
      final fetcher = buildFetcher(
        client: MockClient.streaming((request, _) async {
          await (request as http.Abortable).abortTrigger;
          throw http.RequestAbortedException(request.url);
        }),
      );

      final token = CancelToken();
      final future = fetcher.getBytes(
        Uri.parse('https://cdn.test/slow'),
        cancelToken: token,
      );
      unawaited(Future<void>.delayed(const Duration(milliseconds: 20), token.cancel));

      await expectLater(future, throwsA(isA<HttpBytesException$Cancelled>()));
    });

    test(r'already-cancelled CancelToken surfaces $Cancelled without a wire hit', () async {
      var attempts = 0;
      final fetcher = buildFetcher(
        client: MockClient((_) async {
          attempts++;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );

      expect(
        () => fetcher.getBytes(
          Uri.parse('https://cdn.test/pre'),
          cancelToken: CancelToken()..cancel(),
        ),
        throwsA(isA<HttpBytesException$Cancelled>()),
      );
      expect(attempts, 0);
    });
  });

  group('validateStatus', () {
    test('a custom predicate makes a 404 a success', () async {
      final fetcher = buildFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([9]), 404),
        ),
        validateStatus: (c) => c == 404,
      );

      final bytes = await fetcher.getBytes(Uri.parse('https://cdn.test/x'));
      expect(bytes, Uint8List.fromList([9]));
    });

    test('a predicate rejecting 200 throws', () async {
      final fetcher = buildFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
        validateStatus: (_) => false,
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/x')),
        throwsA(isA<HttpBytesException>()),
      );
    });

    test(r'the default still maps 401 to $Authentication', () async {
      final fetcher = buildFetcher(
        client: MockClient((_) async => http.Response('no', 401)),
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/x')),
        throwsA(isA<HttpBytesException$Authentication>()),
      );
    });

    test(r'the default still maps 403 to $Authentication', () async {
      final fetcher = buildFetcher(
        client: MockClient((_) async => http.Response('no', 403)),
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/x')),
        throwsA(isA<HttpBytesException$Authentication>()),
      );
    });
  });

  group('Receive progress', () {
    test('reports cumulative bytes with total from content-length', () async {
      final events = <(int, int?)>[];
      final fetcher = buildFetcher(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable([
              [1, 2, 3],
              [4, 5],
            ]),
            200,
            contentLength: 5,
          ),
        ),
      );

      final bytes = await fetcher.getBytes(
        Uri.parse('https://cdn.test/x'),
        onBytesProgress: (received, total) => events.add((received, total)),
      );
      expect(bytes, Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(events, [(3, 5), (5, 5)]);
    });

    test('reports null total when Content-Length is unknown', () async {
      final events = <(int, int?)>[];
      final fetcher = buildFetcher(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable([
              [9, 9],
            ]),
            200,
          ),
        ),
      );

      await fetcher.getBytes(
        Uri.parse('https://cdn.test/x'),
        onBytesProgress: (received, total) => events.add((received, total)),
      );
      expect(events, [(2, null)]);
    });
  });

  group('canBeRetried', () {
    test('true for Request / AbortableRequest, false for multipart/streamed', () {
      final uri = Uri.parse('https://cdn.test/x');
      expect(HttpBytesRequest(http.Request('GET', uri)).canBeRetried, isTrue);
      expect(
        HttpBytesRequest(
          http.AbortableRequest('GET', uri, abortTrigger: Completer<void>().future),
        ).canBeRetried,
        isTrue,
      );
      expect(
        HttpBytesRequest(http.MultipartRequest('POST', uri)).canBeRetried,
        isFalse,
      );
      expect(
        HttpBytesRequest(http.StreamedRequest('POST', uri)).canBeRetried,
        isFalse,
      );
    });
  });

  group('Full pipeline (Bearer → Retry → Timeout)', () {
    test('attaches Bearer, retries 503, then succeeds', () async {
      var attempts = 0;
      String? seenAuth;
      final fetcher = buildFetcher(
        extraOuter: <HttpBytesMiddleware>[
          HttpBytesBearerMiddleware(getToken: () async => 'tok'),
        ],
        client: MockClient((request) async {
          attempts++;
          seenAuth = request.headers['authorization'];
          return attempts == 1 ? http.Response('busy', 503) : http.Response.bytes(Uint8List.fromList([3]), 200);
        }),
      );

      final bytes = await fetcher.getBytes(Uri.parse('https://cdn.test/img'));
      expect(bytes, Uint8List.fromList([3]));
      expect(attempts, 2);
      expect(seenAuth, 'Bearer tok');
    });

    test('middleware list order is outermost first', () async {
      final order = <String>[];
      HttpBytesMiddleware named(String label) => (inner) {
        return (request, context) async {
          order.add('in:$label');
          final response = await inner(request, context);
          order.add('out:$label');
          return response;
        };
      };

      final fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
        middlewares: <HttpBytesMiddleware>[named('outer'), named('inner')],
      );
      addTearDown(fetcher.close);

      await fetcher.getBytes(Uri.parse('https://cdn.test/order'));
      expect(order, ['in:outer', 'in:inner', 'out:inner', 'out:outer']);
    });
  });

  group('Status → exception mapping', () {
    Future<HttpBytesException> failOf(Future<Object?> Function() send) async {
      try {
        await send();
      } on HttpBytesException catch (e) {
        return e;
      }
      throw StateError('expected an HttpBytesException');
    }

    test('429 is Request and carries retry-after', () async {
      final fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response('slow', 429, headers: {'retry-after': '5'}),
        ),
        middlewares: const [],
      );
      addTearDown(fetcher.close);

      final e = await failOf(
        () => fetcher.getBytes(Uri.parse('https://cdn.test/x')),
      );
      expect(e, isA<HttpBytesException$Request>());
      expect((e.data! as Map)['retry-after'], '5');
    });

    test('500 is Server', () async {
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async => http.Response('boom', 500)),
        middlewares: const [],
      );
      addTearDown(fetcher.close);

      final e = await failOf(
        () => fetcher.getBytes(Uri.parse('https://cdn.test/x')),
      );
      expect(e, isA<HttpBytesException$Server>());
    });
  });
}
