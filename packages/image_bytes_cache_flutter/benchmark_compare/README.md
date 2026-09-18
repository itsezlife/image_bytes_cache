# image_bytes_cache: three-way raster compare

Standalone, non-published package under
`image_bytes_cache_flutter/benchmark_compare`. Two lanes:

1. **URL → bytes ready** (secondary). Slim four-row tables: ours vs
   [`cached_network_image_ce`](https://pub.dev/packages/cached_network_image_ce)
   (Hive) vs stock
   [`cached_network_image`](https://pub.dev/packages/cached_network_image)
   (sqflite) on a shared adapter port.
2. **Raster paint + profile** (primary). Same PNG corpus through ours
   (`CachedNetworkBytesImage`), CE, and stock (`CachedNetworkImage`):
   - side-by-side integration correctness (competitors do not ship this)
   - curated scroll cells with TimelineSummary (three stacks × three cells)

Competitor deps live only here. Never on the core or flutter package pubspecs.

Harvested runs: [`RESULTS.md`](RESULTS.md).

Neither lane is a CI merge gate. Core store benches and the slim bytes tables
are the durable proof. Profile numbers are phone- or browser-specific frame
timings on top.

## Layout

| Path | Role |
| ---- | ---- |
| `lib/corpus.dart` | Synthetic URLs + size-class payloads for bytes tables |
| `lib/feed_corpus.dart` | Paintable PNG URLs/bytes (ordinary vs complicated) |
| `lib/profile_matrix.dart` | Curated cells: `warm-scroll` / `cold-scroll` / `pressure-scroll` |
| `lib/adapter.dart` | `IBytesReadyAdapter` port |
| `lib/paint_adapter.dart` | `IPaintFeedAdapter` port |
| `lib/adapters/` | Bytes + paint factories for ours / CE / stock |
| `lib/scenarios.dart` | Cold miss, warm hit, same-URL burst, many distinct keys (small) |
| `lib/measure.dart` | Warmup + calibrate + min-of-batches |
| `lib/timeline_summary_table.dart` | TimelineSummary JSON → Markdown |
| `benchmark/bytes_compare.dart` | Prints Markdown absolute + ratio tables |
| `integration_test/paint_compare_test.dart` | Three-way paint correctness |
| `integration_test/scroll_perf_test.dart` | Profile cells × three paint adapters |
| `test_driver/perf_driver.dart` | Writes `build/integration_response_data.json` |
| `tool/summarize_timeline.dart` | Paste-ready profile Markdown |
| `test/adapter_port_test.dart` | Bytes seam correctness |
| `test/paint_adapter_port_test.dart` | Paint seam (widget type; no FakeAsync pump) |
| `test/bytes_compare_test.dart` | Timed bytes compare (not a CI gate) |
| `test/feed_corpus_*.dart` | PNG corpus contracts |
| `test/profile_matrix_test.dart` | Curated cell ids / recipes |
| `test/timeline_summary_table_test.dart` | Summarize formatter |

## Running: bytes compare

```shell
cd packages/image_bytes_cache_flutter/benchmark_compare
flutter pub get

flutter test test/adapter_port_test.dart
flutter test test/bytes_compare_test.dart
```

Paste the printed Markdown into [`RESULTS.md`](RESULTS.md). Absolute
microseconds are not portable. Use the ratio table.

Rows (small corpus only): `cold_miss_small`, `warm_hit_small`,
`same_url_burst_small`, `many_distinct_keys_small`.

## Running: paint integration correctness

```shell
flutter test integration_test/paint_compare_test.dart -d flutter-tester
# or a real device / desktop runner when preferred

# Web (ChromeDriver must already listen on 4444):
#   chromedriver --port=4444
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/paint_compare_test.dart \
  -d web-server --browser-name=chrome --driver-port=4444
```

Cold / warm / short feed / empty-then-reload for ours, ce_hive, and stock_cni
on the shared PNG corpus. On web, stock uses cache_manager's IndexedDB path
(not sqflite); CE uses Hive/IndexedDB. Not a merge gate.

Do not pump real durable resolves under `testWidgets` FakeAsync. Isolate ladder
+ HTTP deadlocks. Unit paint tests only assert widget types; live paint lives
in `integration_test/`.

## Running: profile scroll (optional)

Prefer a real device with `--profile` for the Android harvest in RESULTS.
Chrome web drive adds correctness and noisier debug timings.

```shell
# Device / desktop profile:
flutter drive \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart \
  --profile --no-dds -d <device>

# Chrome web (ChromeDriver on :4444):
flutter drive \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart \
  -d web-server --browser-name=chrome --driver-port=4444

dart run tool/summarize_timeline.dart
```

### Curated cells

| Cell id | List | Scroll | Complexity | Settle |
| ------- | ---- | ------ | ---------- | ------ |
| `warm-scroll` | medium (48) | medium | ordinary | warm `pumpAndSettle` |
| `cold-scroll` | medium (48) | medium | complicated | first-pass misses |
| `pressure-scroll` | large (120) | fast | complicated | first-pass misses |

```shell
# Single cell
flutter drive ... --dart-define=CELL=warm-scroll
```

Optional density defines: `FEED=mixed|prose`, `ITEM_MODE=natural|fixed`.

## Methodology and fairness

### Bytes tables

**Corpus.** Deterministic fill patterns (`small` = 4 KiB) served by an
in-process `MockClient`. No public CDN.

**Primary table.** Bytes ready only. No decode / ImageProvider paint.

**Adapters.** Temp roots, MockClient, stock `sqflite_common_ffi`. Emptied
between rows.

### Paint / profile

**Corpus.** Paintable PNG on `bench.invalid/feed/...` (`lib/feed_corpus.dart`)
via `package:image` (level-0 encode so the ≥64 KiB cut is real file size).

**Paint path.** `IPaintFeedAdapter`:

| Stack | Widget | Notes |
| ----- | ------ | ----- |
| ours | `CachedNetworkBytesImage` | injected resolver |
| CE / stock | `CachedNetworkImage` | injected `cacheManager`; zero fade durations |

Same list layout, decode pixel budget, and corpus per cell. Flutter
`imageCache` cleared between cold cells. On web, competitors use
`ImageRenderMethodForWeb.HttpGet` so MockClient stays in path.

**Metrics.** TimelineSummary build/raster percentiles per
`scroll_<adapter>__<cell-id>`. Summarize prints three-way columns when present.
