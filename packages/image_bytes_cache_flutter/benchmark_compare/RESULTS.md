# Benchmark results: bytes + raster compare

Numbers for **image_bytes_cache** vs **cached_network_image_ce** (Hive) vs
stock **cached_network_image** (sqflite). Machine-specific. Regenerate with the
commands in [`README.md`](README.md).

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

From `flutter test test/bytes_compare_test.dart` (min-of-batches). Lower is
better. Slim scenario set (small corpus only).

| scenario                 | bytes | image_bytes_cache | cached_network_image_ce (Hive) | cached_network_image (sqflite) |
| ------------------------ | ----: | ----------------: | -----------------------------: | -----------------------------: |
| cold_miss_small          |  4096 |             575.5 |                         1244.8 |                         2566.5 |
| warm_hit_small           |  4096 |             263.5 |                          299.1 |                          349.6 |
| same_url_burst_small     |  4096 |            3914.0 |                         8560.0 |                         6473.0 |
| many_distinct_keys_small |  4096 |            5073.0 |                        10420.0 |                        24224.0 |

## Relative to ours

`× = adapter_us / ours_us`. Values > 1 mean slower than ours on this machine.

| scenario                 | image_bytes_cache | cached_network_image_ce (Hive) | cached_network_image (sqflite) |
| ------------------------ | ----------------: | -----------------------------: | -----------------------------: |
| cold_miss_small          |             1.00x |                          2.16x |                          4.46x |
| warm_hit_small           |             1.00x |                          1.13x |                          1.33x |
| same_url_burst_small     |             1.00x |                          2.19x |                          1.65x |
| many_distinct_keys_small |             1.00x |                          2.05x |                          4.78x |

## Notes

- Corpus: `small` = 4 KiB; synthetic `bench.invalid` URLs.
- Large twins dropped. Ratios were near-duplicates. Size cut is covered by the
  raster complicated corpus (≥64 KiB PNG bodies).
- No Hive box name / SQL plan assertions in the harness.
- Stock sqflite uses `sqflite_common_ffi` for desktop VM tests.

## Profile scroll (raster, three-way)

Not a CI merge gate. Prefer a real device with `--profile` for the Android
tables. Chrome `web-server` drive adds correctness and noisier debug timings.

Curated cells (default all three × ours / ce_hive / stock_cni):

| Cell | Contract |
| ---- | -------- |
| `warm-scroll` | medium list, medium fling, ordinary PNG, warm settle |
| `cold-scroll` | medium list, medium fling, complicated PNG, first-pass misses |
| `pressure-scroll` | large list, fast fling, complicated PNG |

Paint via `CachedNetworkBytesImage` (ours) and `CachedNetworkImage` (CE /
stock) over the shared PNG corpus. Competitor fades are zero. On web,
competitors use `ImageRenderMethodForWeb.HttpGet` so MockClient stays in path.

```shell
# Device / desktop profile (primary harvest):
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart --profile --no-dds -d <device>
dart run tool/summarize_timeline.dart

# Chrome web (ChromeDriver on :4444):
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart \
  -d web-server --browser-name=chrome --driver-port=4444
dart run tool/summarize_timeline.dart
```

### How to read these tables

On Android `--profile`, care about missed raster frames and raster worst first.
Frame-build averages are secondary. A few tenths of a millisecond more build is
not jank if every cell stays under ~16.6 ms at 60 fps and missed build frames
stay at 0.

Ours often looks slower on frame build. That is a tradeoff, not a hole in the
durable cache or isolate path. The bytes tables already favor us.

A lot of the build gap is the compare app itself. Ours paints with
`CachedNetworkBytesImage`, `loadingBuilder`, and `gaplessPlayback: true`. CE and
stock use a static `placeholder` and zero fades. Chunk progress rebuilds the
tree; a placeholder swaps once. That alone lifts the build column. It does not
mean the resolve ladder is wrong.

Cold and pressure also finish more work inside the timed window. After a
complicated fling the test pumps a fixed frame count. It does not wait for
every stack to drain. We resolve bytes faster, so more images decode and lay
out on the UI thread while competitors sit on grey boxes and later dump raster
spikes.

