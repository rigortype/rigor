# ADR-45 — Unchanged-project fast path (run-result cache)

Status: **Accepted — record-and-validate run cache landed. The naive pre-analysis fingerprint was rejected (proven unsound by the `pundit_plugin_spec` cross-process regression); the sound record-and-validate design is implemented and verified — an unchanged Mastodon `app/models` (248 files) drops 11.6 s → 1.8 s (~6×), diagnostics byte-identical, `make verify` green.**

`rigor check` re-runs the **entire per-file inference** on every
invocation, even when nothing in the project has changed. The persistent
cache (`.rigor/cache`, ADR-6) holds only intermediate artefacts — the RBS
environment and per-producer plugin tables — keyed by content-addressed
`Cache::Descriptor`s; it does **not** cache analysis *results*. So
`CheckRules.diagnose` over every file — the allocation-bound work all of
ADR-44's profiling measured, ~90 %+ of wall on a warm run — is repaid in
full to reproduce a byte-identical result. On GitLab's configured subset
(2,630 files, 11 plugins) that is ~100–150 s to learn "nothing changed."

This ADR designs a fast path that serves an unchanged project's whole
result from cache, and records why the obvious implementation is unsound.

Grounding: the profiles in
[`docs/notes/20260604-gitlab-plugin-contribution-allocation.md`](../notes/20260604-gitlab-plugin-contribution-allocation.md)
and the cache architecture in [ADR-6](6-cache-persistence-backend.md).

## Context — what a run's diagnostics depend on

1. **Each analyzed file's content.**
2. **Other analyzed files' content** — cross-file user-method return
   inference (`infer_user_method_return`): file A calling `B#foo` adopts
   `B#foo`'s *inferred* return type, which depends on `B#foo`'s **body**.
   Any analyzed-file change can change another file's diagnostics.
3. **Files the plugins read** — and *when* they read them. Some are read
   during `prepare` (rails-routes' `config/routes.rb`, actionpack's
   controllers); **others are read on demand during per-file analysis**.
   `rigor-pundit` reads a policy file the first time it sees an
   `authorize` call, to check the policy defines the action — i.e. **after**
   the pre-passes, mid-`analyze_files`. And the files the plugins looked
   for and did **not** find: a plugin that probes for `db/schema.rb` and
   gets nothing shapes its result on the absence, a dependency of the
   opposite sign (WD1).
4. **The RBS environment** — `Gemfile.lock` gem set, `sig/` files, the
   `rbs` version, `target_ruby`.
5. **Config** — `severity_profile`, `disabled_rules`, `plugins`, `paths`,
   `exclude`, `pre_eval`, `--explain`, …
6. **The engine** — `Rigor::VERSION` / cache schema.

## Decision

### Rejected — whole-run cache keyed on a pre-analysis fingerprint

The first cut (prototyped and reverted) wrapped the diagnostic
computation in `Cache::Store#fetch_or_compute`, keyed on a
`Cache::Descriptor` composed **after the pre-passes** from: every analyzed
file's digest, the RBS descriptor (gems + sig), each plugin's
`io_boundary.cache_descriptor`, a digest of `Configuration#to_h`, and
`Rigor::VERSION`.

It passed the basic soundness checks (unchanged → hit with byte-identical
diagnostics; fix an error → miss → fresh result) but **failed
`spec/integration/plugins/pundit_plugin_spec.rb`'s cross-process
cache-invalidation regression test**, which is the canonical guard for
exactly this hazard:

> write a policy *without* `archive` → `rigor check` flags the
> `authorize :archive` call; rewrite the policy *with* `archive` → a
> second `rigor check` (fresh process, same cache) must **not** flag it.

The fingerprint is built right after the pre-passes, but Pundit reads the
policy file **during** `analyze_files` (per `authorize` call). So at
fingerprint time the policy read has not happened yet, the analyzed file
(`demo.rb`) is unchanged, and the fingerprint is identical across both
runs → the second run is a stale hit and re-reports the fixed call. **A
fingerprint computed before the analysis cannot capture inputs the
analysis itself discovers.** Shipping it would manufacture false
positives across edits — the worst failure mode for a correctness tool —
so it is rejected.

