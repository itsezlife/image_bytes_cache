/// Durable remote image bytes for any image-format payload.
///
/// Product: raw bytes with an identity key, not decoded bitmaps and not Flutter
/// [ImageCache]. After open, meta lives in a RAM mirror; durable meta commits
/// once per exclusive mutate epoch; payloads sit on platform blob stores.
/// Concurrent cache reads are allowed when no mutate holds the gate. Hosts
/// resolve via [ImageBytesResolver] (cache → network coalesce → write-through).
///
/// Wire shared instances with [ImageBytesCache.configure] /
/// [ImageBytesCache.open] and optionally [HttpBytesClient.configure] for a
/// process-wide HTTP client. Soft storage failures report through
/// [ImageBytesDiagnostics]. Open degrades to an in-memory store on hard
/// failure unless [ImageBytesCache.open] is called with
/// `throwOnOpenFailure: true`. Hosts bridge diagnostics; this package does
/// not depend on a product logger.
library;

export 'package:cancel_token/cancel_token.dart' show CancelToken, CancelledException;

export 'src/cache/cache_middleware.dart';
export 'src/cache/middlewares/logger_middleware.dart';
export 'src/cache/middlewares/skip_cache_middleware.dart';
export 'src/http/http_bytes_client.dart';
export 'src/http/middlewares/bearer_middleware.dart';
export 'src/http/middlewares/conditional_middleware.dart';
export 'src/http/middlewares/logger_middleware.dart';
export 'src/http/middlewares/retry_middleware.dart';
export 'src/http/middlewares/timeout_middleware.dart';
export 'src/http/retry_backoff.dart';
export 'src/image_bytes_cache.dart';
export 'src/image_bytes_diagnostics.dart';
export 'src/image_bytes_resolver.dart';
export 'src/image_http_cache_freshness.dart';
