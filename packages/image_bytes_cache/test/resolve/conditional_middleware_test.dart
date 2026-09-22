import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:test/test.dart';

/// Functional coverage for [HttpBytesConditionalMiddleware] — context
/// validators become conditional request headers on the wire.
void main() {
  HttpBytesClient clientWith(
    MockClient httpClient, {
    List<HttpBytesMiddleware> extra = const [],
  }) {
    final client = HttpBytesClient(
      client: httpClient,
      middlewares: <HttpBytesMiddleware>[
        ...extra,
        const HttpBytesConditionalMiddleware(),
      ],
    );
    addTearDown(client.close);
    return client;
  }

  group('HttpBytesConditionalMiddleware', () {
    test('seeds If-None-Match from context etag', () async {
      Map<String, String>? seen;
      final client = clientWith(
        MockClient((request) async {
          seen = Map<String, String>.of(request.headers);
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );

      await client.send(
        HttpBytesRequest(
          http.Request('GET', Uri.parse('https://cdn.test/a')),
        ),
        context: HttpBytesContext({HttpBytesContext.etagKey: '"v1"'}),
      );

      expect(seen?['if-none-match'], '"v1"');
      expect(seen?.containsKey('if-modified-since'), isFalse);
    });

    test('seeds If-Modified-Since from context lastModified', () async {
      Map<String, String>? seen;
      final client = clientWith(
        MockClient((request) async {
          seen = Map<String, String>.of(request.headers);
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );

      await client.send(
        HttpBytesRequest(
          http.Request('GET', Uri.parse('https://cdn.test/b')),
        ),
        context: HttpBytesContext({
          HttpBytesContext.lastModifiedKey: 'Wed, 21 Oct 2015 07:28:00 GMT',
        }),
      );

      expect(seen?['if-modified-since'], 'Wed, 21 Oct 2015 07:28:00 GMT');
      expect(seen?.containsKey('if-none-match'), isFalse);
    });

    test('seeds both validators when both are present', () async {
      Map<String, String>? seen;
      final client = clientWith(
        MockClient((request) async {
          seen = Map<String, String>.of(request.headers);
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );

      await client.send(
        HttpBytesRequest(
          http.Request('GET', Uri.parse('https://cdn.test/c')),
        ),
        context: HttpBytesContext({
          HttpBytesContext.etagKey: '"abc"',
          HttpBytesContext.lastModifiedKey: 'Thu, 01 Jan 1970 00:00:00 GMT',
        }),
      );

      expect(seen?['if-none-match'], '"abc"');
      expect(seen?['if-modified-since'], 'Thu, 01 Jan 1970 00:00:00 GMT');
    });

    test('adds no conditional headers when context has no validators', () async {
      Map<String, String>? seen;
      final client = clientWith(
        MockClient((request) async {
          seen = Map<String, String>.of(request.headers);
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );

      await client.send(
        HttpBytesRequest(
          http.Request('GET', Uri.parse('https://cdn.test/plain')),
        ),
      );

      expect(seen?.containsKey('if-none-match'), isFalse);
      expect(seen?.containsKey('if-modified-since'), isFalse);
    });

    test('ignores empty validator strings', () async {
      Map<String, String>? seen;
      final client = clientWith(
        MockClient((request) async {
          seen = Map<String, String>.of(request.headers);
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );

      await client.send(
        HttpBytesRequest(
          http.Request('GET', Uri.parse('https://cdn.test/empty')),
        ),
        context: HttpBytesContext({
          HttpBytesContext.etagKey: '',
          HttpBytesContext.lastModifiedKey: '   ',
        }),
      );

      expect(seen?.containsKey('if-none-match'), isFalse);
      expect(seen?.containsKey('if-modified-since'), isFalse);
    });

    test(
      'different context validators still coalesce (identity excludes conditionals)',
      () async {
        var hits = 0;
        final release = Completer<void>();
        final seen = <Map<String, String>>[];
        final client = clientWith(
          MockClient((request) async {
            hits++;
            seen.add(Map<String, String>.of(request.headers));
            await release.future;
            return http.Response.bytes(Uint8List.fromList([9]), 200);
          }),
        );

        final url = Uri.parse('https://cdn.test/same');
        final a = client.send(
          HttpBytesRequest(http.Request('GET', url)),
          context: HttpBytesContext({HttpBytesContext.etagKey: '"v1"'}),
        );
        final b = client.send(
          HttpBytesRequest(http.Request('GET', url)),
          context: HttpBytesContext({
            HttpBytesContext.lastModifiedKey: 'Wed, 21 Oct 2015 07:28:00 GMT',
          }),
        );
        await Future<void>.delayed(Duration.zero);
        release.complete();
        await (a, b).wait;

        expect(hits, 1);
        // Winner's headers are on the wire; joiners share that flight.
        final wire = seen.single;
        expect(
          wire.containsKey('if-none-match') || wire.containsKey('if-modified-since'),
          isTrue,
        );
      },
    );

    test(
      '304 Not Modified succeeds when If-None-Match was seeded',
      () async {
        Map<String, String>? seen;
        final client = clientWith(
          MockClient((request) async {
            seen = Map<String, String>.of(request.headers);
            return http.Response.bytes(Uint8List(0), 304, headers: {'etag': '"v1"'});
          }),
        );

        final response = await client.send(
          HttpBytesRequest(
            http.Request('GET', Uri.parse('https://cdn.test/revalidate')),
          ),
          context: HttpBytesContext({HttpBytesContext.etagKey: '"v1"'}),
        );

        expect(seen?['if-none-match'], '"v1"');
        expect(response.statusCode, 304);
        expect(await response.toBytes(), isEmpty);
      },
    );

    test(
      '200 with a new body succeeds when the origin ignores the validator',
      () async {
        final client = clientWith(
          MockClient((request) async {
            expect(request.headers['if-none-match'], '"old"');
            return http.Response.bytes(
              Uint8List.fromList([2, 2]),
              200,
              headers: {'etag': '"new"'},
            );
          }),
        );

        final response = await client.send(
          HttpBytesRequest(
            http.Request('GET', Uri.parse('https://cdn.test/replace')),
          ),
          context: HttpBytesContext({HttpBytesContext.etagKey: '"old"'}),
        );

        expect(response.statusCode, 200);
        expect(await response.toBytes(), Uint8List.fromList([2, 2]));
      },
    );

    test(
      'recommended stack: Bearer then Conditional — auth + validators on wire',
      () async {
        Map<String, String>? seen;
        final client = HttpBytesClient(
          client: MockClient((request) async {
            seen = Map<String, String>.of(request.headers);
            return http.Response.bytes(Uint8List.fromList([1]), 200);
          }),
          middlewares: <HttpBytesMiddleware>[
            const HttpBytesLoggerMiddleware$Developer(logResponse: false),
            HttpBytesRetryMiddleware(),
            const HttpBytesTimeoutMiddleware(),
            HttpBytesBearerMiddleware(getToken: () async => 'tok'),
            const HttpBytesConditionalMiddleware(),
          ],
        );
        addTearDown(client.close);

        await client.send(
          HttpBytesRequest(
            http.Request('GET', Uri.parse('https://cdn.test/stack')),
          ),
          context: HttpBytesContext({HttpBytesContext.etagKey: '"v9"'}),
        );

        expect(seen?['authorization'], 'Bearer tok');
        expect(seen?['if-none-match'], '"v9"');
      },
    );
  });
}
