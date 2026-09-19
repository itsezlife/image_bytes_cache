import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group(r'HttpBytesLoggerMiddleware$Developer', () {
    test('emits on success without changing the body', () async {
      final lines = <String>[];
      final fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1, 2]), 200),
        ),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );
      addTearDown(fetcher.close);

      final bytes = await fetcher.getBytes(Uri.parse('https://cdn.test/a.png'));
      expect(bytes, Uint8List.fromList([1, 2]));
      expect(lines, hasLength(1));
      expect(lines.single, contains('[GET] https://cdn.test/a.png'));
      expect(lines.single, contains('-> 200'));
      expect(lines.single, contains('ms'));
    });

    test('emits typed error code then rethrows', () async {
      final lines = <String>[];
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async => http.Response('gone', 404)),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );
      addTearDown(fetcher.close);

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/missing.png')),
        throwsA(isA<HttpBytesException$Request>()),
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('-> not_found'));
    });

    test('logResponse / logError flags suppress emission', () async {
      final lines = <String>[];
      void capture(String message, {required int level, StackTrace? stackTrace}) {
        lines.add(message);
      }

      final ok = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            logResponse: false,
            debugEmit: capture,
          ),
        ],
      );
      addTearDown(ok.close);
      await ok.getBytes(Uri.parse('https://cdn.test/ok.png'));
      expect(lines, isEmpty);

      final bad = HttpBytesFetcher(
        client: MockClient((_) async => http.Response('x', 500)),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            logError: false,
            debugEmit: capture,
          ),
        ],
      );
      addTearDown(bad.close);
      await expectLater(
        bad.getBytes(Uri.parse('https://cdn.test/err.png')),
        throwsA(isA<HttpBytesException$Server>()),
      );
      expect(lines, isEmpty);
    });

    test('logRequest emits before the handler', () async {
      final lines = <String>[];
      final fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            logRequest: true,
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );
      addTearDown(fetcher.close);

      await fetcher.getBytes(Uri.parse('https://cdn.test/req.png'));
      expect(lines, hasLength(2));
      expect(lines.first, '[GET] https://cdn.test/req.png');
      expect(lines.last, contains('-> 200'));
    });

    test('emission failures do not fail the send', () async {
      final fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([9]), 200),
        ),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              throw StateError('sink broken');
            },
          ),
        ],
      );
      addTearDown(fetcher.close);

      final bytes = await fetcher.getBytes(Uri.parse('https://cdn.test/safe.png'));
      expect(bytes, Uint8List.fromList([9]));
    });

    test('outermost over Retry observes post-retry latency', () async {
      var attempts = 0;
      final lines = <String>[];
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async {
          attempts++;
          if (attempts == 1) {
            return http.Response('busy', 503, headers: {'retry-after': '0'});
          }
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
          HttpBytesRetryMiddleware(
            backoff: const HttpBytesRetryBackoff(
              maxRetries: 2,
              initialDelay: Duration.zero,
              maxDelay: Duration.zero,
            ),
            random: math.Random(1),
          ),
        ],
      );
      addTearDown(fetcher.close);

      await fetcher.getBytes(Uri.parse('https://cdn.test/flaky.png'));
      expect(attempts, 2);
      expect(lines, hasLength(1));
      expect(lines.single, contains('-> 200'));
      expect(lines.single, isNot(contains('service_unavailable')));
    });
  });
}