After warm `pumpAndSettle` a little wrapper cost remains (stateful thin `Image`
plus an attached `loadingBuilder`). Still in budget.

Do not chase build parity. Softening the pressure paint path to look better on
build averages can give back the raster-miss win, and that is the number people
feel as jank. An optional harness run with a static placeholder on ours is fine
if you want a fairer build column. It is not a package API fire drill.

Chrome web tables below are debug `web-server` drives, not `--profile`. Tails
and single-frame worst times jump around. Use them for "does it paint" and a
rough look, not for claiming a web bottleneck or shipping a web fix. Re-run
Chrome with `--profile` first if you want web numbers that stick.

### Harvest: SM S938B (Android 16, `--profile`)

SM S938B (`R5CY22MNSMZ`), Android 16. Curated cells × three paint adapters
(`FEED=mixed`, `ITEM_MODE=natural`).

Under `pressure-scroll`, ours missed 0 raster frames (worst 2.64 ms). CE and
stock missed 4 and 8 (worst about 29-32 ms). Warm and cold are clean on missed
frames for all three. Ours spends a bit more on frame build: still 0 missed
build frames, and pressure build worst 10.57 ms stays under budget. That cost
is the tradeoff above, not something to hunt down. Package READMEs summarize;
tables below are the source of truth.

Profile-mode image feed, cell `cold-scroll` (real frame timings; lower is better)

| metric                  |             ours |          ce_hive |        stock_cni |
| ----------------------- | ---------------: | ---------------: | ---------------: |
| frame build avg (ms)    |             0.66 |             0.59 |             0.58 |
| frame build 90th (ms)   |             1.74 |             1.23 |             1.25 |
| frame build 99th (ms)   |             2.64 |             1.90 |             1.78 |
| frame build worst (ms)  |             3.57 |             2.48 |             2.42 |
| raster avg (ms)         |             1.43 |             1.77 |             1.75 |
| raster 90th (ms)        |             2.41 |             2.44 |             2.43 |
| raster 99th (ms)        |             2.52 |             2.53 |             2.52 |
| raster worst (ms)       |             2.59 |             2.58 |             2.83 |
| missed build frames     |                0 |                0 |                0 |
| missed raster frames    |                0 |                0 |                0 |
| frame count             |              958 |              956 |              960 |


Profile-mode image feed, cell `pressure-scroll` (real frame timings; lower is better)

| metric                  |             ours |          ce_hive |        stock_cni |
| ----------------------- | ---------------: | ---------------: | ---------------: |
| frame build avg (ms)    |             1.41 |             0.99 |             1.01 |
| frame build 90th (ms)   |             2.65 |             1.60 |             1.61 |
| frame build 99th (ms)   |             3.66 |             2.11 |             2.10 |
| frame build worst (ms)  |            10.57 |             3.21 |             2.56 |
| raster avg (ms)         |             1.84 |             2.01 |             2.11 |
| raster 90th (ms)        |             2.43 |             2.45 |             2.46 |
| raster 99th (ms)        |             2.52 |             2.89 |             3.19 |
| raster worst (ms)       |             2.64 |            29.24 |            32.19 |
| missed build frames     |                0 |                0 |                0 |
| missed raster frames    |                0 |                4 |                8 |
| frame count             |             1053 |             1054 |             1051 |


Profile-mode image feed, cell `warm-scroll` (real frame timings; lower is better)

| metric                  |             ours |          ce_hive |        stock_cni |
| ----------------------- | ---------------: | ---------------: | ---------------: |
| frame build avg (ms)    |             0.89 |             0.69 |             0.69 |
| frame build 90th (ms)   |             2.28 |             1.54 |             1.53 |
| frame build 99th (ms)   |             4.00 |             2.28 |             2.34 |
| frame build worst (ms)  |             4.43 |             2.55 |             2.57 |
| raster avg (ms)         |             1.29 |             1.38 |             1.37 |
| raster 90th (ms)        |             2.17 |             2.25 |             2.24 |
| raster 99th (ms)        |             4.28 |             4.40 |             4.43 |
| raster worst (ms)       |             5.89 |             5.07 |             4.95 |
| missed build frames     |                0 |                0 |                0 |
| missed raster frames    |                0 |                0 |                0 |
| frame count             |              521 |              526 |              527 |

