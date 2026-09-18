/// Curated scroll-pressure cells for the raster profile compare.
///
/// Profile-mode cells are named product scenarios (`warm-scroll`,
/// `cold-scroll`, `pressure-scroll`) — not a list×speed×complexity
/// factorial. Lives only in flutter-side `benchmark_compare` — never in
/// pure-Dart core.
///
/// Gesture recipes and item counts are concrete contracts so adapters share
/// the same pressure under a cell id. Decode/paint cost is in scope for this
/// lane; bytes-ready ratios stay in the separate slim bytes tables.
///
/// TimelineSummary report keys are owned here ([reportKeyFor]) so summarize
/// and the drive target cannot drift.
library;

import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show immutable;
import 'package:image_bytes_cache_benchmark_compare/profile_report_key.dart';

export 'package:image_bytes_cache_benchmark_compare/profile_report_key.dart'
    show ProfileReportKey;

/// Feed length tier for one matrix cell.
enum FeedListSize {
  /// Short product-like list.
  small,

  /// Day-to-day default length.
  medium,

  /// Long virtualized feed pressure.
  large
  ;

  /// Concrete item count for this tier.
  int get itemCount => switch (this) {
    FeedListSize.small => 24,
    FeedListSize.medium => 48,
    FeedListSize.large => 120,
  };
}

/// Documented fling recipe for one scroll-intensity tier.
final class ScrollGestureRecipe {
  /// Creates a recipe shared across adapters for one intensity.
  const ScrollGestureRecipe({
    required this.dragOffset,
    required this.velocityPxPerSec,
    required this.passCount,
  });

  /// Primary drag delta (negative [Offset.dy] = fling toward later items).
  final Offset dragOffset;

  /// Fling velocity in logical pixels per second.
  final double velocityPxPerSec;

  /// Down+up fling pairs inside [watchPerformance].
  final int passCount;
}

/// Scroll pressure tier for one matrix cell.
enum ScrollIntensity {
  /// Casual browse — short drag, low velocity, fewer passes.
  slow,

  /// Day-to-day default pressure.
  medium,

  /// Aggressive fling pressure.
  fast
  ;

  /// Concrete gesture recipe (same recipe per intensity across adapters).
  ScrollGestureRecipe get recipe => switch (this) {
    ScrollIntensity.slow => const ScrollGestureRecipe(
      dragOffset: Offset(0, -400),
      velocityPxPerSec: 800,
      passCount: 4,
    ),
    ScrollIntensity.medium => const ScrollGestureRecipe(
      dragOffset: Offset(0, -600),
      velocityPxPerSec: 2000,
      passCount: 6,
    ),
    ScrollIntensity.fast => const ScrollGestureRecipe(
      dragOffset: Offset(0, -900),
      velocityPxPerSec: 4500,
      passCount: 8,
    ),
  };
}

/// Cache / corpus pressure mode for one matrix cell.
enum FeedComplexity {
  /// Few unique URLs, warm settle, mostly small bodies.
  ordinary,

  /// Many distinct keys, first-pass misses, mixed under/over 64 KiB,
  /// in-view coalesce bursts.
  complicated
  ;
}

/// Density feed content control (`FEED` dart-define).
enum FeedContentMode {
  /// Ordinary / complicated corpus from [FeedComplexity].
  mixed,

  /// One identical payload repeated (content-per-frame control).
  prose
  ;

  /// Parses `mixed` / `prose` or throws [ArgumentError].
  static FeedContentMode parse(String raw) => switch (raw) {
    'mixed' => FeedContentMode.mixed,
    'prose' => FeedContentMode.prose,
    _ => throw ArgumentError.value(raw, 'FEED', 'Unknown FeedContentMode'),
  };
}

/// Item height control (`ITEM_MODE` dart-define).
enum FeedItemMode {
  /// Each row keeps its natural height.
  natural,

  /// Every row clipped to a constant height.
  fixed
  ;

  /// Parses `natural` / `fixed` or throws [ArgumentError].
  static FeedItemMode parse(String raw) => switch (raw) {
    'natural' => FeedItemMode.natural,
    'fixed' => FeedItemMode.fixed,
    _ => throw ArgumentError.value(raw, 'ITEM_MODE', 'Unknown FeedItemMode'),
  };
}

/// One named curated cell in the scroll-pressure catalog.
@immutable
final class ProfileMatrixCell {
  /// Creates a curated cell from locked dimensions.
  const ProfileMatrixCell({
    required this.id,
    required this.listSize,
    required this.scroll,
    required this.complexity,
    required this.warmSettle,
  });

  /// Stable cell id for logs and RESULTS (hyphenated; no `/`).
  ///
  /// Hyphens keep [ProfileReportKey] round-trips reversible (the encoder
  /// still maps `/` ↔ `_` for legacy keys).
  final String id;

  /// List length tier.
  final FeedListSize listSize;

  /// Scroll intensity tier.
  final ScrollIntensity scroll;

  /// Ordinary vs complicated corpus / settle policy.
  final FeedComplexity complexity;

  /// When true, [pumpAndSettle] before scroll (warm hit path).
  final bool warmSettle;

  /// TimelineSummary report key for [adapter] under this cell.
  String reportKeyFor(String adapter) =>
      ProfileReportKey.encode(adapter: adapter, cellId: id);

  /// Host-feel / hit path: medium list, medium fling, ordinary warm settle.
  static const ProfileMatrixCell warmScroll = ProfileMatrixCell(
    id: 'warm-scroll',
    listSize: FeedListSize.medium,
    scroll: ScrollIntensity.medium,
    complexity: FeedComplexity.ordinary,
    warmSettle: true,
  );

  /// First-pass misses: medium list, medium fling, complicated corpus.
  static const ProfileMatrixCell coldScroll = ProfileMatrixCell(
    id: 'cold-scroll',
    listSize: FeedListSize.medium,
    scroll: ScrollIntensity.medium,
    complexity: FeedComplexity.complicated,
    warmSettle: false,
  );

  /// Jank / coalesce pressure: large list, fast fling, complicated corpus.
  static const ProfileMatrixCell pressureScroll = ProfileMatrixCell(
    id: 'pressure-scroll',
    listSize: FeedListSize.large,
    scroll: ScrollIntensity.fast,
    complexity: FeedComplexity.complicated,
    warmSettle: false,
  );

  /// Default day-to-day catalog (all three curated cells).
  static const List<ProfileMatrixCell> curated = <ProfileMatrixCell>[
    warmScroll,
    coldScroll,
    pressureScroll,
  ];

  /// Parses a curated cell id or throws [ArgumentError].
  factory ProfileMatrixCell.parseId(String raw) {
    for (final cell in curated) {
      if (cell.id == raw) return cell;
    }
    throw ArgumentError.value(
      raw,
      'cellId',
      'Expected one of: ${curated.map((c) => c.id).join(', ')}',
    );
  }

  /// Resolves which cells a harness run should execute.
  ///
  /// [cellId] wins when set (single cell). Otherwise returns [curated].
  static List<ProfileMatrixCell> resolveCells({String? cellId}) {
    if (cellId case final id? when id.isNotEmpty) {
      return <ProfileMatrixCell>[ProfileMatrixCell.parseId(id)];
    }
    return curated;
  }

  @override
  bool operator ==(Object other) =>
      other is ProfileMatrixCell && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ProfileMatrixCell($id)';
}
