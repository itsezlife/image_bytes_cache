import 'package:http_parser/http_parser.dart' show parseHttpDate;
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:meta/meta.dart';

/// Engine freshness rules for one [ImageHttpCacheMeta] row.
///
/// [ImageBytesResolver] calls this before deciding whether a cache hit can
/// skip the network. [ImageBytesRetention] still owns durable eviction. This
/// type only answers "fresh enough to skip GET?" and builds / merges meta from
/// response headers.
///
/// ## Defaults (no `Cache-Control`, no `Expires`)
///
/// - Non-empty `etag` or `lastModified`: stale. Revalidate on every use.
/// - Neither validator: fresh. Keep the bytes until retention drops the row.
///
/// ## When `Cache-Control` or `Expires` is present
///
/// - `max-age` / `Expires`: compare lifetime to current age (`Age`, `Date`,
///   [ImageHttpCacheMeta.lastValidatedAt], and [writtenAt] when known).
/// - `no-cache` / `must-revalidate`: always stale.
/// - `immutable`: always fresh until retention.
/// - `Expires` alone (no `Date` / `lastValidatedAt`): treat as an absolute
///   wall deadline against [now].
/// - `Cache-Control` with no usable lifetime (e.g. only `public`): same as the
///   defaults above.
///
/// Age math follows RFC 9111 in simplified form.
abstract final class ImageHttpCacheFreshness {
  /// Whether [meta] is still fresh at [now].
  ///
  /// Null or empty [meta] is fresh (pre-ETag row: retain until retention).
  ///
  /// [writtenAt] is the store's durable write time. The ladder passes it when
  /// [ImageHttpCacheMeta.lastValidatedAt] and [ImageHttpCacheMeta.date] are
  /// missing so current age still has a response-time anchor.
  static bool isFresh(
    ImageHttpCacheMeta? meta, {
    required DateTime now,
    DateTime? writtenAt,
  }) {
    switch (meta) {
      case null || ImageHttpCacheMeta(isEmpty: true):
        return true;
      case final m:
        final hasValidators = _hasValidators(m);
        final directives = _parseCacheControl(m.cacheControl);
        final hasFreshnessHeaders =
            switch (m.cacheControl) {
              final cc? when cc.trim().isNotEmpty => true,
              _ => false,
            } ||
            m.expires != null;

        if (!hasFreshnessHeaders) {
          // Validators ⇒ revalidate every use. Else retain until retention
          // would drop the row (a non-null hit already passed TTL).
          return !hasValidators;
        }

        if (directives.immutable) return true;
        if (directives.noCache || directives.mustRevalidate) return false;

        if (_usableLifetimeMissing(m, directives)) {
          // CC present but no max-age / Expires (e.g. only `public`).
          return !hasValidators;
        }

        final lifetime = _freshnessLifetime(m, directives, now: now, writtenAt: writtenAt);
        if (lifetime <= Duration.zero) return false;
        return _currentAge(m, now: now, writtenAt: writtenAt) <= lifetime;
    }
  }

  /// Whether [meta] has a non-empty ETag and/or Last-Modified.
  ///
  /// The ladder uses this to choose conditional GET vs unconditional GET on a
  /// stale hit.
  static bool hasValidators(ImageHttpCacheMeta? meta) => switch (meta) {
    final m? => _hasValidators(m),
    null => false,
  };

  /// Builds meta from GET / 304 response [headers].
  ///
  /// Sets [ImageHttpCacheMeta.lastValidatedAt] to [validatedAt]. Missing or
  /// unparseable fields stay null.
  ///
  /// Returns null when the response carries no validators and no freshness
  /// fields. [lastValidatedAt] alone is not stored. A null return on a 200
  /// write clears prior meta for that key (the old ETag belonged to the old
  /// body).
  static ImageHttpCacheMeta? fromResponseHeaders(
    Map<String, String> headers, {
    required DateTime validatedAt,
  }) {
    final etag = _header(headers, 'etag');
    final lastModified = _header(headers, 'last-modified');
    final cacheControl = _header(headers, 'cache-control');
    final date = _parseDate(_header(headers, 'date'));
    final expires = _parseDate(_header(headers, 'expires'));
    final age = _parseAge(_header(headers, 'age'));

    // lastValidatedAt alone is not wire meta. Without validators or freshness
    // fields there is nothing to store.
    if (etag == null &&
        lastModified == null &&
        cacheControl == null &&
        date == null &&
        expires == null &&
        age == null) {
      return null;
    }

    return ImageHttpCacheMeta(
      etag: etag,
      lastModified: lastModified,
      date: date,
      expires: expires,
      cacheControl: cacheControl,
      age: age,
      lastValidatedAt: validatedAt,
    );
  }

