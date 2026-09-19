import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:test/test.dart';

/// Functional coverage for [HttpBytesBearerMiddleware] — attach-only Bearer
/// (no logout / refresh). Mirrors api_client's bearer middleware harness for
/// the image-GET surface.
void main() {
  HttpBytesClient fetcherWith(
    MockClient client, {
    required Future<String?> Function() getToken,
  }) {
    final fetcher = HttpBytesClient(
      client: client,
      middlewares: <HttpBytesMiddleware>[
        HttpBytesBearerMiddleware(getToken: getToken),
      ],
    );
    addTearDown(fetcher.close);
    return fetcher;
  }

  group('HttpBytesBearerMiddleware', () {
    test('attaches "Authorization: Bearer <token>" from getToken on success', () async {
      Map<String, String>? seen;
      final fetcher = fetcherWith(
        MockClient((request) async {
          seen = Map<String, String>.of(request.headers);
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
        getToken: () async => 'tok-123',
      );

      await fetcher.getBytes(Uri.parse('https://cdn.test/data'));

      expect(seen?['authorization'], equals('Bearer tok-123'));
    });

    test('fails fast when the token is null — no request is sent', () async {
      var requestSent = false;
      final fetcher = fetcherWith(
        MockClient((_) async {
          requestSent = true;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
        getToken: () async => null,
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/data')),
        throwsA(
          isA<HttpBytesException$Authentication>().having(
            (e) => e.code,
            'code',
            'no_credentials',
          ),
        ),
      );
      expect(requestSent, isFalse);
    });

    test('fails fast when the token is empty — no request is sent', () async {
      var requestSent = false;
      final fetcher = fetcherWith(
        MockClient((_) async {
          requestSent = true;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
        getToken: () async => '',
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/data')),
        throwsA(isA<HttpBytesException$Authentication>()),
      );
      expect(requestSent, isFalse);
    });

    test(r'does not swallow a 401 from the server (still $Authentication)', () async {
      final fetcher = fetcherWith(
        MockClient((_) async => http.Response('unauthorized', 401)),
        getToken: () async => 'tok',
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/data')),
        throwsA(
          isA<HttpBytesException$Authentication>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });

    test(r'does not swallow a 403 from the server (still $Authentication)', () async {
      final fetcher = fetcherWith(
        MockClient((_) async => http.Response('forbidden', 403)),
        getToken: () async => 'tok',
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/data')),
        throwsA(
          isA<HttpBytesException$Authentication>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
    });

    test(r'does not special-case a non-auth error (500) — still $Server', () async {
      final fetcher = fetcherWith(
        MockClient((_) async => http.Response('boom', 500)),
        getToken: () async => 'tok',
      );

      await expectLater(
        fetcher.getBytes(Uri.parse('https://cdn.test/data')),
        throwsA(isA<HttpBytesException$Server>()),
      );
    });

    test('token is read per request', () async {
      var n = 0;
      final seen = <String?>[];
      final fetcher = fetcherWith(
        MockClient((request) async {
          seen.add(request.headers['authorization']);
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
        getToken: () async {
          n++;
          return 'tok-$n';
        },
      );

      await fetcher.getBytes(Uri.parse('https://cdn.test/a'));
      await fetcher.getBytes(Uri.parse('https://cdn.test/b'));

      expect(seen, ['Bearer tok-1', 'Bearer tok-2']);
    });

    test(
      'different tokens do not coalesce — separate GETs for the same URL',
      () async {
        var n = 0;
        var hits = 0;
        final release = Completer<void>();
        final seen = <String?>[];
        final fetcher = fetcherWith(
          MockClient((request) async {
            hits++;
            seen.add(request.headers['authorization']);
            await release.future;
            return http.Response.bytes(Uint8List.fromList([1]), 200);
          }),
          getToken: () async {
            final mine = ++n;
            return 'tok-$mine';
          },
        );

        final url = Uri.parse('https://cdn.test/same');
        final a = fetcher.getBytes(url);
        final b = fetcher.getBytes(url);
        // Let both callers pass Bearer and register flights before release.
        await Future<void>.delayed(Duration.zero);
        release.complete();
        await (a, b).wait;

        expect(hits, 2);
        expect(seen.toSet(), {'Bearer tok-1', 'Bearer tok-2'});
      },
    );

    test(
      'same token coalesces concurrent callers into one GET',
      () async {
        var hits = 0;
        final release = Completer<void>();
        final fetcher = fetcherWith(
          MockClient((_) async {
            hits++;
            await release.future;
            return http.Response.bytes(Uint8List.fromList([9]), 200);
          }),
          getToken: () async => 'shared-tok',
        );

        final url = Uri.parse('https://cdn.test/same');
        final a = fetcher.getBytes(url);
        final b = fetcher.getBytes(url);
        await Future<void>.delayed(Duration.zero);
        release.complete();

        final results = await (a, b).wait;
        expect(results.$1, Uint8List.fromList([9]));
        expect(results.$2, Uint8List.fromList([9]));
        expect(hits, 1);
      },
    );
  });
}
