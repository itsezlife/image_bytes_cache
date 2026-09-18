# AGENTS.md

High-signal orientation for LLMs/agents working in
**`image_bytes_cache_flutter`**. Read this first. Glossary:
[`CONTEXT.md`](CONTEXT.md). Sibling core:
[`../image_bytes_cache/`](../image_bytes_cache/).

## Owns

- Flutter widgets that paint resolved image **bytes** (including
  `CachedNetworkSvgImage`).
- Widget tests for those adapters.
- UI/profile benches and flutter-side `benchmark_compare` (head-to-head bytes
  tables when fair, profile feed, scroll-pressure matrix) under
  [`benchmark_compare/`](benchmark_compare/) in this package — never under
  pure-Dart core.

## Does not own

- Durable open policy, blob stores, resolve ladder, HTTP coalesce — core
  [`image_bytes_cache`](../image_bytes_cache/AGENTS.md).
- Product l10n, design tokens, or host screen chrome — design-system / app
  hosts.
- Store / ladder microbenches — core `benchmark/` (plain `dart test`).

## Bootstrap

Hosts call core `ImageBytesCache.open` / `configure` (and a host diagnostics
bridge) before paint. This package assumes a shared `IImageBytesResolver` is
available (`ImageBytesResolver.shared` or an injected resolver). Do not open
files, sockets, or durable stores from widgets.

## Hard rules

1. **Depend on core contracts only** (`IImageBytesResolver`, `ImageCacheKey`,
   request types). Do not reimplement ladder, coalesce, or blob IO here.
2. **Soft paint failures stay widget-local** (`onError` / `errorBuilder` for
   resolve **and** SVG decode/paint — never endless placeholder alone). No
   product logger inside paint adapters.
3. **PageStorage identity** aligns with `ImageCacheKey` when a short-lived
   copy is kept for scroll restore; keep it bounded / opt-out
   (`pageStorageMaxBytes` / `persistInPageStorage`), never a second durable
   store.
4. **No dual implementations** in host design-system packages — migrate or
   re-export; do not keep a second resolve/paint tree beside this package.
5. **Profile / compare harnesses** that need a Flutter binding live in this
   package’s [`benchmark_compare/`](benchmark_compare/), not in core
   `benchmark/`.

## Commands

From this package root:

```shell
flutter pub get
flutter test
flutter analyze
```

Core store microbenches and Chrome open smoke stay in
[`../image_bytes_cache/`](../image_bytes_cache/AGENTS.md).

Three-way bytes compare and profile scroll-pressure matrix (optional
real-device `--profile`, not a merge gate):
[`benchmark_compare/`](benchmark_compare/).

Profile matrix defines (details + recipes in
[`benchmark_compare/README.md`](benchmark_compare/README.md)):

| Define      | Values                         | Role |
| ----------- | ------------------------------ | ---- |
| `MATRIX`    | `subset` (default) / `full`    | Day-to-day two cells vs full 18-cell factorial |
| `CELL`      | `list/speed/complexity`        | Optional single-cell override |
| `FEED`      | `mixed` / `prose`              | Complexity corpus vs repeated payload |
| `ITEM_MODE` | `natural` / `fixed`            | Natural row height vs fixed clip |

Cell ids look like `large/fast/complicated`. Harvest with
`dart run tool/summarize_timeline.dart` into `RESULTS.md`. Not a merge gate;
does not replace core store or bytes-table ratios.

## The docs

- [`CONTEXT.md`](CONTEXT.md): paint-adapter glossary.
- [`CHANGELOG.md`](CHANGELOG.md): package history.
- Core engine: [`../image_bytes_cache/AGENTS.md`](../image_bytes_cache/AGENTS.md),
  [`../image_bytes_cache/CONTEXT.md`](../image_bytes_cache/CONTEXT.md).