  /// Meta after a 304 Not Modified.
  ///
  /// Keeps prior validators when the 304 omits them. Always sets
  /// [ImageHttpCacheMeta.lastValidatedAt] to [validatedAt]. Overlays
  /// freshness headers the 304 does send (`Cache-Control`, `Expires`, …).
  static ImageHttpCacheMeta afterNotModified(
    ImageHttpCacheMeta? previous, {
    required Map<String, String> headers,
    required DateTime validatedAt,
  }) {
    final from304 = fromResponseHeaders(headers, validatedAt: validatedAt);
    final prior = previous ?? const ImageHttpCacheMeta();
    return ImageHttpCacheMeta(
      etag: from304?.etag ?? prior.etag,
      lastModified: from304?.lastModified ?? prior.lastModified,
      date: from304?.date ?? prior.date,
      expires: from304?.expires ?? prior.expires,
      cacheControl: from304?.cacheControl ?? prior.cacheControl,
      age: from304?.age ?? prior.age,
      lastValidatedAt: validatedAt,
    );
  }

  static bool _hasValidators(ImageHttpCacheMeta meta) => switch (meta) {
    ImageHttpCacheMeta(etag: final e?) when e.trim().isNotEmpty => true,
    ImageHttpCacheMeta(lastModified: final lm?) when lm.trim().isNotEmpty => true,
    _ => false,
  };

  static bool _usableLifetimeMissing(
    ImageHttpCacheMeta meta,
    _CacheControlDirectives directives,
  ) => directives.maxAge == null && meta.expires == null;

  static Duration _freshnessLifetime(
    ImageHttpCacheMeta meta,
    _CacheControlDirectives directives, {
    required DateTime now,
    DateTime? writtenAt,
  }) {
    if (directives.maxAge case final maxAge?) {
      return maxAge;
    }
    final expires = meta.expires!;
    // Prefer Date / lastValidatedAt / writtenAt as date_value. When none
    // exist, treat Expires as an absolute wall deadline against [now].
    final dateValue = meta.date ?? meta.lastValidatedAt ?? writtenAt ?? now;
    final delta = expires.difference(dateValue);
    return delta.isNegative ? Duration.zero : delta;
  }

  /// RFC 9111 current_age, simplified.
  static Duration _currentAge(
    ImageHttpCacheMeta meta, {
    required DateTime now,
    DateTime? writtenAt,
  }) {
    final responseTime = meta.lastValidatedAt ?? writtenAt ?? meta.date ?? now;
    final dateValue = meta.date ?? responseTime;
    final apparentAge = responseTime.isAfter(dateValue) ? responseTime.difference(dateValue) : Duration.zero;
    final ageHeader = meta.age ?? Duration.zero;
    final correctedInitialAge = apparentAge > ageHeader ? apparentAge : ageHeader;
    final residentTime = now.isAfter(responseTime) ? now.difference(responseTime) : Duration.zero;
    return correctedInitialAge + residentTime;
  }

  static _CacheControlDirectives _parseCacheControl(String? raw) {
    switch (raw?.trim()) {
      case null || '':
        return const _CacheControlDirectives();
      case final text:
        var noCache = false;
        var mustRevalidate = false;
        var immutable = false;
        Duration? maxAge;
        for (final part in text.split(',')) {
          switch (part.trim().toLowerCase()) {
            case '':
              continue;
            case final d when d == 'no-cache' || d.startsWith('no-cache='):
              noCache = true;
            case 'must-revalidate':
              mustRevalidate = true;
            case 'immutable':
              immutable = true;
            case final d when d.startsWith('max-age='):
              if (int.tryParse(d.substring('max-age='.length).trim()) case final seconds? when seconds >= 0) {
                maxAge = Duration(seconds: seconds);
              }
            case _:
              break;
          }
        }
        return _CacheControlDirectives(
          noCache: noCache,
          mustRevalidate: mustRevalidate,
          immutable: immutable,
          maxAge: maxAge,
        );
    }
  }

  static String? _header(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) {
        final value = entry.value.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  static DateTime? _parseDate(String? raw) {
    if (raw == null) return null;
    try {
      return parseHttpDate(raw).toUtc();
    } on FormatException {
      return null;
    }
  }

  static Duration? _parseAge(String? raw) {
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }
}

@immutable
final class _CacheControlDirectives {
  const _CacheControlDirectives({
    this.noCache = false,
    this.mustRevalidate = false,
    this.immutable = false,
    this.maxAge,
  });

  final bool noCache;
  final bool mustRevalidate;
  final bool immutable;
  final Duration? maxAge;
}
