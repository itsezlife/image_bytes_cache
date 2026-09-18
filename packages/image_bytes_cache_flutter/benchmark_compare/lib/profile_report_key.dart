/// TimelineSummary report-key encoding for profile scroll cells.
///
/// Pure Dart so `dart run tool/summarize_timeline.dart` can format driver JSON
/// without pulling in `dart:ui` via [profile_matrix].
library;

/// Encodes / parses `scroll_<adapter>[__<cell>]` driver report keys.
///
/// Format: `scroll_<adapter>__<list>_<speed>_<complexity>` for matrix cells,
/// or `scroll_<adapter>` for the unlabeled single-run cell id `default`.
/// Adapter ids may contain underscores; the separator between adapter and
/// cell encoding is the first `__`.
abstract final class ProfileReportKey {
  /// Cell id used when a report key has no matrix suffix.
  static const String defaultCellId = 'default';

  /// Encodes a driver report key for [adapter] and [cellId].
  static String encode({
    required String adapter,
    required String cellId,
  }) {
    if (cellId == defaultCellId) {
      return 'scroll_$adapter';
    }
    return 'scroll_${adapter}__${cellId.replaceAll('/', '_')}';
  }

  /// Parses a driver report key into `(cellId, adapter)`, or `null` if not a
  /// profile scroll key.
  static (String cellId, String adapter)? tryParse(String key) {
    const prefix = 'scroll_';
    if (!key.startsWith(prefix)) return null;
    final rest = key.substring(prefix.length);
    final sep = rest.indexOf('__');
    if (sep < 0) {
      if (rest.isEmpty) return null;
      return (defaultCellId, rest);
    }
    final adapter = rest.substring(0, sep);
    final encodedCell = rest.substring(sep + 2);
    if (adapter.isEmpty || encodedCell.isEmpty) return null;
    return (encodedCell.replaceAll('_', '/'), adapter);
  }
}