### Accepted (landed) — record-and-validate dependencies

The sound model inverts the order: **run, recording every input actually
read; cache the result alongside that dependency set; on the next run,
validate the recorded dependencies by re-reading them.**

- **Key:** stable, known before the run — the analyzed-path *set* +
  config digest (`Configuration#to_h`) + gems (`RbsDescriptor` gem/config
  entries) + `Rigor::VERSION` + `--explain`. Adding/removing a file
  changes the path set → new key; editing a file keeps the key and is
  caught by validation (so content edits reuse the same slot — no cache
  growth).
- **Stored value:** `[diagnostics, dependency_descriptor]` where the
  descriptor's `files` are collected **after** the run — analyzed files +
  the RBS `sig` files + every plugin's `io_boundary.cache_descriptor`
  (complete post-run, including analysis-time reads like the Pundit
  policy and — since WD1 — the paths a plugin probed and found missing).
  `Diagnostic` is a flat value object, so the pair is `Marshal`-clean.
- **Lookup:** `Cache::Store#fetch_or_validate` reads the entry at the
  stable key and calls `Descriptor#fresh?`, which re-digests every
  recorded `FileEntry`; **hit** only if all match (else miss → re-run →
  rewrite the same slot). It captures the Pundit policy because the policy
  is in the dependency set after the first run.

Two robustness rules the implementation enforces: **the cache must never
break a run** — a serialization/disk failure on write is swallowed (skip
caching), and any cache-path error falls back to a direct uncached
analysis; and the post-run dependency collection reads each plugin's
`@io_boundary` *without* triggering its lazy `||=` initializer (plugin
instances are frozen after the run, and a plugin that built no boundary
read no files through it). The fast path is gated to a sequential,
writable-cache, non-editor, non-prebuilt run; a cache hit returns `nil`
stats (the analysis it would summarise did not run).

Verified: an unchanged Mastodon `app/models` (248 files) drops **11.6 s →
1.8 s (~6×)**; `fix-an-error → 0 errors` (no stale); the
`pundit_plugin_spec` cross-process regression and the per-producer cache
tests (rigor-routes, rigor-rbs-inline) pass; `make verify` green.

### Companion (landed) — the verification gate is cache-proof

The result cache must never let the project's own gate read a stale
result, and the fingerprint deliberately excludes engine code (only
`Rigor::VERSION`), so an engine edit that leaves the version unchanged
could be masked by a hit. `make check` / `check-plugins` therefore run
`rigor check --no-cache` — the gate always re-runs the analysis. A
developer running `rigor check` on a real project after editing `lib/`
should `--clear-cache` (or `--no-cache`) the same way.

### WD1 (landed, #577) — absence is a dependency too