### Harvest: Chrome web (debug drive)

Chrome 153 + ChromeDriver,
`flutter drive -d web-server --browser-name=chrome` (debug, not `--profile`).
Same curated cells × three adapters. Competitors use
`ImageRenderMethodForWeb.HttpGet` so MockClient serves `bench.invalid`.

Do not treat these cells as a web performance problem to fix. Build averages
sit near ~4 ms across stacks, basically tied. Pressure missed raster 0 / 0 / 0.
Cold and warm worst times, and the odd missed frame, swing run to run in debug.
`warm-scroll` had one missed raster on ours (worst about 35 ms). That is noise,
not a product claim. Until someone harvests Chrome with `--profile`, keep
Android profile as what scrolling feels like on device and leave web out of the
performance story.

```shell
# ChromeDriver must already listen on 4444
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart \
  -d web-server --browser-name=chrome --driver-port=4444
dart run tool/summarize_timeline.dart
```

Debug-mode image feed, cell `cold-scroll` (Chrome web; lower is better)

| metric                  |             ours |          ce_hive |        stock_cni |
| ----------------------- | ---------------: | ---------------: | ---------------: |
| frame build avg (ms)    |                3 |             3.08 |             3.15 |
| frame build 90th (ms)   |             6.20 |             5.90 |             5.90 |
| frame build 99th (ms)   |                7 |             7.10 |             6.70 |
| frame build worst (ms)  |            23.10 |             8.40 |            34.50 |
| raster avg (ms)         |             0.61 |             0.58 |             0.61 |
| raster 90th (ms)        |                1 |             0.90 |             0.90 |
| raster 99th (ms)        |             5.10 |             5.40 |             5.20 |
| raster worst (ms)       |             5.90 |               10 |            10.20 |
| missed build frames     |                1 |                0 |                1 |
| missed raster frames    |                0 |                0 |                0 |
| frame count             |              969 |              966 |              972 |


Debug-mode image feed, cell `pressure-scroll` (Chrome web; lower is better)

| metric                  |             ours |          ce_hive |        stock_cni |
| ----------------------- | ---------------: | ---------------: | ---------------: |
| frame build avg (ms)    |             3.95 |             3.92 |             3.85 |
| frame build 90th (ms)   |             7.60 |             6.90 |             6.70 |
| frame build 99th (ms)   |             9.40 |            10.60 |             7.60 |
| frame build worst (ms)  |            27.60 |            20.90 |            28.10 |
| raster avg (ms)         |             0.61 |             0.53 |             0.60 |
| raster 90th (ms)        |                1 |             0.90 |             0.90 |
| raster 99th (ms)        |             5.40 |             5.40 |             5.30 |
| raster worst (ms)       |             8.10 |             6.40 |                8 |
| missed build frames     |                2 |                1 |                1 |
| missed raster frames    |                0 |                0 |                0 |
| frame count             |             1073 |             1071 |             1070 |


Debug-mode image feed, cell `warm-scroll` (Chrome web; lower is better)

| metric                  |             ours |          ce_hive |        stock_cni |
| ----------------------- | ---------------: | ---------------: | ---------------: |
| frame build avg (ms)    |             4.46 |             4.58 |             4.05 |
| frame build 90th (ms)   |             7.50 |             7.20 |             6.60 |
| frame build 99th (ms)   |            11.20 |             9.20 |             8.50 |
| frame build worst (ms)  |            17.10 |            12.60 |             9.20 |
| raster avg (ms)         |             0.97 |             0.77 |             0.75 |
| raster 90th (ms)        |             1.30 |             1.10 |             1.10 |
| raster 99th (ms)        |             6.20 |             5.80 |             5.60 |
| raster worst (ms)       |            34.70 |             7.10 |             8.10 |
| missed build frames     |                1 |                0 |                0 |
| missed raster frames    |                1 |                0 |                0 |
| frame count             |              515 |              515 |              515 |
