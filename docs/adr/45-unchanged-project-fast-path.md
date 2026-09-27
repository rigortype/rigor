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
`--explain` false), plus the analysis roots, under its own producer id,
`analysis.incremental-run-diagnostics`. The roots are not implied by the
files: `--incremental lib extra` with `extra` missing analyses what
`--incremental lib` analyses, and only the first reports `extra` missing
(the plain key has the same gap, #1559). The key holds them normalised to
absolute paths and sorted (`lib`, `./lib` and `lib/` are one root there),
so a run that reorders them still finds the previous slot's chain, as the
snapshot fingerprint, which sorts them too, still restores, and a respelled
run replaces the slot rather than adding one beside it. The entry keeps them as the run was given them, and is served only to a
run that names them the same way in the same order: a missing root is
reported as written (`./extra` is not `extra`), and `--incremental a b`
lists `a`'s files first where `b a` lists `b`'s. The producer id and the
roots entry each keep the two slots apart on their own, so neither probe
can read the other's entry.

Neither slot WD4's key leaves out is needed. A synthesised RBS buffer is a
function of an analysed file's bytes (a validated row) and of the
synthesising plugin's identity and configuration (the key's
`configuration`, lockfile and engine slots). A template unit (#392) is a
function of its template's bytes and whatever else its transform read, of
the transform, and of the synthesis version: the template files and one
listing row per claimed glob are rows, a transform's other reads go
through its plugin's boundary, and the plugin and the engine are in the
key. So a project whose plugins claim template globs, as rigor-actionpack
does on any Rails application, is served; the plain probe misses on it,
because the plain key carries the compiled units' digest.

**Descriptor.** A narrowed recheck read only its closure; the rest of its
answer was computed by earlier runs. The rows come from three sources:

1. One `:stat` row per analysed file, packed from the digest the session
   holds for it — for a file served from cache, the bytes its cached rows
   were computed from — and re-packed against the current stat when the
   bytes still match but the tuple moved (a `touch`, a checkout), so a
   later probe stats rather than re-hashes it. The re-pack hashes the file
   afresh, never from the per-run memo, whose digest describes the bytes
   change detection read, and only when the tuple it packs after that hash
   is the one taken before it. A re-digest after the run would vouch for
   bytes that changed while the run was reading them.
2. What every run reads again and re-derives its answer from
   (`Runner#incremental_slot_rows`), in two kinds. Taken as the run read:
   every plugin `IoBoundary` row, among them each producer's `watch:`
   globs, which #1558 replays into the boundary whether the producer
   computed or was served. Taken when the run ends: the template files and
   globs (re-analysed every run), and an existence row per analysis root
   and per `pre_eval:` entry. The plain slot records no existence rows, but
   the incremental path regenerates its path-error rows every run, so a
   slot that served one past the edit that retracts it would print what no
   run of the tree prints. They carry WD1b's bound.
3. The **chain** the slot's value carries forward. Its baseline part is
   what a full run records for inputs a recheck does NOT re-derive
   (`Runner#baseline_dependency_rows`): the signature tree
   (`RbsDescriptor.file_entries` / `.glob_entries`) and an existence row per
   signature root, configured or the auto-detected `sig`; the
   discovered-not-analysed files (#684) and a listing row per discovery
   root; and the `pre_eval:` files outside the analysed set. Its reads part
   is the plugin reads credited to each analysed file:
   `Runner#analyze_file` wraps each file's analysis in
   `Plugin::IoBoundary.attributing` when it records dependencies. A full run
   starts a chain; a recheck carries the baseline part unchanged, replaces
   the reads of every file it re-analysed with this run's, and drops the
   removed files'.

Carrying the baseline part rather than recomputing it is deliberate. A
recheck neither rebuilds its environment on an empty closure nor widens
discovery, the snapshot fingerprint digests only a configured
`signature_paths:` (#1554), and the session tracks only analysed files
(#1560), so a change to one of those inputs leaves the full path serving
rows computed before it. Recomputed, the next slot would vouch for that
stale answer; carried, the probe declines until the next full run.

Reads are credited to the file whose analysis made them, and only a read
the boundary records is credited at all. A value a plugin memoised — in an
ivar, through `producer_value`, or carried across files by the ADR-84
return memo — reaches later files without a read of their own, so only the
first file to trigger the read guards it. A producer answered from its
own record-and-validate entry reads nothing, but since #1558 it replays the
rows its entry recorded into its boundary, and `IoBoundary#replay` hands
each of them to the sink as a live read would, the ones a held row wins
over included. A producer first asked while a file is analysed
(rigor-actionpack's `:controller_index`, rigor-rails-i18n's
`:locale_index`) then credits that file with its inputs; without the
credit, the rows it replays during the per-file loop would make
`Runner#incremental_slot_rows` decline and no slot would ever be written
for such a project. On a miss the replayed descriptor is the whole
boundary's, so the file is credited with more than the producer read,
which only makes the slot decline sooner.

**Written only for the tree the run read.** Part of the slot is read off
the tree when the run ENDS: the analysed-file rows (a full run digests its
files after analysing them), the rows item 2 takes at the end, and a full
run's baseline rows. A save that lands while the run reads — an editor's, a
`bundle install`'s, a `mkdir` — would leave those vouching for a tree the
analysis never saw: a signature file saved after the environment was
built, a served file replaced with its mtime kept, an analysis root created
after the run reported it missing. A recheck's carried baseline has the
same exposure in another form: a recheck with a non-empty closure reads
the signature tree again, and a save it read that is reverted before the
run ends leaves every carried row fresh. So the session takes a mark before
the run reads anything (`IncrementalRunSlot::WriteGuard`) and writes
nothing unless, at write time, none of those rows, carried or taken, moved
after it: no file a content row names, no directory a glob row lists, and
no file a stat-mode glob matches. An existence row asks only whether its
path is there, so the mark records whether each path such a row can name
(the analysis roots, the `pre_eval:` entries, the signature roots) is
present, and the row moved if its path came or went since. Its
directory's change time is not asked: an editor's lock file created and
removed beside the path moves it, and a recheck refused for that leaves
the chain broken until the next full run. A path that comes and goes again
within the run is the bound. An existence row for a path the mark did not
record falls back to its own change time, or its nearest existing
ancestor's. A row taken as a plugin read needs no guard, since a later
save leaves it stale.

The key needs the same care: it is computed when the run ends, and its
only file inputs are the lockfiles. So the guard also watches every
lockfile the key or the snapshot fingerprint may read: one present at the
mark must still be there with its change time before it, which refuses a
lockfile rewritten, removed, or rewritten and restored (which a digest
would not tell apart from the bytes the run began with), and one absent at
the mark must still be absent. The caller computes the snapshot
fingerprint before the run starts, and a lockfile or configured signature
file changed in between would leave the snapshot the run restores keyed by
one tree while the run reads another, so the mark also recomputes the
fingerprint and takes no mark when it moved.

The mark is the change time of a file written for the purpose, so it is
read off the filesystem's own clock. A change time, unlike a modification
time, cannot be set back by `cp -p` or `touch -d`, and on the mark's own
filesystem a coarse tick cannot hide an edit: a change in the mark's tick
counts as after it. One clock needs one filesystem, so the mark is taken
only when the store is on the project's. A row on another filesystem is
decided by what identifies it. The signature files outside the project's
own signature roots are identified by the key already: the engine's own
(`data/`, a bundled plugin's `sig/`, a gem overlay) by the engine slot, a
gem's `sig/` and an `rbs collection` directory by the lockfiles. They live
wherever the engine and the gems are installed, a container image's layer
or a Nix store, so on another filesystem the guard passes over them, and on
the mark's it checks them like any other row
(`Runner::BaselineRows#pinned`). Every other row on another filesystem
refuses the write. For a checkout, the engine slot pins only the engine's
Ruby source, so a contributor's edit to a bundled signature file while a
run reads is outside the guard when the checkout is on another filesystem
from the project. What the guard cannot see is its clock stepping
backwards during a run (an NTP correction, a network filesystem's server),
which could date a save before the mark.

**Why the chain holds together.** By induction from the full run that
started it: that run's descriptor is the plain slot's, and each recheck's
carries this run's reads for the files it re-analysed and the previous
slot's for the files it served. That holds only if the previous slot
describes the snapshot the recheck restored. It does not when the slot is
missing (evicted, deleted, never written), or when another run rewrote the
snapshot without writing a slot: a pool run, whose workers' reads never
reach the process that would record them; `--incremental --no-cache`,
which has no store; a slot write that failed. So the slot records the
identity of the snapshot file its run left behind — `(size, mtime_ns,
ctime_ns, inode)`; a save renames a new file into place — and a recheck
carries the chain only from a previous slot that exists and names the
snapshot file it restored. Otherwise it writes nothing, and the fast path
stays off until the next full run starts a fresh chain: after a pool or
`--no-cache` edit run, a save the write guard caught, a cache restored
onto a new checkout (new inodes), a lockfile change the snapshot
fingerprint does not see (#1532), or two runs racing.
`Runner#incremental_slot_rows` also declines when a boundary row changed
during the per-file loop without being credited to a file (a read from a
thread the plugin started).

"Until the next full run" can mean indefinitely: the full `--incremental`
path starts one only when its fingerprint moves (the configuration, the
lockfiles, a configured `signature_paths:`, the engine) or its snapshot is
gone, and never because the probe stopped serving. The same holds after a
chained input changed (below). A cheap follow-up would be for the session
to run a baseline itself when the previous slot's chain no longer
validates in its baseline part, or when no chain could be carried; it is
not built here.

**What is neither written nor served.** No slot is written for an editor
buffer (never persisted), a pool run, effect collection (its `effects:`
block is outside the key, and its envelope rows are #428's decline), an
opaque plugin, whose next full-path run is cold rather than the warm run
the probe stands in for, or a run after which the session holds no digest
for some analysed file: #1536's source-RBS gate forgets the digest of a
file saved after the closure was decided, and no row could then say what
its readers were computed from. The slot does not depend on that gate's
closure decision otherwise, so a run under an untrusted gate is written. The CLI asks the probe only for a plain
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

**What a hit guarantees.** A hit prints exactly what the run that wrote
the slot printed, and only while every recorded row validates. The rows
cover every input the full incremental path's own change detection sees —
the analysed files, the configuration, roots and lockfiles in the key, the
signature tree, and each plugin read the boundary records, which is where
the ADR-88 fact surface comes from — so where the full path would notice a
change and re-analyse, the probe declines first. That rests on ADR-45's own
premise, that a plugin reads through its `IoBoundary`, and on #1558's
replay of a producer's rows on a hit; before it, a producer input could
change with the probe serving the pre-change answer while the full path
recomputed the producer and rebuilt. WD2 landed after #1558 for that
reason.

A hit is not guaranteed to equal a cold run. Where the full path misses a
change, one of two things happens. For an input the chain carries (#1554's
auto-detected `sig/`, #1560's discovered files, a `pre_eval:` file outside
the analysed set), the probe declines until the next full run while the
full path serves its stale answer. For a plugin read credited to another
file, or reaching a file through a memo (#1553), the probe serves the same
stale answer the full path serves — parity, no more.

Measured locally on Mastodon (macOS, engines laid out as installed gems
by `tool/engine_warm_ab.rb`). With the sweep configuration
(`data/oss-sweep/mastodon-rigor.yml`, 1,404 files, no plugin claiming
templates), an `--incremental` null run went from 0.94 s to 0.18 s, level
with the default null run's 0.17 s. With the survey configuration (1,328
files; rigor-actionpack, which claims `app/views/**/*.erb`, and nine other
Rails plugins) it went from 2.49 s to 0.28 s, every null run served, where
a default null run takes 1.1 s because the plain key's `template-units`
slot keeps WD4's probe from answering. That configuration's edit runs are
cold on both engines, for #1574. Writing the slot costs 17–20 ms per run
with the sweep configuration and 48–62 ms with the survey one, where the
guard takes 11–13 ms and the rest builds and writes a 0.5 MB entry of
6,348 file rows. CI numbers are for the `engine-warm.yml` dispatch to
confirm.

Gate: `spec/rigor/analysis/incremental_run_slot_spec.rb` (each input class,
the roots and their spelling, the carried read, the inputs that decline
until a full run, the chain breaks, the separation of the two slots, a
producer's input through a cache hit, a producer first asked from a node
rule, template units, and the write guard: a save, a root created or
removed, a nested signature file removed and a configured lockfile
rewritten while the run reads, and a row on another filesystem), the
subprocess examples in `spec/rigor/cli/run_cache_probe_spec.rb`
(no `rigor/inference` on a hit), `spec/rigor/cli/check_command_spec.rb` (the
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
