# Benchmark results — URL → bytes ready

Head-to-head numbers for **image_bytes_cache** vs **cached_network_image_ce**
(Hive) vs stock **cached_network_image** (sqflite). Machine-specific —
regenerate with the commands in [`README.md`](README.md).

Primary tables measure **bytes ready only** (no decode / ImageProvider paint).

## Environment

|                         |                                                              |
| ----------------------- | ------------------------------------------------------------ |
| CPU                     | Apple Silicon (arm64)                                        |
| OS                      | Darwin 25.6.0                                                |
| Flutter                 | 3.41.7 (local FVM)                                           |
| image_bytes_cache       | path `../image_bytes_cache`                                  |
| cached_network_image_ce | resolved 4.12.0                                              |
| cached_network_image    | 3.4.1                                                        |
| flutter_cache_manager   | ^3.4.1                                                       |
| sqflite (stock meta)    | `CacheObjectProvider` + `sqflite_common_ffi` in this harness |

## URL → bytes ready (µs/op)

Harvested from `flutter test test/bytes_compare_test.dart` (min-of-batches).
Lower is better. Eviction for cold rows runs outside the stopwatch.

| scenario                 | bytes | image_bytes_cache | cached_network_image_ce (Hive) | cached_network_image (sqflite) |
| ------------------------ | ----: | ----------------: | -----------------------------: | -----------------------------: |
| cold_miss_small          |  4096 |             470.5 |                         1448.3 |                         2248.3 |
| cold_miss_large          | 98304 |             423.8 |                         1181.9 |                         2211.0 |
| warm_hit_small           |  4096 |             186.7 |                          297.4 |                          334.8 |
| warm_hit_large           | 98304 |             184.3 |                          279.0 |                          333.0 |
| same_url_burst_small     |  4096 |            3319.0 |                         8379.0 |                         5181.0 |
| many_distinct_keys_small |  4096 |            3578.0 |                        10185.0 |                        23608.0 |

## Relative to ours

`× = adapter_us / ours_us`. Values > 1 mean slower than ours on this machine.

| scenario                 | image_bytes_cache | cached_network_image_ce (Hive) | cached_network_image (sqflite) |
| ------------------------ | ----------------: | -----------------------------: | -----------------------------: |
| cold_miss_small          |             1.00x |                          3.08x |                          4.78x |
| cold_miss_large          |             1.00x |                          2.79x |                          5.22x |
| warm_hit_small           |             1.00x |                          1.59x |                          1.79x |
| warm_hit_large           |             1.00x |                          1.51x |                          1.81x |
| same_url_burst_small     |             1.00x |                          2.52x |                          1.56x |
| many_distinct_keys_small |             1.00x |                          2.85x |                          6.60x |

## Notes

- Corpus: `small` = 4 KiB, `large` = 96 KiB; synthetic `bench.invalid` URLs.
- No Hive box name / SQL plan assertions in the harness.
- Warm-hit rows measure store hit cost after a seeded write (ours waits for
  durable write-through). Cold-miss / burst / many-keys include MockClient
  fetch + write cost — see [`README.md`](README.md).
- Stock sqflite uses `sqflite_common_ffi` so desktop VM tests can open
  `CacheObjectProvider` without a mobile plugin registrant.
- Adapters are emptied between rows and closed after an ~11s settle so stock
  FCM’s deferred cleanup timer does not race a closed database.

## Profile scroll-pressure matrix

Optional, **real-device `--profile` only** — not a CI merge gate. Does not
replace core store microbenches or the bytes tables above.

Default subset: `medium/medium/ordinary` + `medium/medium/complicated`
(ours-only; paint via `CachedNetworkSvgImage` + controlled SVG corpus).
Full factorial (`MATRIX=full`): every list × speed × complexity (18 cells).

| Axis       | Tokens                       | Contract |
| ---------- | ---------------------------- | -------- |
| List size  | small / medium / large       | 24 / 48 / 120 items |
| Scroll     | slow / medium / fast         | See README gesture recipes |
| Complexity | ordinary / complicated       | Ordinary = 4 unique small SVGs + warm settle; complicated = many keys, mixed under/over 64 KiB, coalesce bursts, first-pass misses |

Harvest with:

```shell
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart --profile --no-dds -d <device> \
  --dart-define=MATRIX=full
dart run tool/summarize_timeline.dart
```

