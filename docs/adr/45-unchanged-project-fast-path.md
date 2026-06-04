# ADR-45 — Unchanged-project fast path (run-result cache)

Status: **Proposed — design + soundness analysis; the naive pre-analysis fingerprint is rejected (proven unsound by an existing regression test), and the sound record-and-validate implementation is staged, not landed.**

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
   the pre-passes, mid-`analyze_files`.
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

### Accepted design (staged) — record-and-validate dependencies

The sound model inverts the order: **run, recording every input actually
read; cache the result alongside that dependency set; on the next run,
validate the recorded dependencies by re-reading them.**

- **Key:** stable, known before the run — the analyzed-path *set* +
  config digest + gems + `Rigor::VERSION`. (Adding/removing a file changes
  the path set → new key; editing a file keeps the key and is caught by
  validation.)
- **Stored value:** `{ diagnostics, file_deps: {path => digest} }` where
  `file_deps` is collected **after** the run — analyzed files + every
  plugin's `io_boundary.cache_descriptor` (now complete, including
  analysis-time reads like the Pundit policy) + the RBS `sig` files.
- **Lookup:** read the entry at the stable key; re-digest each
  `file_deps` path; **hit** only if all match (else miss → re-run →
  rewrite). This is the standard build-system "validate recorded inputs"
  model, and it captures the Pundit policy because the policy is in
  `file_deps` after the first run.

This needs a cache primitive the store does not have today —
`fetch_or_compute` derives its key *from* the descriptor, so it cannot
express "stable key, validate a recorded dependency set." A small
`Cache::Store` addition (read raw value + stored dependency descriptor at
a key; validate; recompute on mismatch) is the unit of work, plus the
post-run dependency collection in the runner. Staged behind this ADR.

### Required companion — make the verification gate cache-proof

The result cache must never let the project's own gate read a stale
result: `make check` / `check-plugins` run `rigor check lib` with no
`--no-cache`, and the fingerprint deliberately excludes engine code (only
`Rigor::VERSION`), so an engine edit that leaves the version unchanged
could be masked by a hit. When the cache lands, those targets MUST switch
to `--no-cache` (the gate always re-runs the analysis). Until then the
cache is not wired, so the gate is unaffected.

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
