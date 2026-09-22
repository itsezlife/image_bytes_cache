/// Compact developer size labels: `384 B`, `12.4 KB`, `1.8 MB`, …
///
/// Closed namespace for logger lines. Not a process service — no state.
abstract final class ByteCountFormat {
  /// Formats [bytes] for developer logs (`2 B`, `1.5 KB`, …).
  static String format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${_prettyFixed(kb)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${_prettyFixed(mb)} MB';
    return '${_prettyFixed(mb / 1024)} GB';
  }

  static String _prettyFixed(double value) {
    return value < 10 ? value.toStringAsFixed(1) : value.round().toString();
  }
}
