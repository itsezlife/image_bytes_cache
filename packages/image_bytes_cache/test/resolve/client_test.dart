import 'dart:async';
import 'dart:typed_data';

import 'package:cancel_token/cancel_token.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/src/http/http_bytes_client.dart';
import 'package:image_bytes_cache/src/http/middlewares/timeout_middleware.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('HttpBytesClient.getBytes', () {
    test('returns response body bytes on 200', () async {
      final expected = Uint8List.fromList([1, 2, 3, 4]);
      final client = HttpBytesClient(
        client: MockClient((request) async {
          expect(request.url, Uri.parse('https://cdn.example.com/a.svg'));
          return http.Response.bytes(expected, 200);
        }),
      );
      addTearDown(client.close);

      final bytes = await client.getBytes(
        Uri.parse('https://cdn.example.com/a.svg'),
      );

      expect(bytes, expected);
    });

    test(r'throws HttpBytesException$Request on 404', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response('gone', 404),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.example.com/missing.svg')),
        throwsA(
          isA<HttpBytesException$Request>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.data, 'data', isA<Map<String, Object?>>()),
        ),
      );
    });

    test(r'throws HttpBytesException$Authentication on 401', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response('auth', 401),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.example.com/private.svg')),
        throwsA(
          isA<HttpBytesException$Authentication>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });

    test(r'throws HttpBytesException$Server on 503', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response(
            'down',
            503,
            headers: {'retry-after': '12'},
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.example.com/busy.svg')),
        throwsA(
          isA<HttpBytesException$Server>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having(
                (e) => (e.data! as Map)['retry-after'],
                'retry-after',
                '12',
              ),
        ),
      );
    });

    test(r'throws HttpBytesException$Internal on empty body', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List(0), 200),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.example.com/empty.svg')),
        throwsA(
          isA<HttpBytesException$Internal>().having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });

    test(r'throws HttpBytesException$Network when the client fails without a response', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => throw http.ClientException('socket hung up'),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.example.com/down.svg')),
        throwsA(isA<HttpBytesException$Network>()),
      );
    });

    test('coalesces concurrent identical url and headers into one GET', () async {
      var hits = 0;
      final release = Completer<void>();
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          await release.future;
          return http.Response.bytes(Uint8List.fromList([9]), 200);
        }),
      );
      addTearDown(client.close);

      final url = Uri.parse('https://cdn.example.com/same.svg');
      const headers = {'Authorization': 'Bearer x'};

      final a = client.getBytes(url, headers: headers);
      final b = client.getBytes(url, headers: headers);
      release.complete();

      final results = await (a, b).wait;
      expect(results.$1, Uint8List.fromList([9]));
      expect(results.$2, Uint8List.fromList([9]));
      expect(hits, 1);
    });

    test(
      'canceling one coalesced subscriber leaves the other running',
      () async {
        var hits = 0;
        var aborted = false;
        final release = Completer<void>();
        final tokenA = CancelToken();
        final tokenB = CancelToken();
        final client = HttpBytesClient(
          middlewares: const [],
          client: _AbortHonoringClient(
            onRequest: (request) {
              hits++;
              if (request case http.Abortable(:final abortTrigger?)) {
                unawaited(
                  abortTrigger.whenComplete(() {
                    aborted = true;
                    if (!release.isCompleted) {
                      release.completeError(StateError('flight aborted'));
                    }
                  }),
                );
              }
            },
            bodyAfter: () async {
              await release.future;
              return Uint8List.fromList([9]);
            },
          ),
        );
        addTearDown(client.close);

        final url = Uri.parse('https://cdn.example.com/coalesce-cancel-one.svg');
        final a = client.getBytes(url, cancelToken: tokenA);
        final b = client.getBytes(url, cancelToken: tokenB);
        await Future<void>.delayed(Duration.zero);

        tokenA.cancel();
        await expectLater(a, throwsA(isA<HttpBytesException$Cancelled>()));
        expect(aborted, isFalse);

        release.complete();
        expect(await b, Uint8List.fromList([9]));
        expect(hits, 1);
        expect(aborted, isFalse);
      },
    );

    test(
      'canceling the last coalesced subscriber aborts the flight',
      () async {
        var aborted = false;
        final never = Completer<void>();
        final tokenA = CancelToken();
        final tokenB = CancelToken();
        final client = HttpBytesClient(
          middlewares: const [],
          client: _AbortHonoringClient(
            onRequest: (request) {
              if (request case http.Abortable(:final abortTrigger?)) {
                unawaited(abortTrigger.whenComplete(() => aborted = true));
              }
            },
            bodyAfter: () async {
              await never.future;
              return Uint8List.fromList([9]);
            },
          ),
        );
        addTearDown(client.close);

        final url = Uri.parse('https://cdn.example.com/coalesce-cancel-last.svg');
        final a = client.getBytes(url, cancelToken: tokenA);
        final b = client.getBytes(url, cancelToken: tokenB);
        await Future<void>.delayed(Duration.zero);

        tokenA.cancel();
        await expectLater(a, throwsA(isA<HttpBytesException$Cancelled>()));
        expect(aborted, isFalse);

        tokenB.cancel();
        await expectLater(b, throwsA(isA<HttpBytesException$Cancelled>()));
        await Future<void>.delayed(Duration.zero);
        expect(aborted, isTrue);
      },
    );

    test('middleware injects headers onto the wire request', () async {
      String? seenAuth;
      HttpBytesHandler injectAuth(HttpBytesHandler inner) {
        return (request, context) {
          return inner(
            request.clone(
              headers: {
                ...request.headers,
                'Authorization': 'Bearer secret',
              },
            ),
            context,
          );
        };
      }

      final client = HttpBytesClient(
        middlewares: [injectAuth],
        client: MockClient((request) async {
          seenAuth = request.headers['Authorization'];
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(client.close);

      await client.getBytes(Uri.parse('https://cdn.example.com/auth.svg'));
      expect(seenAuth, 'Bearer secret');
    });

    test('coalesce identity unchanged when starter supplies onBytesProgress', () async {
      var hits = 0;
      final release = Completer<void>();
      final reports = <(int cumulative, int? total)>[];
      final client = HttpBytesClient(
        client: _GatedChunkedBodyClient(
          release: release,
          onSend: () => hits++,
          chunks: [
            [1, 2],
          ],
          contentLength: 2,
        ),
      );
      addTearDown(client.close);

      final url = Uri.parse('https://cdn.example.com/coalesce-progress.svg');
      final a = client.getBytes(
        url,
        onBytesProgress: (cumulative, total) => reports.add((cumulative, total)),
      );
      final b = client.getBytes(
        url,
        onBytesProgress: (_, __) => fail('joiner sink must not run'),
      );
      release.complete();

      final results = await (a, b).wait;
      expect(results.$1, Uint8List.fromList([1, 2]));
      expect(results.$2, Uint8List.fromList([1, 2]));
      expect(hits, 1);
      expect(reports, [(2, 2)]);
    });

    test('does not coalesce when headers differ', () async {
      var hits = 0;
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(Uint8List.fromList([hits]), 200);
        }),
      );
      addTearDown(client.close);

      final url = Uri.parse('https://cdn.example.com/auth.svg');
      await (
        client.getBytes(url, headers: {'Authorization': 'a'}),
        client.getBytes(url, headers: {'Authorization': 'b'}),
      ).wait;

      expect(hits, 2);
    });

    test('does not coalesce URL-with-|… into clean URL plus those headers', () async {
      var hits = 0;
      final release = Completer<void>();
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          await release.future;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(client.close);

      final poisoned = Uri.parse('https://cdn.example.com/a.svg|authorization=Bearer x');
      final clean = Uri.parse('https://cdn.example.com/a.svg');

      final a = client.getBytes(poisoned);
      final b = client.getBytes(clean, headers: const {'Authorization': 'Bearer x'});
      release.complete();

      await (a, b).wait;
      expect(hits, 2);
    });

    test('limits concurrent GETs to maxConcurrent', () async {
      var inFlight = 0;
      var peak = 0;
      final release = Completer<void>();
      final client = HttpBytesClient(
        maxConcurrent: 2,
        client: MockClient((_) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await release.future;
          inFlight--;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(client.close);

      final futures = [
        for (var i = 0; i < 5; i++) client.getBytes(Uri.parse('https://cdn.example.com/$i.svg')),
      ];

      await Future<void>.delayed(Duration.zero);
      expect(peak, 2);
      expect(inFlight, 2);

      release.complete();
      await Future.wait(futures);
      expect(peak, 2);
    });

    test(r'throws HttpBytesException$Timeout when GET stalls past connect Timeout', () async {
      final client = HttpBytesClient(
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesTimeoutMiddleware(
            connectTimeout: Duration(milliseconds: 20),
            receiveTimeout: Duration(seconds: 30),
          ),
        ],
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.example.com/slow.svg')),
        throwsA(
          isA<HttpBytesException$Timeout>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
    });

    test(r'throws HttpBytesException$Timeout when body idle past receive Timeout', () async {
      final client = HttpBytesClient(
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesTimeoutMiddleware(
            connectTimeout: Duration(seconds: 30),
            receiveTimeout: Duration(milliseconds: 40),
          ),
        ],
        client: _StallingBodyClient(
          firstChunk: [1],
          stall: const Duration(seconds: 5),
          secondChunk: [2],
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.example.com/stall.svg')),
        throwsA(
          isA<HttpBytesException$Timeout>().having(
            (e) => e.code,
            'code',
            'receive_timeout',
          ),
        ),
      );
    });

    test('empty middleware list does not apply default Timeout', () async {
      final client = HttpBytesClient(
        middlewares: const [],
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response.bytes(Uint8List.fromList([7]), 200);
        }),
      );
      addTearDown(client.close);

      final bytes = await client.getBytes(
        Uri.parse('https://cdn.example.com/no-timeout.svg'),
      );
      expect(bytes, Uint8List.fromList([7]));
    });

    test('timeout aborts AbortableRequest when the client honors abortTrigger', () async {
      var sawAbortable = false;
      var abortCompleted = false;
      final client = HttpBytesClient(
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesTimeoutMiddleware(
            connectTimeout: Duration(milliseconds: 30),
            receiveTimeout: Duration(seconds: 30),
          ),
        ],
        client: _AbortHonoringClient(
          onRequest: (request) {
            if (request case http.Abortable(:final abortTrigger?)) {
              sawAbortable = true;
              unawaited(abortTrigger.whenComplete(() => abortCompleted = true));
            }
          },
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.getBytes(Uri.parse('https://cdn.example.com/abort.svg')),
        throwsA(isA<HttpBytesException$Timeout>()),
      );
      // Let abortTrigger.whenComplete run after HttpBytesTimeoutMiddleware cancels the token.
      await Future<void>.delayed(Duration.zero);
      expect(sawAbortable, isTrue);
      expect(abortCompleted, isTrue);
    });

    test(r'CancelToken cancel surfaces HttpBytesException$Cancelled', () async {
      final token = CancelToken();
      final client = HttpBytesClient(
        middlewares: const [],
        client: _AbortHonoringClient(
          onRequest: (request) {
            if (request case http.Abortable(:final abortTrigger?)) {
              unawaited(abortTrigger);
            }
          },
        ),
      );
      addTearDown(client.close);

      final future = client.getBytes(
        Uri.parse('https://cdn.example.com/cancel.svg'),
        cancelToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();

      await expectLater(future, throwsA(isA<HttpBytesException$Cancelled>()));
    });

    test(r'already-cancelled CancelToken surfaces HttpBytesException$Cancelled', () async {
      final token = CancelToken()..cancel();
      final client = HttpBytesClient(
        middlewares: const [],
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
      );
      addTearDown(client.close);

      expect(
        () => client.getBytes(
          Uri.parse('https://cdn.example.com/pre-cancelled.svg'),
          cancelToken: token,
        ),
        throwsA(isA<HttpBytesException$Cancelled>()),
      );
    });

    test(r'rejects getBytes after close with HttpBytesException$Internal', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
      );
      await client.close();

      expect(
        () => client.getBytes(Uri.parse('https://cdn.example.com/a.svg')),
        throwsA(isA<HttpBytesException$Internal>()),
      );
    });

    test('reports cumulative bytes and total while reading the body', () async {
      final chunks = <List<int>>[
        [1, 2],
        [3, 4, 5],
      ];
      final reports = <(int cumulative, int? total)>[];
      final client = HttpBytesClient(
        client: _ChunkedBodyClient(
          chunks: chunks,
          contentLength: 5,
        ),
      );
      addTearDown(client.close);

      final bytes = await client.getBytes(
        Uri.parse('https://cdn.example.com/progress.svg'),
        onBytesProgress: (cumulative, total) => reports.add((cumulative, total)),
      );

      expect(bytes, Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(reports, [(2, 5), (5, 5)]);
    });

    test('reports null total when Content-Length is unknown', () async {
      final reports = <(int cumulative, int? total)>[];
      final client = HttpBytesClient(
        client: _ChunkedBodyClient(
          chunks: [
            [9, 9],
          ],
        ),
      );
      addTearDown(client.close);

      await client.getBytes(
        Uri.parse('https://cdn.example.com/no-length.svg'),
        onBytesProgress: (cumulative, total) => reports.add((cumulative, total)),
      );

      expect(reports, [(2, null)]);
    });

    test('does not invent progress when onBytesProgress is omitted', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200),
        ),
      );
      addTearDown(client.close);

      final bytes = await client.getBytes(
        Uri.parse('https://cdn.example.com/no-sink.svg'),
      );

      expect(bytes, Uint8List.fromList([1, 2, 3]));
    });

    test('middleware list order is outermost first (reverse-fold)', () async {
      final order = <String>[];
      HttpBytesMiddleware named(String label) {
        return (inner) {
          return (request, context) async {
            order.add('in:$label');
            final response = await inner(request, context);
            order.add('out:$label');
            return response;
          };
        };
      }

      final client = HttpBytesClient(
        middlewares: [named('outer'), named('inner')],
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
      );
      addTearDown(client.close);

      await client.getBytes(Uri.parse('https://cdn.example.com/order.svg'));
      expect(order, ['in:outer', 'in:inner', 'out:inner', 'out:outer']);
    });
  });

  group('HttpBytesClient.configure', () {
    tearDown(() async {
      await HttpBytesClient.resetShared();
    });

    test('closes the previous shared instance before replace', () async {
      final first = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
      );
      final second = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([2]), 200),
        ),
      );

      await HttpBytesClient.configure(first);
      expect(identical(HttpBytesClient.shared(), first), isTrue);

      await HttpBytesClient.configure(second);
      expect(identical(HttpBytesClient.shared(), second), isTrue);
      expect(
        () => first.getBytes(Uri.parse('https://cdn.example.com/closed.svg')),
        throwsA(isA<HttpBytesException$Internal>()),
        reason: 'configure must close the previous client',
      );
    });

    test('resetShared closes then clears', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
      );
      await HttpBytesClient.configure(client);

      await HttpBytesClient.resetShared();
      expect(
        () => client.getBytes(Uri.parse('https://cdn.example.com/closed.svg')),
        throwsA(isA<HttpBytesException$Internal>()),
      );
      expect(
        identical(HttpBytesClient.shared(), client),
        isFalse,
        reason: 'shared must not keep returning the closed instance',
      );
    });

    test('ImageBytesCache.resetShared also clears the configured client', () async {
      final client = HttpBytesClient(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
      );
      await HttpBytesClient.configure(client);

      await ImageBytesCache.resetShared();
      expect(
        () => client.getBytes(Uri.parse('https://cdn.example.com/closed.svg')),
        throwsA(isA<HttpBytesException$Internal>()),
        reason: 'cache resetShared must tear down client shared wiring',
      );
    });
  });
}

