/// Scroll-pressure matrix: list size × scroll intensity × complexity.
///
/// Profile-mode cells are named `list/speed/complexity` (e.g.
/// `large/fast/complicated`). The default day-to-day subset is medium ×
/// medium × ordinary+complicated; [MatrixRunMode.full] expands to the full
/// factorial. Lives only in flutter-side `benchmark_compare` — never in
/// pure-Dart core.
///
/// Gesture recipes and item counts are concrete contracts so adapters share
/// the same pressure under a cell id. Decode/paint cost is in scope for this
/// lane; bytes-ready ratios stay in the separate bytes tables.
///
/// TimelineSummary report keys are owned here ([reportKeyFor]) so summarize
/// and the drive target cannot drift.
library;

import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show immutable;
import 'package:image_bytes_cache_benchmark_compare/profile_report_key.dart';

export 'package:image_bytes_cache_benchmark_compare/profile_report_key.dart' show ProfileReportKey;

/// Which catalog a harness run executes.
enum MatrixRunMode {
  /// [ProfileMatrixCell.defaultSubset] (medium × medium × ordinary+complicated).
  subset,

  /// Every list × speed × complexity combination.
  full
  ;

  /// Parses `subset` / `full` or throws [ArgumentError].
  static MatrixRunMode parse(String raw) => switch (raw) {
    'subset' => MatrixRunMode.subset,
    'full' => MatrixRunMode.full,
    _ => throw ArgumentError.value(raw, 'MATRIX', 'Unknown MatrixRunMode'),
  };
}

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

  /// Token used in [ProfileMatrixCell.id].
  String get id => name;

  /// Parses a list-size token or throws [ArgumentError].
  static FeedListSize parse(String raw) => switch (raw) {
    'small' => FeedListSize.small,
    'medium' => FeedListSize.medium,
    'large' => FeedListSize.large,
    _ => throw ArgumentError.value(raw, 'listSize', 'Unknown FeedListSize'),
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

  /// Token used in [ProfileMatrixCell.id].
  String get id => name;

  /// Parses a scroll-intensity token or throws [ArgumentError].
  static ScrollIntensity parse(String raw) => switch (raw) {
    'slow' => ScrollIntensity.slow,
    'medium' => ScrollIntensity.medium,
    'fast' => ScrollIntensity.fast,
    _ => throw ArgumentError.value(
      raw,
      'scroll',
      'Unknown ScrollIntensity',
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

  /// Token used in [ProfileMatrixCell.id].
  String get id => name;

  /// Parses a complexity token or throws [ArgumentError].
  static FeedComplexity parse(String raw) => switch (raw) {
    'ordinary' => FeedComplexity.ordinary,
    'complicated' => FeedComplexity.complicated,
    _ => throw ArgumentError.value(
      raw,
      'complexity',
      'Unknown FeedComplexity',
    ),
  };
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

/// One named cell in the scroll-pressure matrix.
@immutable
final class ProfileMatrixCell {
  /// Creates a cell from the three locked dimensions.
  const ProfileMatrixCell({
    required this.listSize,
    required this.scroll,
    required this.complexity,
  });

  /// List length tier.
  final FeedListSize listSize;

  /// Scroll intensity tier.
  final ScrollIntensity scroll;

  /// Ordinary vs complicated corpus / settle policy.
  final FeedComplexity complexity;

  /// Stable cell id for logs and RESULTS (`list/speed/complexity`).
  String get id => '${listSize.id}/${scroll.id}/${complexity.id}';

  /// TimelineSummary report key for the ours paint path.
  String get reportKey => ProfileReportKey.encode(adapter: 'ours', cellId: id);

  /// Day-to-day subset: medium × medium × ordinary + complicated.
  static const List<ProfileMatrixCell> defaultSubset = <ProfileMatrixCell>[
    ProfileMatrixCell(
      listSize: FeedListSize.medium,
      scroll: ScrollIntensity.medium,
      complexity: FeedComplexity.ordinary,
    ),
    ProfileMatrixCell(
      listSize: FeedListSize.medium,
      scroll: ScrollIntensity.medium,
      complexity: FeedComplexity.complicated,
    ),
  ];

  /// Full factorial: every list × speed × complexity combination (18 cells).
  static List<ProfileMatrixCell> get fullFactorial => <ProfileMatrixCell>[
    for (final list in FeedListSize.values)
      for (final speed in ScrollIntensity.values)
        for (final complexity in FeedComplexity.values)
          ProfileMatrixCell(
            listSize: list,
            scroll: speed,
            complexity: complexity,
          ),
  ];

  /// Parses `list/speed/complexity` or throws [ArgumentError].
  factory ProfileMatrixCell.parseId(String raw) {
    final parts = raw.split('/');
    if (parts.length != 3) {
      throw ArgumentError.value(
        raw,
        'cellId',
        'Expected list/speed/complexity',
      );
    }
    return ProfileMatrixCell(
      listSize: FeedListSize.parse(parts[0]),
      scroll: ScrollIntensity.parse(parts[1]),
      complexity: FeedComplexity.parse(parts[2]),
    );
  }

  /// Resolves which cells a harness run should execute.
  ///
  /// [cellId] wins when set (single cell). Otherwise [mode] selects
  /// [defaultSubset] or [fullFactorial].
  static List<ProfileMatrixCell> resolveCells({
    String? cellId,
    MatrixRunMode mode = MatrixRunMode.subset,
  }) {
    if (cellId case final id? when id.isNotEmpty) {
      return <ProfileMatrixCell>[ProfileMatrixCell.parseId(id)];
    }
    return switch (mode) {
      MatrixRunMode.subset => defaultSubset,
      MatrixRunMode.full => fullFactorial,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ProfileMatrixCell &&
      other.listSize == listSize &&
      other.scroll == scroll &&
      other.complexity == complexity;

  @override
  int get hashCode => Object.hash(listSize, scroll, complexity);

  @override
  String toString() => 'ProfileMatrixCell($id)';
}
