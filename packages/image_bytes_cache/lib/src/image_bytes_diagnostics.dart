import 'dart:developer' as developer;

import 'package:meta/meta.dart';

/// Soft-path reporting for the image-bytes ladder.
///
/// Process-wide policy lives on [current], set by [ImageBytesCache.open] /
/// [ImageBytesCache.configure].
///
/// Host [ImageBytesDiagnostics.onEvent] callbacks must not throw. If they do,
/// [report] swallows the error so a soft path (especially unawaited
/// write-through catch) cannot become an unhandled async error in the zone.
@immutable
sealed class ImageBytesDiagnostics {
  const ImageBytesDiagnostics();

  /// Active policy for open wipe and resolve write-through.
  static ImageBytesDiagnostics current = const ImageBytesDiagnostics.silent();

  /// No emission.
  const factory ImageBytesDiagnostics.silent() = ImageBytesDiagnosticsSilent;

  /// [developer.log] with name `image_bytes`.
  const factory ImageBytesDiagnostics.developer() = ImageBytesDiagnosticsDeveloper;

  /// Host owns routing (print, logger, Crashlytics, …).
  ///
  /// The callback must not throw. Throws are caught inside [report] so soft
  /// failure reporting cannot escalate into an unhandled async error.
  const factory ImageBytesDiagnostics.onEvent(
    void Function(ImageBytesLogEvent event) onEvent,
  ) = ImageBytesDiagnosticsOnEvent;

  /// Emits [event] according to this policy.
  ///
  /// Swallowing a throwing host callback is intentional: diagnostics are
  /// best-effort. Without this, an unawaited write-through `.catchError` that
  /// calls [report] would surface the host throw as a second unhandled async
  /// error after the durable failure was already soft-failed.
  void report(ImageBytesLogEvent event) {
    try {
      switch (this) {
        case ImageBytesDiagnosticsSilent():
          return;
        case ImageBytesDiagnosticsDeveloper():
          developer.log(
            event.message,
            name: 'image_bytes',
            stackTrace: event.stackTrace,
            level: switch (event.level) {
              ImageBytesLogLevel.error => 1000,
              ImageBytesLogLevel.warning => 900,
              ImageBytesLogLevel.debug => 500,
            },
          );
        case ImageBytesDiagnosticsOnEvent(:final onEvent):
          onEvent(event);
      }
    } on Object {
      // Host diagnostics must not escalate soft failures.
    }
  }
}

/// [ImageBytesDiagnostics.silent].
final class ImageBytesDiagnosticsSilent extends ImageBytesDiagnostics {
  /// Shared silent policy.
  const ImageBytesDiagnosticsSilent();
}

/// [ImageBytesDiagnostics.developer].
final class ImageBytesDiagnosticsDeveloper extends ImageBytesDiagnostics {
  /// Shared developer-log policy.
  const ImageBytesDiagnosticsDeveloper();
}

/// [ImageBytesDiagnostics.onEvent].
final class ImageBytesDiagnosticsOnEvent extends ImageBytesDiagnostics {
  /// Forwards every event to [onEvent].
  const ImageBytesDiagnosticsOnEvent(this.onEvent);

  /// Host callback.
  final void Function(ImageBytesLogEvent event) onEvent;
}

/// Severity for [ImageBytesLogEvent].
enum ImageBytesLogLevel {
  /// Development notice (for example cacheKey set with Authorization headers).
  debug,

  /// Recoverable path that still completed (for example stale-on-network-error).
  warning,

  /// Unexpected durable failure after a successful network fetch.
  error,
}

/// Soft-path tag for [ImageBytesLogEvent.op].
extension type const ImageBytesLogOp(String value) implements String {
  /// Cache write after a successful resolve.
  static const writeThrough = ImageBytesLogOp('write_through');

  /// Corrupt / unrecognized index wipe on open.
  static const indexWipe = ImageBytesLogOp('index_wipe');

  /// Durable open failed; host received Memory / NoOp instead of throwing.
  static const openDegraded = ImageBytesLogOp('open_degraded');

  /// [ImageBytesRequest.cacheKey] set while request headers include
  /// `Authorization`. Override wins for durable and coalesce identity; mint
  /// distinct keys per tenant if you need both.
  static const cacheKeyAuthorization = ImageBytesLogOp('cache_key_authorization');

  /// Cached bytes returned after `$Network`, `$Timeout`, or `$Server` failed
  /// the GET. Resolve succeeds; the failure shows up here only when diagnostics
  /// are audible.
  static const resolveStaleUsed = ImageBytesLogOp('resolve_stale_used');

  /// Stale hit with validators got HTTP 304; cached bytes reused and meta
  /// soft-refreshed. Debug only when diagnostics are audible.
  static const resolveRevalidated = ImageBytesLogOp('resolve_revalidated');

  /// Ladder already held non-empty bytes but issued an unconditional GET
  /// (stale without validators, or 412 fallback). Cold misses stay quiet.
  /// Debug only when diagnostics are audible.
  static const resolveUnconditional = ImageBytesLogOp('resolve_unconditional');
}

/// Soft-path report from the image-bytes ladder (failures and audible resolve
/// paths such as revalidated / stale-used / unconditional).
@immutable
final class ImageBytesLogEvent {
  /// Builds an event for hosts and [ImageBytesDiagnostics.developer].
  const ImageBytesLogEvent({
    required this.level,
    required this.message,
    required this.op,
    this.stackTrace,
  });

  /// Warning vs error.
  final ImageBytesLogLevel level;

  /// Human-readable detail (includes key / error text when relevant).
  final String message;

  /// Soft-path tag (see [ImageBytesLogOp]).
  final ImageBytesLogOp op;

  /// Present when the failure carried a stack.
  final StackTrace? stackTrace;
}