/// Streams one chunk, stalls, then streams another — for receive-timeout tests.
final class _StallingBodyClient extends http.BaseClient {
  _StallingBodyClient({
    required this.firstChunk,
    required this.stall,
    required this.secondChunk,
  });

  final List<int> firstChunk;
  final Duration stall;
  final List<int> secondChunk;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      () async* {
        yield firstChunk;
        await Future<void>.delayed(stall);
        yield secondChunk;
      }(),
      200,
      contentLength: firstChunk.length + secondChunk.length,
      request: request,
    );
  }
}

/// Streams response body chunks so progress can be observed mid-read.
final class _ChunkedBodyClient extends http.BaseClient {
  _ChunkedBodyClient({
    required this.chunks,
    this.contentLength,
  });

  final List<List<int>> chunks;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.fromIterable(chunks),
      200,
      contentLength: contentLength,
      request: request,
    );
  }
}

/// Like [_ChunkedBodyClient], but waits on [release] before streaming so two
/// callers can join the same in-flight GET.
final class _GatedChunkedBodyClient extends http.BaseClient {
  _GatedChunkedBodyClient({
    required this.release,
    required this.onSend,
    required this.chunks,
    this.contentLength,
  });

  final Completer<void> release;
  final void Function() onSend;
  final List<List<int>> chunks;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onSend();
    await release.future;
    return http.StreamedResponse(
      Stream.fromIterable(chunks),
      200,
      contentLength: contentLength,
      request: request,
    );
  }
}

/// Test client that honors [http.Abortable.abortTrigger].
///
/// When [bodyAfter] is null, waits for abort then throws
/// [http.RequestAbortedException] (legacy cancel/timeout tests).
/// When [bodyAfter] is set, races abort against the body future — abort wins
/// with [http.RequestAbortedException], otherwise returns a 200 with those bytes.
final class _AbortHonoringClient extends http.BaseClient {
  _AbortHonoringClient({
    required this.onRequest,
    this.bodyAfter,
  });

  final void Function(http.BaseRequest request) onRequest;
  final Future<Uint8List> Function()? bodyAfter;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onRequest(request);
    if (request case http.Abortable(:final abortTrigger?)) {
      final body = bodyAfter;
      if (body == null) {
        await abortTrigger;
        throw http.RequestAbortedException(request.url);
      }

      final bytes = await Future.any<Uint8List>([
        body(),
        abortTrigger.then((_) => throw http.RequestAbortedException(request.url)),
      ]);
      return http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length,
        request: request,
      );
    }
    throw StateError('expected AbortableRequest with abortTrigger');
  }
}
