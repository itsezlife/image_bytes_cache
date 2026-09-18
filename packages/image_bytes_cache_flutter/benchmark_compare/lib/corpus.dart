/// Shared synthetic corpus for three-way URL → bytes compare.
///
/// Payloads are deterministic fill patterns by size class. URLs are synthetic
/// (`bench.invalid`) so basename collision and public CDN variance are not
/// accidental variables. Every adapter sees the same [urlFor] / [payloadFor]
/// mapping.
library;

import 'dart:typed_data';

/// Below the 64 KiB transferable / OPFS cut (chrome-sized SVG-ish).
const int smallBytes = 4 * 1024;

/// At or above the 64 KiB cut (raster-sized).
const int largeBytes = 96 * 1024;

/// Size classes exercised by the primary bytes tables.
enum PayloadClass {
  /// [smallBytes] body.
  small,

  /// [largeBytes] body.
  large,
}

/// Builds a deterministic payload of [length] bytes.
Uint8List payloadOf(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31) & 0xff;
  }
  return bytes;
}

/// Payload for [klass].
Uint8List payloadFor(PayloadClass klass) => switch (klass) {
  PayloadClass.small => payloadOf(smallBytes),
  PayloadClass.large => payloadOf(largeBytes),
};

/// Stable synthetic URL for [klass] and optional [slot] (distinct-key grids).
String urlFor(PayloadClass klass, {int slot = 0}) {
  final size = switch (klass) {
    PayloadClass.small => 'small',
    PayloadClass.large => 'large',
  };
  return 'https://bench.invalid/$size/$slot.bin';
}

/// Resolves [url] produced by [urlFor] back to its payload.
///
/// Returns `null` when [url] is not a corpus URL (adapters must not invent
/// keys outside this map for fair compare rows).
Uint8List? payloadForUrl(String url) {
  final match = RegExp(
    r'^https://bench\.invalid/(small|large)/(\d+)\.bin$',
  ).firstMatch(url);
  if (match == null) return null;
  final klass = switch (match.group(1)!) {
    'small' => PayloadClass.small,
    'large' => PayloadClass.large,
    _ => null,
  };
  if (klass == null) return null;
  return payloadFor(klass);
}
