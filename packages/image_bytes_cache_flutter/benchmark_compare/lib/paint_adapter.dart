/// Shared “URL → painted Image” adapter port for three-way profile/integration.
///
/// Paint lane for the raster feed: ours [CachedNetworkBytesImage] vs CE / stock
/// [CachedNetworkImage] over the same PNG corpus + MockClient. Competitors use
/// zero fade durations so animation does not dominate frame timings.
library;

import 'package:flutter/widgets.dart';

/// Contract every compare stack implements for the paint feed.
///
/// Hosts open adapters for a suite, drive [buildImage] inside a list, call
/// [empty] between cold cells when needed, then [close]. Clear Flutter
/// [PaintingBinding.instance.imageCache] separately when measuring cold decode.
abstract interface class IPaintFeedAdapter {
  /// Short column id (`ours`, `ce_hive`, `stock_cni`).
  String get id;

  /// Human label for Markdown tables.
  String get label;

  /// Builds one feed cell image for [url] at the shared chrome size.
  Widget buildImage(
    String url, {
    required double width,
    required double height,
  });

  /// Clears the adapter’s durable/RAM store so the next resolve is a miss.
  Future<void> empty();

  /// Releases files, managers, caches, and HTTP clients.
  Future<void> close();
}

/// Factory that opens an isolated paint adapter (unique temp root).
typedef PaintFeedAdapterFactory = Future<IPaintFeedAdapter> Function({Duration responseDelay});