Profile percentiles are device-specific host-feel evidence — not a substitute
for the bytes ratios above.

### Environment (profile)

|         |                                              |
| ------- | -------------------------------------------- |
| Device  | SM S938B (`R5CY22MNSMZ`), Android 16 (API 36) |
| Flutter | 3.41.7 (local FVM)                           |
| Defines | `MATRIX=full`; `FEED=mixed`; `ITEM_MODE=natural` |

### Overview (`MATRIX=full`)

Compact harvest from the same TimelineSummary JSON (lower ms is better).
`miss B/R` = missed build / raster frame-budget counts.

| cell | build avg | build 99th | raster avg | raster 99th | miss B/R | frames |
| ---- | --------: | ---------: | ---------: | ----------: | -------: | -----: |
| `large/fast/complicated` | 1.07 | 2.48 | 2.26 | 2.89 | 0/2 | 1053 |
| `large/fast/ordinary` | 1.36 | 4.14 | 1.90 | 4.25 | 0/0 | 559 |
| `large/medium/complicated` | 0.61 | 2.04 | 2.08 | 2.85 | 0/0 | 960 |
| `large/medium/ordinary` | 0.73 | 2.47 | 1.67 | 4.73 | 0/0 | 527 |
| `large/slow/complicated` | 0.44 | 2.19 | 1.95 | 2.84 | 0/0 | 764 |
| `large/slow/ordinary` | 0.54 | 2.24 | 1.48 | 4.79 | 0/0 | 447 |
| `medium/fast/complicated` | 0.79 | 2.78 | 2.59 | 27.62 | 0/16 | 1053 |
| `medium/fast/ordinary` | 1.14 | 4.32 | 2.69 | 32.01 | 0/16 | 479 |
| `medium/medium/complicated` | 0.61 | 2.12 | 2.06 | 2.83 | 0/0 | 959 |
| `medium/medium/ordinary` | 0.74 | 2.44 | 1.66 | 5.26 | 0/0 | 527 |
| `medium/slow/complicated` | 0.45 | 2.18 | 1.95 | 2.83 | 0/0 | 766 |
| `medium/slow/ordinary` | 0.53 | 1.95 | 1.55 | 5.23 | 0/0 | 447 |
| `small/fast/complicated` | 0.44 | 2.76 | 2.62 | 26.90 | 0/16 | 1056 |
| `small/fast/ordinary` | 0.70 | 2.34 | 2.86 | 32.18 | 0/16 | 399 |
| `small/medium/complicated` | 0.45 | 2.14 | 2.37 | 28.18 | 0/12 | 959 |
| `small/medium/ordinary` | 0.61 | 2.15 | 2.34 | 32.02 | 0/12 | 491 |
| `small/slow/complicated` | 0.43 | 1.91 | 1.93 | 2.79 | 0/0 | 764 |
| `small/slow/ordinary` | 0.54 | 1.91 | 1.53 | 4.58 | 0/0 | 447 |

**Read:** build stays under budget everywhere (0 missed build frames). Raster
pressure shows up under **fast** (and some **small/medium** medium-speed)
cells — high raster 99ths (~27–32 ms) and missed raster budgets (12–16). Slow
and most medium-speed cells stay clean (0/0). Worst raster 99th:
`small/fast/ordinary` (32.18 ms). Worst build 99th: `medium/fast/ordinary`
(4.32 ms). `large/fast/complicated` only 2 raster misses despite high frame
count — list length alone is not the jank story; scroll intensity is.

### Per-cell TimelineSummary

<details>
<summary>Full per-cell tables (paste from summarize)</summary>

Profile-mode image feed — cell `large/fast/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             1.07 |
| frame build 90th (ms)   |             1.83 |
| frame build 99th (ms)   |             2.48 |
| frame build worst (ms)  |             3.33 |
| raster avg (ms)         |             2.26 |
| raster 90th (ms)        |             2.79 |
| raster 99th (ms)        |             2.89 |
| raster worst (ms)       |            27.43 |
| missed build frames     |                0 |
| missed raster frames    |                2 |
| frame count             |             1053 |


Profile-mode image feed — cell `large/fast/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             1.36 |
| frame build 90th (ms)   |             3.12 |
| frame build 99th (ms)   |             4.14 |
| frame build worst (ms)  |             5.80 |
| raster avg (ms)         |             1.90 |
| raster 90th (ms)        |             2.60 |
| raster 99th (ms)        |             4.25 |
| raster worst (ms)       |             6.98 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              559 |


