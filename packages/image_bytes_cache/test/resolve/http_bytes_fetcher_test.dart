import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/src/http_bytes_fetcher.dart';
import 'package:test/test.dart';

void main() {
  group('HttpBytesFetcher.getBytes', () {
    test('returns response body bytes on 200', () async {
      final expected = Uint8List.fromList([1, 2, 3, 4]);
      final fetcher = HttpBytesFetcher(
        client: MockClient((request) async {
          expect(request.url, Uri.parse('https://cdn.example.com/a.svg'));
          return http.Response.bytes(expected, 200);
        }),
      );
      addTearDown(fetcher.close);

      final bytes = await fetcher.getBytes(
        Uri.parse('https://cdn.example.com/a.svg'),
      );

      expect(bytes, expected);
    });

    test('throws ClientException on non-2xx', () async {
      final fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response('gone', 404),
        ),
      );
      addTearDown(fetcher.close);

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.example.com/missing.svg')),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('throws StateError on empty body', () async {
      final fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List(0), 200),
        ),
      );
      addTearDown(fetcher.close);

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.example.com/empty.svg')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });

    test('coalesces concurrent identical url and headers into one GET', () async {
      var hits = 0;
      final release = Completer<void>();
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async {
          hits++;
          await release.future;
          return http.Response.bytes(Uint8List.fromList([9]), 200);
        }),
      );
      addTearDown(fetcher.close);

      final url = Uri.parse('https://cdn.example.com/same.svg');
      const headers = {'Authorization': 'Bearer x'};

      final a = fetcher.getBytes(url, headers: headers);
      final b = fetcher.getBytes(url, headers: headers);
      release.complete();

      final results = await (a, b).wait;
      expect(results.$1, Uint8List.fromList([9]));
      expect(results.$2, Uint8List.fromList([9]));
      expect(hits, 1);
    });

    test('does not coalesce when headers differ', () async {
      var hits = 0;
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(Uint8List.fromList([hits]), 200);
        }),
      );
      addTearDown(fetcher.close);

      final url = Uri.parse('https://cdn.example.com/auth.svg');
      await (
        fetcher.getBytes(url, headers: {'Authorization': 'a'}),
        fetcher.getBytes(url, headers: {'Authorization': 'b'}),
      ).wait;

      expect(hits, 2);
    });

    test('does not coalesce URL-with-|… into clean URL plus those headers', () async {
      var hits = 0;
      final release = Completer<void>();
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async {
          hits++;
          await release.future;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(fetcher.close);

      final poisoned = Uri.parse('https://cdn.example.com/a.svg|authorization=Bearer x');
      final clean = Uri.parse('https://cdn.example.com/a.svg');

      final a = fetcher.getBytes(poisoned);
      final b = fetcher.getBytes(clean, headers: const {'Authorization': 'Bearer x'});
      release.complete();

      await (a, b).wait;
      expect(hits, 2);
    });

    test('limits concurrent GETs to maxConcurrent', () async {
      var inFlight = 0;
      var peak = 0;
      final release = Completer<void>();
      final fetcher = HttpBytesFetcher(
        maxConcurrent: 2,
        client: MockClient((_) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await release.future;
          inFlight--;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(fetcher.close);

      final futures = [
        for (var i = 0; i < 5; i++) fetcher.getBytes(Uri.parse('https://cdn.example.com/$i.svg')),
      ];

      // Let the first two acquire pool slots and enter the mock.
      await Future<void>.delayed(Duration.zero);
      expect(peak, 2);
      expect(inFlight, 2);

      release.complete();
      await Future.wait(futures);
      expect(peak, 2);
    });

    test('throws TimeoutException when GET stalls past timeout', () async {
      final fetcher = HttpBytesFetcher(
        timeout: const Duration(milliseconds: 20),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(fetcher.close);

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.example.com/slow.svg')),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('timeout aborts AbortableRequest when the client honors abortTrigger', () async {
      var sawAbortable = false;
      var abortCompleted = false;
      final fetcher = HttpBytesFetcher(
        timeout: const Duration(milliseconds: 30),
        client: _AbortHonoringClient(
          onRequest: (request) {
            if (request case http.Abortable(:final abortTrigger?)) {
              sawAbortable = true;
              unawaited(abortTrigger.whenComplete(() => abortCompleted = true));
            }
          },
        ),
      );
      addTearDown(fetcher.close);

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.example.com/abort.svg')),
        throwsA(isA<TimeoutException>()),
      );
      expect(sawAbortable, isTrue);
      expect(abortCompleted, isTrue);
    });

    test('rejects getBytes after close', () async {
      final fetcher = HttpBytesFetcher(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List.fromList([1]), 200),
        ),
      );
      await fetcher.close();

      expect(
        () => fetcher.getBytes(Uri.parse('https://cdn.example.com/a.svg')),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// Test client that aborts when [http.Abortable.abortTrigger] completes.
final class _AbortHonoringClient extends http.BaseClient {
  _AbortHonoringClient({required this.onRequest});

  final void Function(http.BaseRequest request) onRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onRequest(request);
    if (request case http.Abortable(:final abortTrigger?)) {
      await abortTrigger;
      throw http.RequestAbortedException(request.url);
    }
    throw StateError('expected AbortableRequest with abortTrigger');
  }
}
