import 'package:image_bytes_cache/src/http/http_bytes_client.dart';
import 'package:meta/meta.dart';

/// {@template http_bytes_bearer}
/// Attaches `Authorization: Bearer <token>` to every request.
///
/// Named after the Bearer scheme, not HTTP Basic. Performs **no** logout and
/// **no** token refresh: hosts that need session teardown or refresh belong in
/// the product auth stack.
///
/// A `null`/empty [getToken] result throws [HttpBytesException$Authentication]
/// (`no_credentials`) without mutating app session state. For optional auth,
/// omit this middleware and pass headers on the request instead.
/// {@endtemplate}
@immutable
class HttpBytesBearerMiddleware {
  /// {@macro http_bytes_bearer}
  const HttpBytesBearerMiddleware({
    required this.getToken,
  });

  /// Resolves the raw bearer token (no scheme). `null`/empty → not authenticated.
  final Future<String?> Function() getToken;

  /// Calls the inner handler with the modified request.
  HttpBytesHandler call(
    HttpBytesHandler innerHandler,
  ) => (request, context) async {
    final token = await getToken();
    if (token == null || token.isEmpty) {
      throw const HttpBytesException$Authentication(
        code: 'no_credentials',
        message: 'No authentication token available.',
        statusCode: 0,
      );
    }
    request.headers['authorization'] = 'Bearer $token';
    return innerHandler(request, context);
  };
}
