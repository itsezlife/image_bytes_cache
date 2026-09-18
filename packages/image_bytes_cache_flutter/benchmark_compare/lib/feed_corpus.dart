/// Paintable PNG corpus for the profile / integration image-feed harness.
///
/// Separate from the bytes-compare `.bin` fill patterns: paint adapters need
/// engine-decodable rasters. URLs stay on `bench.invalid` so the lane never
/// touches a public CDN. Complexity modes (ordinary vs complicated) live here;
/// curated profile cells pick list length / scroll / settle in
/// [profile_matrix].
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';

/// Ordinary mode: few unique PNG URLs cycled through the list.
const int feedOrdinaryUniqueSlots = 4;

/// Minimum distinct keys expected from a complicated length-48 feed.
///
/// Complicated builds many unique URLs plus coalesce triplets; under a 48-item
/// list the unique count stays well above ordinary's four slots.
const int feedComplicatedMinUniqueKeys = 16;

/// Default list length helper (matches [FeedListSize.medium]).
const int defaultFeedLength = 48;

/// Fixed item height when [FeedItemMode.fixed] (density control).
const double kFixedFeedItemHeight = 88;

/// Below the 64 KiB transferable / OPFS cut (ordinary + complicated small).
const int feedSmallMinBytes = 512;

/// At or above the 64 KiB cut (complicated large bodies).
const int feedLargeMinBytes = 64 * 1024;

/// Coalesce burst length (same URL repeated in-view under complicated).
const int feedCoalesceBurstLength = 3;

/// Insert a coalesce burst after this many distinct complicated keys.
const int feedCoalesceEveryDistinct = 8;

/// PNG signature bytes.
final Uint8List _pngSignature = Uint8List.fromList(const <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
]);

/// Memoized bodies — complicated feeds hit the same slots repeatedly.
final Map<(int slot, int minBytes), Uint8List> _pngCache =
    <(int, int), Uint8List>{};

/// Synthetic ordinary feed URL for [slot] (mod [feedOrdinaryUniqueSlots]).
String feedUrl({int slot = 0}) {
  final index = slot % feedOrdinaryUniqueSlots;
  return 'https://bench.invalid/feed/$index.png';
}

/// Repeated identical payload URL ([FeedContentMode.prose] control).
String feedProseUrl() => 'https://bench.invalid/feed/prose.png';

/// Complicated distinct-key URL for [slot] (not modulo-capped).
String complicatedFeedUrl({required int slot}) =>
    'https://bench.invalid/feed/c/$slot.png';

/// Complicated coalesce-burst URL for [group] (repeated in-view).
String complicatedBurstUrl({required int group}) =>
    'https://bench.invalid/feed/c/burst-$group.png';

/// Deterministic paintable PNG for [slot], sized to at least [minBytes].
///
/// Solid fill + zlib level 0 keeps encode fast while file size stays near the
/// raw RGB footprint (so the ≥64 KiB durable cut is real). Memoized per
/// `(slot, minBytes)`.
Uint8List feedPngBytes({required int slot, int minBytes = 256}) {
  final key = (slot, minBytes);
  final cached = _pngCache[key];
  if (cached != null) return cached;

  // Edge length so raw RGB ≈ 3·edge² exceeds [minBytes] under level-0 store.
  final edge = switch (minBytes) {
    <= 1024 => 32,
    <= 8 * 1024 => 64,
    <= 32 * 1024 => 128,
    _ => 256,
  };

  final image = img.Image(width: edge, height: edge);
  final r = (slot * 40) & 0xff;
  final g = (slot * 80) & 0xff;
  final b = (slot * 120) & 0xff;
  img.fill(image, color: img.ColorRgb8(r, g, b));
  // Slot mark so bodies differ at the same edge length.
  image.setPixelRgb(0, 0, (r + 1) & 0xff, g, b);
  final encoded = Uint8List.fromList(img.encodePng(image, level: 0));
  assert(
    encoded.length >= minBytes,
    'PNG encode too small (${encoded.length} < $minBytes) at edge=$edge',
  );
  _pngCache[key] = encoded;
  return encoded;
}

/// Min body size for a complicated slot (even = small, odd = ≥64 KiB).
int complicatedMinBytesForSlot(int slot) =>
    slot.isEven ? feedSmallMinBytes : feedLargeMinBytes;

/// Resolves a feed corpus URL to PNG bytes, or `null` when not a feed URL.
Uint8List? feedPayloadForUrl(String url) {
  if (url == feedProseUrl()) {
    return feedPngBytes(slot: 0, minBytes: feedSmallMinBytes);
  }
  if (RegExp(r'^https://bench\.invalid/feed/(\d+)\.png$').firstMatch(url)
      case final Match ordinary?) {
    if (ordinary.group(1) case final String raw) {
      if (int.tryParse(raw) case final int slot) {
        return feedPngBytes(slot: slot, minBytes: feedSmallMinBytes);
      }
    }
    return null;
  }
  if (RegExp(
        r'^https://bench\.invalid/feed/c/burst-(\d+)\.png$',
      ).firstMatch(url)
      case final Match burst?) {
    if (burst.group(1) case final String raw) {
      if (int.tryParse(raw) case final int group) {
        // Bursts stay small so coalesce pressure is about shared resolve, not IO.
        return feedPngBytes(slot: group, minBytes: feedSmallMinBytes);
      }
    }
    return null;
  }
  if (RegExp(r'^https://bench\.invalid/feed/c/(\d+)\.png$').firstMatch(url)
      case final Match complicated?) {
    if (complicated.group(1) case final String raw) {
      if (int.tryParse(raw) case final int slot) {
        return feedPngBytes(
          slot: slot,
          minBytes: complicatedMinBytesForSlot(slot),
        );
      }
    }
    return null;
  }
  return null;
}

/// Ordered URL list for one feed run.
///
/// [contentMode] [FeedContentMode.mixed] builds ordinary or complicated lists
/// from [complexity]; [FeedContentMode.prose] repeats one identical payload
/// and ignores [complexity].
List<String> feedUrls({
  required int length,
  FeedContentMode contentMode = FeedContentMode.mixed,
  FeedComplexity complexity = FeedComplexity.ordinary,
}) {
  return switch (contentMode) {
    FeedContentMode.prose => List<String>.filled(length, feedProseUrl()),
    FeedContentMode.mixed => switch (complexity) {
      FeedComplexity.ordinary => List<String>.generate(
        length,
        (i) => feedUrl(slot: i),
      ),
      FeedComplexity.complicated => _complicatedUrls(length),
    },
  };
}

List<String> _complicatedUrls(int length) {
  final urls = <String>[];
  var distinct = 0;
  var burstGroup = 0;
  while (urls.length < length) {
    final remaining = length - urls.length;
    final shouldBurst =
        distinct > 0 &&
        distinct % feedCoalesceEveryDistinct == 0 &&
        remaining >= feedCoalesceBurstLength;
    if (shouldBurst) {
      final burst = complicatedBurstUrl(group: burstGroup++);
      for (var i = 0; i < feedCoalesceBurstLength; i++) {
        urls.add(burst);
      }
      distinct++;
      continue;
    }
    urls.add(complicatedFeedUrl(slot: distinct));
    distinct++;
  }
  return urls;
}

/// True when [bytes] look like a PNG (signature check).
bool isPngSignature(Uint8List bytes) {
  if (bytes.length < _pngSignature.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}
