import 'package:image_bytes_cache/src/http/http_bytes_client.dart';
import 'package:meta/meta.dart';

/// {@template http_bytes_conditional}
/// Opt-in conditional GET layer: reads validators from [HttpBytesContext] and
/// sets `If-None-Match` / `If-Modified-Since` on the outgoing request.
///
/// Seed [HttpBytesContext.etag] and/or [HttpBytesContext.lastModified]
/// (resolver or host). Empty or missing slots add nothing; the GET stays
/// unconditional. Not part of the default [HttpBytesClient] middleware list.
///
/// Place **after** [HttpBytesBearerMiddleware] (auth on the wire) and
/// **before** coalesce (innermost request-mutating layer). Conditional headers
/// are excluded from [ImageCacheKey] / coalesce identity, so local validators
/// do not fragment shared flights. Recommended full stack (outermost first):
/// ```dart
/// HttpBytesClient(
///   middlewares: <HttpBytesMiddleware>[
///     const HttpBytesLoggerMiddleware$Developer(), // outermost
///     HttpBytesRetryMiddleware(),
///     const HttpBytesTimeoutMiddleware(),
///     HttpBytesBearerMiddleware(getToken: getToken),
///     const HttpBytesConditionalMiddleware(), // before coalesce
///   ],
/// );
/// ```
///
/// Works with 304 Not Modified as a first-class success on [HttpBytesClient]
/// (headers present; body optional and ignored). Retry never retries 304
/// because it is not an exception.
/// {@endtemplate}
@immutable
class HttpBytesConditionalMiddleware {
  /// {@macro http_bytes_conditional}
  const HttpBytesConditionalMiddleware();

  /// Calls the inner handler with conditional headers when validators are set.
  HttpBytesHandler call(
    HttpBytesHandler innerHandler,
  ) => (request, context) async {
    if (context.etag case final etag?) {
      request.headers['if-none-match'] = etag;
    }
    if (context.lastModified case final lastModified?) {
      request.headers['if-modified-since'] = lastModified;
    }
    return innerHandler(request, context);
  };
}