Profile-mode image feed — cell `large/medium/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.61 |
| frame build 90th (ms)   |             1.44 |
| frame build 99th (ms)   |             2.04 |
| frame build worst (ms)  |             2.66 |
| raster avg (ms)         |             2.08 |
| raster 90th (ms)        |             2.76 |
| raster 99th (ms)        |             2.85 |
| raster worst (ms)       |             2.92 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              960 |


Profile-mode image feed — cell `large/medium/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.73 |
| frame build 90th (ms)   |             1.59 |
| frame build 99th (ms)   |             2.47 |
| frame build worst (ms)  |             3.58 |
| raster avg (ms)         |             1.67 |
| raster 90th (ms)        |             2.57 |
| raster 99th (ms)        |             4.73 |
| raster worst (ms)       |             5.34 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              527 |


Profile-mode image feed — cell `large/slow/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.44 |
| frame build 90th (ms)   |             0.80 |
| frame build 99th (ms)   |             2.19 |
| frame build worst (ms)  |             2.51 |
| raster avg (ms)         |             1.95 |
| raster 90th (ms)        |             2.75 |
| raster 99th (ms)        |             2.84 |
| raster worst (ms)       |             2.91 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              764 |


Profile-mode image feed — cell `large/slow/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.54 |
| frame build 90th (ms)   |             1.35 |
| frame build 99th (ms)   |             2.24 |
| frame build worst (ms)  |             2.46 |
| raster avg (ms)         |             1.48 |
| raster 90th (ms)        |             2.42 |
| raster 99th (ms)        |             4.79 |
| raster worst (ms)       |             5.65 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              447 |


Profile-mode image feed — cell `medium/fast/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.79 |
| frame build 90th (ms)   |             1.88 |
| frame build 99th (ms)   |             2.78 |
| frame build worst (ms)  |             3.48 |
| raster avg (ms)         |             2.59 |
| raster 90th (ms)        |             2.95 |
| raster 99th (ms)        |            27.62 |
| raster worst (ms)       |            36.80 |
| missed build frames     |                0 |
| missed raster frames    |               16 |
| frame count             |             1053 |


Profile-mode image feed — cell `medium/fast/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             1.14 |
| frame build 90th (ms)   |             2.98 |
| frame build 99th (ms)   |             4.32 |
| frame build worst (ms)  |             5.82 |
| raster avg (ms)         |             2.69 |
| raster 90th (ms)        |             2.75 |
| raster 99th (ms)        |            32.01 |
| raster worst (ms)       |            36.86 |
| missed build frames     |                0 |
| missed raster frames    |               16 |
| frame count             |              479 |


Profile-mode image feed — cell `medium/medium/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.61 |
| frame build 90th (ms)   |             1.46 |
| frame build 99th (ms)   |             2.12 |
| frame build worst (ms)  |             2.87 |
| raster avg (ms)         |             2.06 |
| raster 90th (ms)        |             2.75 |
| raster 99th (ms)        |             2.83 |
| raster worst (ms)       |             2.93 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              959 |


Profile-mode image feed — cell `medium/medium/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.74 |
| frame build 90th (ms)   |             1.63 |
| frame build 99th (ms)   |             2.44 |
| frame build worst (ms)  |             3.06 |
| raster avg (ms)         |             1.66 |
| raster 90th (ms)        |             2.56 |
| raster 99th (ms)        |             5.26 |
| raster worst (ms)       |            10.85 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              527 |


Profile-mode image feed — cell `medium/slow/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.45 |
| frame build 90th (ms)   |             0.83 |
| frame build 99th (ms)   |             2.18 |
| frame build worst (ms)  |             2.75 |
| raster avg (ms)         |             1.95 |
| raster 90th (ms)        |             2.74 |
| raster 99th (ms)        |             2.83 |
| raster worst (ms)       |             3.49 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              766 |


Profile-mode image feed — cell `medium/slow/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.53 |
| frame build 90th (ms)   |             1.41 |
| frame build 99th (ms)   |             1.95 |
| frame build worst (ms)  |             2.25 |
| raster avg (ms)         |             1.55 |
| raster 90th (ms)        |             2.52 |
| raster 99th (ms)        |             5.23 |
| raster worst (ms)       |             6.06 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              447 |