The record-and-validate set as landed recorded only **successful** reads:
`IoBoundary#read_file` added a `FileEntry` when the read returned bytes
and nothing when it raised. A plugin that probes for a file, finds none,
and shapes its result on the absence — rigor-activerecord's reduced mode on
a missing `db/schema.rb` (#569) — therefore left no edge for the file's
later appearance to invalidate: a warm run kept serving the reduced index
and its now-false "schema not found" disclosure until some other recorded
input moved (found in #576's review; the attribution probe showed the
staleness class predates #576). The inverse edit — removing a file a run
had read — was already caught, because the recorded read row reads stale
once the file is gone. The dependency set was missing its negative half:
*the analysis depended on X being absent*.

The fix records the negative half at the same surface. A `read_file` that
fails because the path does not exist (`Errno::ENOENT`, or `Errno::ENOTDIR`
for a parent component that is a regular file) records an **absence row**
— `FileEntry.absent(path:)`, the `:exists` comparator with value `"false"`
— before re-raising. Nothing else moves: the runner's post-run dependency
descriptor and each producer's dependency descriptor are both built from
the boundary's `cache_descriptor.files`, so the one recording point covers
the whole-run entry and the plugin-producer entries alike, and
`Descriptor#fresh?` already validated `:exists` rows. An absence row
validates by one `File.exist?` — no stat tuple, no digest, nothing that can
drift on an unchanged tree — so it never costs a warm run its hit.

Three bounds keep the recording deliberate. It fires only for the
not-there outcome: a path that exists but cannot be read (`EISDIR`, a
permission failure) is a failure the plugin reports, not an existence
probe, and records nothing, as before. It fires only inside the
trusted-read scope, because the policy check precedes the read. And within
one boundary a content row for a path is never replaced by an absence row
(two outcomes for one path in one run mean the file moved under the
analysis, and the content row is the one whose validation covers both
content and existence), while a successful read after a probe replaces the
absence row. `SCHEMA_VERSION` 7 → 8: a pre-8 entry carries no absence rows
and would validate fresh across exactly the edit this closes, so the marker
discipline retires it.

Gate: the rigor-activerecord warm-run fixture in
`spec/integration/plugins/activerecord_plugin_spec.rb` — a cold schema-less
run, `db/schema.rb` added, and the warm run re-analyzes (`unknown-column`
fires, the disclosure retracts) with the cache on; the schema-removed
inverse (already sound through the recorded read) and a no-churn control
(a warm run with nothing changed is still served) sit beside it, with the
boundary, descriptor, store and producer-cache halves pinned in their own
unit specs.

### WD1b (landed, #613) — the probe is the read

WD1 recorded the absence at `read_file`, which covers a plugin that
*attempts the read and fails*. Plugins do not all attempt it: the
prevailing shape gates the read on a `File.file?` / `File.directory?`
probe first (`return nil unless File.file?(config/sidekiq.yml)`, `next []
unless File.directory?(app/models)`), and a probe through `File` records
nothing at all. So on exactly the projects WD1 was written for — the ones
where the file is missing — the read never happens, no absence row is
recorded, and the warm run keeps serving the pre-appearance result. The
recording point was right; the surface was one call too late.

WD1b moves the probe itself onto the boundary. `IoBoundary#file?(path)`
and `#directory?(path)` return exactly what `File.file?` / `File.directory?`
return and record the answer as an `:exists` row: `FileEntry.present` when
the probe found what it asked for, `FileEntry.absent` when nothing exists
there, and nothing when something exists but is not what was asked for
(the bound WD1 pins for `EISDIR`, in probe form). Every plugin probe on a
boundary-managed project path is converted to them, with one named exception:
rigor-actionpack's `Analyzer` template probes (`locate_template`,
`abstract_base_controller?`) hold no boundary and try many candidate paths per
`render`, so their conversion waits on a cardinality decision (#629). A presence
row validates existence only: a directory replaced by a regular file at the same
path (or the reverse) stays fresh although the predicate would now answer
differently — a bound, not a realistic project edit.

Two calls are deliberate. The predicates answer truthfully for every path
and never raise — including outside the trusted-read scope, where they
record nothing: they replace a bare `File.file?` in plugin code, and a
predicate that raised, or answered `false` for an out-of-scope path that
exists, would change what the converted plugin *does* rather than only
what it records, which is the wrong trade under the false-positive-first
rule. And the presence row is recorded even though a probe that is
followed by a read is immediately superseded by the `:stat` content row:
the probes that are *not* followed by a read — a discovery root that is
globbed, a config file whose presence alone switches a mode — are exactly
the ones with no other edge back to the filesystem.

No `SCHEMA_VERSION` bump: WD1b adds no row kind, no comparator and no
value grammar — `:exists` / `"true"` was already constructible,
already validated by one `File.exist?`, and already ranked in
`COMPARATOR_STRICTNESS`. The one thing a bump would buy is retiring
entries written between WD1 and WD1b, which carry no probe rows; those
exist only in a mid-cycle developer's `.rigor/cache`, because
`SCHEMA_VERSION` 8 has not shipped in a release — every released cache is
≤ 7 and misses on the next upgrade regardless.

Gate: the WD1 three-fixture pattern per converted plugin — rigor-sidekiq's
`config/sidekiq.yml` probe and rigor-activestorage's discovery-root probe,
each driven cold → add → warm through the real Runner against a real
on-disk Store, plus the nothing-changed control and the remove-after-hit
inverse.

### WD2 (landed, #1507) — a second writer: the `--incremental` session

The slot above is written by a run that analysed every file. A warm
`rigor check --incremental` never is one, so [ADR-87](87-null-build-floor.md)
WD4's engine-free probe declined it, and an unchanged project paid the
incremental path's whole fixed cost to learn that nothing changed: on CI
against Mastodon (~1,400 files), 1.43 s for an `--incremental` null run
against 0.29 s for a default one — 343 ms loading the engine, 273 ms
reading the snapshot, 123 ms rebuilding its dependents indexes, 160 ms
building an environment for an empty closure, ~190 ms of discovery and
digests.

WD2 makes the incremental session a second writer. After every run whose
snapshot it persists, `IncrementalSession#run_incremental` records the
run's diagnostics — the list the CLI prints before its baseline filter,
which #1524 made a full run's list in a full run's order — in a
record-and-validate slot of its own, and `rigor check --incremental`
serves a null run from it before loading the engine
(`Analysis::IncrementalRunSlot`), with the `--incremental warm` banner the
full path prints for the same run.

**Key.** The one WD4 reconstructs from configuration alone (`RunCacheKey`:
the library list without `rbs.virtual_rbs`, no `template-units` slot,
`--explain` false), under its own producer id,
`analysis.incremental-run-diagnostics`. The two slots' keys coincide for a
project with no synthesised RBS and no template units, so the producer id
is what keeps them apart: neither probe can read the other's entry, and an
incremental defect cannot reach a default run. A synthesised RBS buffer is
a function of an analysed file's bytes (a validated row) and of the
synthesising plugin's identity and configuration (the key's
`configuration`, lockfile and engine slots), so the key needs no
`rbs.virtual_rbs` slot. A project whose plugins claim template globs gets
no slot, as it gets no WD4 hit.

**Descriptor.** A narrowed recheck read only its closure; the rest of its
answer was computed by earlier runs. Every row carries the value the
answer was computed from, from three sources:

1. One `:stat` row per analysed file, packed from the digest the session
   holds for it — for a file served from cache, the bytes its cached rows
   were computed from. A re-digest after the run would vouch for bytes
   that changed while the run was reading them.
2. What the run read itself (`Runner#incremental_slot_rows`): every plugin
   `IoBoundary` row, the producer `watch:` globs, the discovered files
   (#684), the `pre_eval:` and template files and their globs, and an
   existence row per analysis root, per `pre_eval:` entry and per
   signature root (the configured `signature_paths:`, or the auto-detected
   `sig`). The plain slot records no existence rows, but the incremental
   path regenerates every path-error row on every run, so a slot that
   served one past the edit that retracts it would print what no run of
   the tree prints. They carry WD1b's bound.
3. The **chain** the slot's value carries forward: the signature-tree rows
   (`RbsDescriptor.file_entries` / `.glob_entries`) the last full run
   recorded, and the plugin reads each file's analysis made, kept per file.
   `Runner#analyze_file` wraps each file's analysis in
   `Plugin::IoBoundary.attributing` when it records dependencies. A full
   run starts a chain; a recheck takes the previous slot's, replaces the
   reads of every file it re-analysed with this run's, and drops the
   removed files'.

Reads are kept per file, not per path, so a file served from cache keeps
validating what its own analysis read, even after another file's
re-analysis read the same path at a newer value. That is the case the
design review marked most likely to be missed: the Pundit shape above,
with the reading file served from cache by the last recheck.

**Why the chain is sound.** By induction from the full run that started
it. That run's descriptor is the plain slot's and its answer a full run's.
A recheck's answer merges this run's re-analysed files with the served
files' cached rows, and its descriptor carries this run's reads for the
first and the previous slot's for the second — by induction, the reads
those rows were computed from. That holds only if the previous slot
describes the snapshot the recheck restored. It does not when the slot is
missing (evicted, deleted, never written), or when another run rewrote the
snapshot without writing a slot: a pool run, whose workers' reads never
reach the process that would record them; `--incremental --no-cache`,
which has no store; a slot write that failed. So the slot records the
identity of the snapshot file its run left behind — `(size, mtime_ns,
ctime_ns, inode)`; a rewrite renames a new file into place — and a recheck
carries the chain only from a previous slot that exists and names the
snapshot file it restored. Otherwise it writes nothing, and the next full
run starts a fresh chain; declining costs the fast path until then and
nothing else. `Runner#incremental_slot_rows` also declines when a boundary
row changed during the per-file loop without being credited to a file (a
read from a thread the plugin started), since the next narrowed run would
drop that row.

**What is neither written nor served.** No slot is written for an editor
buffer (never persisted), a pool run, effect collection (its `effects:`
block is outside the key, and its envelope rows are #428's decline), or an
opaque plugin, whose next full-path run is cold rather than the warm run
the probe stands in for. The CLI asks the probe only for a plain
`--incremental`: not `--no-cache`, `--verify-incremental`, a worker pool,
`--coverage`, `--cache-stats`, a `RIGOR_*_TRACE` probe, or `--explain`,
which the session does not honour yet (#1533) and so writes no slot keyed
by. A hit prints the incremental tail
(`CheckCommand#write_incremental_result`), not the ordinary check's.

`Runner#run_result_cacheable?` still excludes recording and subset runs,
for reasons that do not reach this slot: a recording run must analyse to
record the graph, and a subset run's partial answer would share the full
run's key. The session writes after recording, the merged and complete
answer, under its own producer id. A hit neither reads nor writes the
snapshot: it stands in for a null recheck, which already leaves the
snapshot as it was (ADR-87 WD3), so the next edit run restores what it
would have restored.

**Bounds.** A hit answers what the full incremental path answered for a
tree identical in every recorded input, so where that path is stale a hit
is too, never more. Two such gaps sit outside this WD. The session does
not re-analyse a served file whose analysis read a file a plugin read: the
chain's rows make the probe decline, and the full path then serves the
stale rows. And the snapshot fingerprint digests a configured
`signature_paths:` only, so an edit under an auto-detected `sig/` is
rechecked rather than rebuilt. #1541's pool-mode row loss is unreachable
here, since a pool run neither writes nor serves the slot.

Measured locally on Mastodon (1,404 files, macOS, engines laid out as
installed gems by `tool/engine_warm_ab.rb`): an `--incremental` null run
0.94 s → 0.18 s, level with the default null run's 0.17 s for the same
engine; writing the slot costs about 10 ms per run, cold or edit. CI
numbers are for the `engine-warm.yml` dispatch to confirm.

Gate: `spec/rigor/analysis/incremental_run_slot_spec.rb` (each input class,
the carried row, the chain breaks, the separation of the two slots), the
subprocess examples in `spec/rigor/cli/run_cache_probe_spec.rb` (no
`rigor/inference` on a hit), `spec/rigor/cli/check_command_spec.rb` (the
same output per format, baseline and `--fail-on`), and
`tool/engine_warm_ab.rb`, which counts `--incremental` null probe hits and
fails an edit run that did not load the engine.

## Consequences

- **Soundness is the whole game.** The naive design under-invalidates on
  analysis-time plugin reads; the record-and-validate design closes that
  by deriving the dependency set from what the run actually read, not from
  a guess made before it. The pundit regression test is the acceptance
  gate for the implementation.
- **The no-change floor is the pre-passes, not zero.** Even the sound
  cache still runs `run_project_pre_passes` (parse every analyzed file for
  the discovered-symbol indexes + plugin `prepare`) before it can validate
  and serve. A later slice can cache the pre-pass artefacts keyed on the
  same file-digest set to approach near-instant; deferred.
- **Per-file granularity stays out of scope.** Because A's diagnostics
  depend on B's *body* (item 2), a per-file cache that survives single-
  file edits needs a cross-file dependency graph Rigor does not build;
  the whole-run entry is the right first granularity.

## Rejected alternatives (summary)

- **Pre-analysis whole-run fingerprint** — unsound for analysis-time
  plugin reads (Pundit); proven by the existing regression test.
- **Fingerprint from the analyzed set only** — also misses plugin-read
  files outside `paths:`; subsumed by the above.
- **Hand-picked config-field fingerprint** — fragile; digest the whole
  `Configuration#to_h`.
- **Per-file cache for single-file edits** — needs a cross-file
  dependency graph; deferred.
