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
