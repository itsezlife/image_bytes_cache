import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group(r'HttpBytesLoggerMiddleware$Developer', () {
    test('emits downloaded size on success without changing the body', () async {
      final lines = <String>[];
      final client = HttpBytesClient(
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
      addTearDown(client.close);

      final bytes = await client.getBytes(Uri.parse('https://cdn.test/a.png'));
      expect(bytes, Uint8List.fromList([1, 2]));
      expect(lines, hasLength(1));
      expect(
        lines.single,
        matches(r'^\[GET\] https://cdn\.test/a\.png -> 200 \| 2 B \| \d+ms$'),
      );
    });

    test('formats larger sizes compactly', () async {
      final lines = <String>[];
      // 1536 bytes → 1.5 KB
      final payload = Uint8List(1536);
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(payload, 200)),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );
      addTearDown(client.close);

      await client.getBytes(Uri.parse('https://cdn.test/big.png'));
      expect(lines.single, contains('| 1.5 KB |'));
    });

    test('logs buffered body size for coalesce joiners', () async {
      final lines = <String>[];
      final url = Uri.parse('https://cdn.test/join.png');
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      var releases = 0;
      final gate = Completer<void>();
      final client = HttpBytesClient(
        client: MockClient((_) async {
          releases++;
          await gate.future;
          return http.Response.bytes(payload, 200);
        }),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );
      addTearDown(client.close);

      final a = client.getBytes(url);
      final b = client.getBytes(url);
      // Both subscribers join before the mock releases the response.
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      final results = await (a, b).wait;

      expect(releases, 1);
      expect(results.$1, payload);
      expect(results.$2, payload);
      expect(lines, hasLength(2));
      for (final line in lines) {
        expect(line, contains('| 4 B |'));
        expect(line, contains('-> 200'));
      }
    });

    test('emits typed error code then rethrows', () async {
      final lines = <String>[];
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response('gone', 404)),
        middlewares: <HttpBytesMiddleware>[
          HttpBytesLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.test/missing.png')),
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

      final ok = HttpBytesClient(
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

      final bad = HttpBytesClient(
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
      final client = HttpBytesClient(
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
      addTearDown(client.close);

      await client.getBytes(Uri.parse('https://cdn.test/req.png'));
      expect(lines, hasLength(2));
      expect(lines.first, '[GET] https://cdn.test/req.png');
      expect(
        lines.last,
        matches(r'^\[GET\] https://cdn\.test/req\.png -> 200 \| 1 B \| \d+ms$'),
      );
    });

    test('emission failures do not fail the send', () async {
      final client = HttpBytesClient(
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
      addTearDown(client.close);

      final bytes = await client.getBytes(Uri.parse('https://cdn.test/safe.png'));
      expect(bytes, Uint8List.fromList([9]));
    });

    test('outermost over Retry observes post-retry latency', () async {
      var attempts = 0;
      final lines = <String>[];
      final client = HttpBytesClient(
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
      addTearDown(client.close);

      await client.getBytes(Uri.parse('https://cdn.test/flaky.png'));
      expect(attempts, 2);
      expect(lines, hasLength(1));
      expect(lines.single, contains('-> 200'));
      expect(lines.single, contains('| 1 B |'));
      expect(lines.single, isNot(contains('service_unavailable')));
    });
  });
}
