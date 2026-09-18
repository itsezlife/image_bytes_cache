/// Paintable SVG corpus for the profile image-feed harness.
///
/// Separate from the bytes-compare `.bin` fill patterns: [CachedNetworkSvgImage]
/// needs well-formed SVG. URLs stay on `bench.invalid` so the lane never
/// touches a public CDN. Density controls (`FEED`, `ITEM_MODE`) and matrix
/// dimensions live on the integration target — this module supplies URLs and
/// bytes for ordinary vs complicated complexity modes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';

/// Ordinary mode: few unique SVG URLs cycled through the list.
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

/// Synthetic ordinary feed URL for [slot] (mod [feedOrdinaryUniqueSlots]).
String feedUrl({int slot = 0}) {
  final index = slot % feedOrdinaryUniqueSlots;
  return 'https://bench.invalid/feed/$index.svg';
}

/// Repeated identical payload URL ([FeedContentMode.prose] control).
String feedProseUrl() => 'https://bench.invalid/feed/prose.svg';

/// Complicated distinct-key URL for [slot] (not modulo-capped).
String complicatedFeedUrl({required int slot}) => 'https://bench.invalid/feed/c/$slot.svg';

/// Complicated coalesce-burst URL for [group] (repeated in-view).
String complicatedBurstUrl({required int group}) => 'https://bench.invalid/feed/c/burst-$group.svg';

/// Deterministic paintable SVG for [slot], optionally padded to [minBytes].
Uint8List feedSvgBytes({required int slot, int minBytes = 256}) {
  final fill = '#${((slot * 0x3151) & 0xffffff).toRadixString(16).padLeft(6, '0')}';
  const open = '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96">';
  final body = StringBuffer()
    ..write('<rect width="96" height="96" rx="12" fill="$fill"/>')
    ..write('<circle cx="48" cy="48" r="28" fill="#ffffff88"/>');
  const close = '</svg>';
  final bodyText = body.toString();

  final coreBytes = utf8.encode('$open$bodyText$close');
  if (coreBytes.length >= minBytes) {
    return Uint8List.fromList(coreBytes);
  }

  // `<!--` + `-->` = 7 UTF-8 bytes; pad the comment body to hit [minBytes].
  final baseLen = coreBytes.length + 7;
  final padLen = (minBytes - baseLen).clamp(0, 1 << 20);
  return Uint8List.fromList(
    utf8.encode('$open<!--${'x' * padLen}-->$bodyText$close'),
  );
}

/// Min body size for a complicated slot (even = small, odd = ≥64 KiB).
int complicatedMinBytesForSlot(int slot) => slot.isEven ? feedSmallMinBytes : feedLargeMinBytes;

/// Resolves a feed corpus URL to SVG bytes, or `null` when not a feed URL.
Uint8List? feedPayloadForUrl(String url) {
  if (url == feedProseUrl()) {
    return feedSvgBytes(slot: 0, minBytes: feedSmallMinBytes);
  }
  if (RegExp(r'^https://bench\.invalid/feed/(\d+)\.svg$').firstMatch(url) case final Match ordinary?) {
    if (ordinary.group(1) case final String raw) {
      if (int.tryParse(raw) case final int slot) {
        return feedSvgBytes(slot: slot, minBytes: feedSmallMinBytes);
      }
    }
    return null;
  }
  if (RegExp(
        r'^https://bench\.invalid/feed/c/burst-(\d+)\.svg$',
      ).firstMatch(url)
      case final Match burst?) {
    if (burst.group(1) case final String raw) {
      if (int.tryParse(raw) case final int group) {
        // Bursts stay small so coalesce pressure is about shared resolve, not IO.
        return feedSvgBytes(slot: group, minBytes: feedSmallMinBytes);
      }
    }
    return null;
  }
  if (RegExp(r'^https://bench\.invalid/feed/c/(\d+)\.svg$').firstMatch(url) case final Match complicated?) {
    if (complicated.group(1) case final String raw) {
      if (int.tryParse(raw) case final int slot) {
        return feedSvgBytes(
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
        distinct > 0 && distinct % feedCoalesceEveryDistinct == 0 && remaining >= feedCoalesceBurstLength;
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
