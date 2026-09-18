# image_bytes_cache — three-way bytes compare + profile matrix

Standalone, non-published package under
`image_bytes_cache_flutter/benchmark_compare`. Two measurement lanes:

1. **URL → bytes ready** — ours vs
   [`cached_network_image_ce`](https://pub.dev/packages/cached_network_image_ce)
   (Hive) vs stock
   [`cached_network_image`](https://pub.dev/packages/cached_network_image)
   (sqflite) on a shared adapter port.
2. **Profile scroll-pressure matrix** — real-device `--profile` scroll of a
   product-like list painted through `image_bytes_cache_flutter`
   (`CachedNetworkSvgImage`), capturing TimelineSummary frame build/raster
   per named cell (`list/speed/complexity`). Ours-only today; competitor
   paint columns only when fair.

Competitor deps live **only** here — never on the core or flutter package
pubspecs.

Harvested runs: [`RESULTS.md`](RESULTS.md).

**Neither lane is a CI merge gate.** Core store RESULT / bytes tables remain
the doctrine proof; the profile matrix is additive host-feel evidence.

## Layout

| Path                                     | Role                                                                    |
| ---------------------------------------- | ----------------------------------------------------------------------- |
| `lib/corpus.dart`                        | Synthetic URLs + size-class payloads (small / ≥64 KiB) for bytes tables |
| `lib/feed_corpus.dart`                   | Paintable SVG URLs/bytes (ordinary vs complicated)                      |
| `lib/profile_matrix.dart`                | List × scroll × complexity cells, recipes, report keys, subset/full     |
| `lib/adapter.dart`                       | `IBytesReadyAdapter` port                                               |
| `lib/adapters/`                          | Ours (resolver + durable VM), CE Hive, stock CNI                        |
| `lib/scenarios.dart`                     | Cold miss, warm hit, same-URL burst, many distinct keys                 |
| `lib/measure.dart`                       | Warmup + calibrate + min-of-batches                                     |
| `lib/timeline_summary_table.dart`        | TimelineSummary JSON → Markdown (named cells)                           |
| `benchmark/bytes_compare.dart`           | Prints Markdown absolute + ratio tables                                 |
| `integration_test/scroll_perf_test.dart` | Profile matrix feed + TimelineSummary                                   |
| `test_driver/perf_driver.dart`           | Writes `build/integration_response_data.json`                           |
| `tool/summarize_timeline.dart`           | Paste-ready profile Markdown                                            |
| `test/adapter_port_test.dart`            | Correctness at the adapter seam                                         |
| `test/bytes_compare_test.dart`           | Runs the timed compare (not a CI gate)                                  |
| `test/feed_corpus_test.dart`             | Feed SVG corpus contracts                                               |
| `test/feed_corpus_complexity_test.dart`  | Ordinary vs complicated observable differences                          |
| `test/profile_matrix_test.dart`          | Cell ids, subset/full, gesture recipes                                  |
| `test/timeline_summary_table_test.dart`  | Summarize formatter                                                     |

## Running — bytes compare

```shell
cd packages/image_bytes_cache_flutter/benchmark_compare
flutter pub get

# Seam correctness (fast)
flutter test test/adapter_port_test.dart

# Head-to-head tables (slow; machine-local)
flutter test test/bytes_compare_test.dart
```

Paste the printed Markdown into [`RESULTS.md`](RESULTS.md). Absolute
microseconds are **not** portable — use the ratio table.

## Running — profile scroll-pressure matrix (optional, real device)

Profile timings need a **real device or desktop runner** and GPU raster. They
are device-specific, **not** a merge gate, and do **not** replace core store
microbenches or the bytes doctrine tables.

```shell
cd packages/image_bytes_cache_flutter/benchmark_compare
flutter pub get

# One-time platform runner (gitignored scaffolding):
flutter create --platforms=linux \
  --project-name image_bytes_cache_benchmark_compare .

# Default subset: medium/medium/ordinary + medium/medium/complicated
flutter drive \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart \
  --profile --no-dds -d linux

dart run tool/summarize_timeline.dart
# -> reads build/integration_response_data.json
# -> one Markdown table per named cell
```

Swap `-d linux` for another device when preferred.

### Matrix defines

| Define   | Values / example              | Effect                                                                 |
| -------- | ----------------------------- | ---------------------------------------------------------------------- |
| `MATRIX` | `subset` (default) / `full`   | `subset` = medium × medium × ordinary+complicated; `full` = 18 cells   |
| `CELL`   | e.g. `large/fast/complicated` | Single-cell override (wins over `MATRIX`)                              |

```shell
# Full factorial (opt-in; long)
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart --profile --no-dds -d linux \
  --dart-define=MATRIX=full

# One pressure cell
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart --profile --no-dds -d linux \
  --dart-define=CELL=large/fast/complicated
```

### Locked dimensions

| Axis         | Tokens                         | Concrete contract                                                                                                                                 |
| ------------ | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| List size    | `small` / `medium` / `large`   | 24 / 48 / 120 items                                                                                                                               |
| Scroll       | `slow` / `medium` / `fast`     | drag `(0,-400)` @ 800 px/s × 4 passes; `(0,-600)` @ 2000 × 6; `(0,-900)` @ 4500 × 8 (down then up each pass)                                      |
| Complexity   | `ordinary` / `complicated`     | **ordinary:** 4 unique small SVGs, warm `pumpAndSettle` before scroll. **complicated:** many distinct keys, mixed under/over 64 KiB, 3-in-a-row coalesce bursts, layout-only settle (first-pass misses), 2 ms MockClient delay |

Cell id in logs / RESULTS: `list/speed/complexity` (e.g. `large/fast/complicated`).

### Density controls (orthogonal)

| Define      | Values                        | Effect                                                                                                       |
| ----------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `FEED`      | `mixed` (default) / `prose`   | `mixed` uses ordinary/complicated corpus; `prose` repeats one identical payload (content-per-frame control)  |
| `ITEM_MODE` | `natural` (default) / `fixed` | `fixed` clips every row to a constant height so fling distance crosses the same item count                   |

```shell
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart --profile --no-dds -d linux \
  --dart-define=FEED=prose --dart-define=ITEM_MODE=fixed
```

## Methodology & fairness

### Bytes tables

**Corpus.** Deterministic fill patterns (`small` = 4 KiB, `large` = 96 KiB)
served by an in-process `MockClient`. No public CDN. Every adapter resolves
the same `https://bench.invalid/…` URLs.

**Primary table.** Bytes ready only — `getBytes` / resolver / `CacheManager`
file path. **No** decode, **no** Flutter `ImageCache`, **no** ImageProvider
paint (those belong in the profile-scroll lane).

**Adapters.**

| Stack     | Bytes path                                             | HTTP control                            | Store isolation                              |
| --------- | ------------------------------------------------------ | --------------------------------------- | -------------------------------------------- |
| ours      | `ImageBytesResolver` + durable `ImageBytesCache.open`  | `HttpBytesFetcher` + `MockClient`       | Temp directory; emptied between rows         |
| CE Hive   | `DefaultCacheManager.getFileStream` → `FileInfo` bytes | `httpClientFactory` → same `MockClient` | Temp cache + Hive dirs                       |
| stock CNI | `CacheManager.getSingleFile` → bytes                   | `HttpFileService(httpClient: …)`        | Temp root + `CacheObjectProvider` `.db` path |

**Lifecycle.** Adapters are reused across rows (reopened only when a scenario’s
HTTP delay changes) and emptied between scenarios. Stock CNI close waits past
`flutter_cache_manager`’s ~10s cleanup timer so dispose does not race a closed
sqflite handle.

**Do not** assert Hive box names, SQLite query plans, or private lock maps —
adapters stay at the bytes-ready port. If a stack cannot expose bytes fairly
on a platform, the cell is **N/A** with a reason (never a paint-inclusive lie).

**Interpreting ratios.** `× = adapter_us / ours_us`. Values above 1.00 mean
slower than ours on **this** machine/run. Residual unfairness (e.g. CE
materializing a `File` from Hive+disk, stock reading through sqflite + file
IO, ours RAM-meta hit after durable write-through) is inherent to the public
APIs — document it, do not normalize it away in the table.

### Profile matrix

**Corpus.** Paintable SVG on `bench.invalid/feed/…` (`lib/feed_corpus.dart`).
Still no public CDN — `MockClient` only. Ordinary vs complicated rules are in
the table above.

**Paint path.** Rows use `CachedNetworkSvgImage` with an injected
`ImageBytesResolver` over a durable temp store + controlled HTTP. Light list
chrome (avatar + label) is in scope so rebuild/layout cost is realistic.

**Metrics.** TimelineSummary frame build/raster avg / p90 / p99 / worst, missed
frame counts, frame count — **per named cell**. Summarize → Markdown; harvest
under a separate RESULTS section from the bytes tables.

**Fairness.** Decode/paint is **in scope** here (host claim). Same feed length,
gesture recipe, corpus, and density mode per cell. Ours-only is intentional
until competitor paint adapters can consume the SVG corpus fairly — report
missing columns as `-` / N/A with that reason, not a forced three-way paint
table.

**Interpreting percentiles vs bytes ratios.** Profile numbers are machine- and
device-specific frame build/raster timings under GPU raster. They answer “how
does the feed feel under this pressure cell?” Bytes-table ratios answer “how
fast is URL → bytes ready on the durable path?” Do not treat profile
percentiles as portable absolute milliseconds, and do not substitute them for
(or against) core store microbench / bytes-compare ratios — different seams,
different claims.

## Summarize

```shell
dart run tool/summarize_timeline.dart
dart run tool/summarize_timeline.dart --cell medium/medium/ordinary
```

Discovers `scroll_ours__list_speed_complexity` keys and prints one table per
cell id (`list/speed/complexity`).
