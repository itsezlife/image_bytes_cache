/// Shared “URL → bytes ready” adapter port for three-way compare.
///
/// Primary tables measure durable (or store) bytes readiness only — no decode,
/// no Flutter [ImageCache], no ImageProvider paint. Implementations must not
/// assert Hive box names, SQLite plans, or other store internals; close/dispose
/// between scenarios so warm-hit rows stay unpoisoned.
library;

import 'dart:typed_data';

/// Contract every compare stack implements for the bytes-ready tables.
///
/// Hosts open adapters for a suite (reopen when HTTP delay changes), drive
/// [getBytes], [empty] between rows, then [close] after settle. Adapters that
/// cannot expose bytes fairly report N/A with a reason in the runner — never a
/// paint-inclusive lie. Do not assert Hive box names, SQLite plans, or other
/// store internals.
abstract interface class IBytesReadyAdapter {
  /// Short column id (`ours`, `ce_hive`, `stock_cni`).
  String get id;

  /// Human label for Markdown tables.
  String get label;

  /// Returns payload bytes for [url] (cache and/or network per stack rules).
  Future<Uint8List> getBytes(String url);

  /// Drops cached entry for [url] when the stack exposes eviction.
  ///
  /// Used to force a cold miss without disposing the whole store. Prefer
  /// [empty] when clearing many keys between iterations.
  Future<void> evict(String url);

  /// Clears the adapter’s durable/RAM store so the next [getBytes] is a miss.
  Future<void> empty();

  /// Releases files, Hive boxes, SQLite handles, and HTTP clients.
  Future<void> close();
}

/// Factory that opens an isolated adapter (unique temp root / cache key).
typedef BytesReadyAdapterFactory = Future<IBytesReadyAdapter> Function();