Profile-mode image feed — cell `small/fast/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.44 |
| frame build 90th (ms)   |             1.22 |
| frame build 99th (ms)   |             2.76 |
| frame build worst (ms)  |             3.09 |
| raster avg (ms)         |             2.62 |
| raster 90th (ms)        |             2.97 |
| raster 99th (ms)        |            26.90 |
| raster worst (ms)       |            32.69 |
| missed build frames     |                0 |
| missed raster frames    |               16 |
| frame count             |             1056 |


Profile-mode image feed — cell `small/fast/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.70 |
| frame build 90th (ms)   |             1.71 |
| frame build 99th (ms)   |             2.34 |
| frame build worst (ms)  |             3.23 |
| raster avg (ms)         |             2.86 |
| raster 90th (ms)        |             2.86 |
| raster 99th (ms)        |            32.18 |
| raster worst (ms)       |            35.03 |
| missed build frames     |                0 |
| missed raster frames    |               16 |
| frame count             |              399 |


Profile-mode image feed — cell `small/medium/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.45 |
| frame build 90th (ms)   |             1.20 |
| frame build 99th (ms)   |             2.14 |
| frame build worst (ms)  |             2.85 |
| raster avg (ms)         |             2.37 |
| raster 90th (ms)        |             2.83 |
| raster 99th (ms)        |            28.18 |
| raster worst (ms)       |            35.16 |
| missed build frames     |                0 |
| missed raster frames    |               12 |
| frame count             |              959 |


Profile-mode image feed — cell `small/medium/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.61 |
| frame build 90th (ms)   |             1.39 |
| frame build 99th (ms)   |             2.15 |
| frame build worst (ms)  |             2.59 |
| raster avg (ms)         |             2.34 |
| raster 90th (ms)        |             2.61 |
| raster 99th (ms)        |            32.02 |
| raster worst (ms)       |            40.05 |
| missed build frames     |                0 |
| missed raster frames    |               12 |
| frame count             |              491 |


Profile-mode image feed — cell `small/slow/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.43 |
| frame build 90th (ms)   |             0.78 |
| frame build 99th (ms)   |             1.91 |
| frame build worst (ms)  |             2.69 |
| raster avg (ms)         |             1.93 |
| raster 90th (ms)        |             2.70 |
| raster 99th (ms)        |             2.79 |
| raster worst (ms)       |             2.85 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              764 |


Profile-mode image feed — cell `small/slow/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.54 |
| frame build 90th (ms)   |             1.36 |
| frame build 99th (ms)   |             1.91 |
| frame build worst (ms)  |             2.14 |
| raster avg (ms)         |             1.53 |
| raster 90th (ms)        |             2.49 |
| raster 99th (ms)        |             4.58 |
| raster worst (ms)       |             5.99 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              447 |


</details>


### Density controls (`FEED=prose`, `ITEM_MODE=fixed`)

Same device; default `MATRIX=subset` only. Identical payload per row + fixed
row height — content-per-frame / fling-distance control vs mixed/natural.

Profile-mode image feed — cell `medium/medium/complicated` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.55 |
| frame build 90th (ms)   |             1.21 |
| frame build 99th (ms)   |             2.14 |
| frame build worst (ms)  |             2.75 |
| raster avg (ms)         |             1.96 |
| raster 90th (ms)        |             2.63 |
| raster 99th (ms)        |             2.73 |
| raster worst (ms)       |             5.52 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              959 |


Profile-mode image feed — cell `medium/medium/ordinary` (real frame timings; lower is better)

| metric                  |             ours |
| ----------------------- | ---------------: |
| frame build avg (ms)    |             0.67 |
| frame build 90th (ms)   |             1.64 |
| frame build 99th (ms)   |             2.58 |
| frame build worst (ms)  |             2.72 |
| raster avg (ms)         |             1.51 |
| raster 90th (ms)        |             2.42 |
| raster 99th (ms)        |             3.96 |
| raster worst (ms)       |             5.00 |
| missed build frames     |                0 |
| missed raster frames    |                0 |
| frame count             |              527 |

