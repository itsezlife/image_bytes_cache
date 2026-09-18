import 'dart:developer' as developer;

import 'package:meta/meta.dart';

/// Soft-failure reporting for the image-bytes ladder.
///
/// Does not change resolve or wipe behavior. It only controls whether anyone
/// hears about write-through failures, index recovery, and degraded open.
/// Default is [ImageBytesDiagnostics.silent].
///
/// Process-wide policy lives on [current], set by [ImageBytesCache.open] /
/// [ImageBytesCache.configure].
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
  const factory ImageBytesDiagnostics.onEvent(
    void Function(ImageBytesLogEvent event) onEvent,
  ) = ImageBytesDiagnosticsOnEvent;

  /// Emits [event] according to this policy.
  void report(ImageBytesLogEvent event) {
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
          },
        );
      case ImageBytesDiagnosticsOnEvent(:final onEvent):
        onEvent(event);
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
  /// Recoverable / expected recovery.
  warning,

  /// Unexpected durable failure after a successful network fetch.
  error,
}

/// Soft-failure path tag for [ImageBytesLogEvent.op].
extension type const ImageBytesLogOp(String value) implements String {
  /// Cache write after a successful resolve.
  static const writeThrough = ImageBytesLogOp('write_through');

  /// Corrupt / unrecognized index wipe on open.
  static const indexWipe = ImageBytesLogOp('index_wipe');

  /// Durable open failed; host received Memory / NoOp instead of throwing.
  static const openDegraded = ImageBytesLogOp('open_degraded');
}

/// One soft-failure report from the image-bytes ladder.
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

  /// Soft-failure path tag (see [ImageBytesLogOp]).
  final ImageBytesLogOp op;

  /// Present when the failure carried a stack.
  final StackTrace? stackTrace;
}
