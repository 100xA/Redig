# Efficiency fork

DigUp's separation between the engine, embedding runtime and platform interfaces is worth keeping. This fork improves
work inside those boundaries rather than replacing the application architecture.

Original project: [ARahim3/DigUp](https://github.com/ARahim3/DigUp), created by **Abdur Rahim**. The original MIT
copyright, license and third party notices remain intact. Fork changes and the replacement icon are maintained in
[100xA/DigUp](https://github.com/100xA/DigUp), starting from upstream commit
`ec28973268b81f836be72187ff23b3a16ef4fd97`. Implementation and verification were assisted by OpenAI Codex.

## Search

- A bounded SQLite change journal updates the dense vector cache by changed file. Repeated refreshes read no
  unchanged vector blobs; file state and metadata updates do not reload embeddings. A reader that falls behind the
  retained journal takes a complete snapshot.
- Queries refresh metadata, check the query encoder's vector source and hydrate results inside one deferred WAL read
  transaction. A replacement file cannot inherit a deleted file's vector: file and segment IDs are never reused.
- Folder, extension and kind rules apply before result limits. Missing files are checked among candidates and
  replaced by the next eligible result. A stale or excluded high ranking file no longer empties the visible list.
- Keyword retrieval ranks IDs first and creates snippets only for final results. The covering segment index avoids
  reading vector blobs during keyword lookups. The candidate budget counts distinct eligible files, so one long
  document cannot consume the old segment cap. BM25 breaks ties between equal fused scores.
- Modality statistics use fixed numeric slots instead of per-vector dictionary lookups. Their centering, small-group
  fallback, long-file scale rules and deviation floor retain the existing scoring formula.

The default remains exact search over normalized 768 dimensional float16 vectors. This fork does not introduce ANN,
smaller embeddings or a new retrieval model. Such changes need separate recall measurements on real collections.

Reproduce the model-free search benchmark on macOS with Swift 6.2 or later:

```sh
bash scripts/benchmark-search.sh 10000 100000
```

The script builds the same deterministic fixture against upstream `ec28973268b81f836be72187ff23b3a16ef4fd97`
and the current working tree, without downloading a model or building llama.cpp. Each fixture has ten segments per
file, a seeded bank of 256 normalized 768-dimensional vectors stored as float16, and seven-word text containing the
common query term in every segment. It reports median/p95 times, fixture construction cost and database bytes.
Searches use 21 repetitions, reloads seven, vector math/statistics 31, and unchanged refreshes 101. Loads follow
fixture creation and use warm filesystem caches; these are not cold-disk or inference benchmarks. The fixture is
intentionally repetitive and does not measure retrieval recall.

A paired release run on 2026-10-15 used an Apple M5, 16 GiB RAM, macOS 26.6.2 and Swift 6.4. Both variants were
compiled before either was timed. For 100,000 segments / 10,000 files, warm median milliseconds were:

| Operation | Upstream baseline | Fork |
| --- | ---: | ---: |
| Complete vector reload | 338.13 | 326.76 |
| Meaning search, 40 results | 29.52 | 24.08 |
| Common-term keyword search, 40 results | 363.78 | 242.00 |
| Common-term hybrid search, 40 results | 364.06 | 246.95 |
| Score statistics / normalization | 6.47 | 2.02 |

The fork's unchanged refresh took **0.006 ms** and a one-file append refresh took **0.063 ms**. The latter rereads
only the changed file (growing from 10 to 31 vectors across the 21 samples), rather than forcing a complete vector
reload. Initial complete load was 273.51 ms upstream and 285.21 ms in the fork; the additional cached segment/file
mappings carry a small startup and memory cost.

Maintaining the journal and covering index increased bulk fixture construction from **1.48 s to 2.04 s (+38%)**.
Database size increased from 220.2 MB to 222.1 MB. This write overhead is a tradeoff for committed incremental reads;
fixture construction bypasses model inference and is reported separately from search times.

Set `KEEP_BENCHMARK=1` to retain both generated packages, executables and databases for further paired runs without
recompiling. The script prints their temporary directory; each executable accepts segment counts as arguments.

## Indexing

- Long documents reuse extracted chunks for the same file version. The cache keeps one decoded document in memory
  and up to 64 MiB of extracted chunks in per-indexer scratch storage. Code project discovery is cached by folder while titles remain
  specific to each file.
- Audio and video are decoded and committed in bounded ranges, with resumable checkpoints. The default first step is
  12 audio-hop windows (about five minutes). Remaining work joins the existing long-file pass, allowing other files
  to become searchable sooner. This bounds work per step; it does not promise a hard memory ceiling for every codec.
- Failed PDF image embeddings and media windows do not silently become successful checkpoints. Retries stop after
  three failures, report a visible failure and preserve earlier successful segments.
- Source metadata is checked again before committing embeddings. If a file changed while being processed, stale
  output is discarded and the current file is queued again. Same-path replacement checks include device and inode.
- Extraction policy changes selectively requeue affected file kinds, separately from embedding compatibility. Legacy
  code indexes are rebuilt once to adopt the corrected discovery and eligibility rules; other kinds are retained.
- Incomplete directory reads and cloud placeholders preserve existing entries. Availability is checked before
  content sniffing. Canonical paths make alias roots consistent with exclusions and git rules; Windows directory
  traversal rejects junction/symlink reparse points and tracks visited identities.
- Hidden `.gitignore`, `.git/info/exclude` and `.git` changes invalidate their enclosing scope. Work excluded before
  preparation is also excluded from prefetch.

Indicative release-build phase measurements on one macOS arm64 machine, without a model:

| Synthetic workload | Repeated discovery/extraction | Cached | Scope |
| --- | ---: | ---: | --- |
| Project discovery for 1,000 files in one non-git folder | 30.678 s | 0.213 s | Includes 1,000 distinct cached file titles |
| A 1.14 MB document across 16 continuation steps | 2.687 s | 0.151 s | One actual extraction with the shared cache |

These measurements isolate the affected phases; they are not end-to-end indexing speedups. Timing depends on the
machine and filesystem cache.

## Runtime and interface

- The portable search helper reads commands independently from bounded preview rendering. Keyword searches and index
  refreshes run independently from model startup and query encoding. Per-client generations coalesce superseded
  queries; a model that becomes available later can be retried.
- Helper restarts replay current configuration. Per-index sync generations prevent a change arriving during a crawl
  from being acknowledged as though that later change was included. Watcher buffering and debounce are bounded.
- Preview promises use a bounded LRU cache keyed by file version and helper generation. Failures are evicted, and
  helper lifecycle changes clear and repaint previews.
- Portable CPU startup probes CPU backends without first initializing GPU drivers. GPU calibration runs in an
  isolated subprocess; a failed GPU trial retains the working CPU baseline.

## Branding and releases

The new minimal D/lens icon is an editable [Icon Composer document](../Resources/AppIcon/AppIcon.icon), with flat
fallbacks for older macOS, Windows and Linux. [Asset notes](../Resources/AppIcon/README.md) include a reproducible
render command. The original application and its previous branding remain credited to Abdur Rahim.

Upstream automatic updates are disabled so an upstream package cannot replace this fork. A maintainer can enable a
separate signed feed: on macOS, set `FORK_UPDATES=1`, `SPARKLE_FEED` and `SPARKLE_KEY` when building; for the portable
shell, configure its updater endpoint/public key before compiling with `DIGUP_ENABLE_SIGNED_UPDATES=1`. No fork
release packages or signing keys are supplied here. Upgrading an existing index to schema 6 is transactional and
preserves its vectors and keyword text; older upstream versions cannot open that migrated index.

## Validation

The engine regression suite runs without downloading a model:

```sh
bash scripts/test-kit.sh
bash scripts/test-search-service.sh
node --test shell/tests/*.test.cjs
cargo test --locked --manifest-path shell/src-tauri/Cargo.toml
```

The engine shortcut currently targets macOS; use the main package's `swift test` after installing its portable vendor
libraries on Linux or Windows. The fork's Checks workflow runs engine regressions on macOS and shell checks on
macOS, Linux and Windows.

The service harness compiles the production `SearchService.swift` with deterministic slow model and preview
substitutes. It checks keyword responsiveness during model startup and a full preview queue, coalescing of 50 rapid
queries, and recovery after an initial encoder startup failure. Its timing checks describe queue isolation rather
than real model inference speed.

The added engine regressions cover snapshot/source consistency, incremental updates, ID reuse, migration, result
eligibility, long-file keyword starvation, statistics equivalence, source mutation, replacement files, extraction
policy, unavailable paths, and PDF/audio/video failure and continuation. Existing engine tests remain part of the run.

Model-free tests verify the scheduling, persistence and retrieval mechanics. Full model reference-vector and real
collection relevance evaluations require the model files and remain separate checks; no end-to-end inference or
recall improvement is claimed from synthetic benchmarks.
