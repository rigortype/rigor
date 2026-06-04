# ADR-46 — Incremental analysis via a cross-file dependency graph

Status: **Proposed — design. The whole-run cache ([ADR-45](45-unchanged-project-fast-path.md)) is coarse (any analyzed-file change → full re-run); this ADR designs the per-file incremental successor: edit a leaf controller → re-check that one file; edit a model → re-check the model plus the files that actually depend on it.**

ADR-45 made an *unchanged* project fast (record-and-validate whole-run
cache, ~42× on GitLab). It is deliberately coarse: a single changed file
invalidates the whole entry, so editing one file costs a full re-scan
(~113 s on GitLab). The intuition behind this ADR is exactly the user's:
in an MVC app a concrete `PostsController` is a **leaf** of the dependency
graph — nothing infers through its actions — so editing it should
re-check only that file; editing a `Post` model should re-check the model
and the handful of services/controllers that call its methods, not all
2,630 files.

This design records, per analyzed file, *what it actually read from other
files*, inverts that into a dependents index, and on an edit re-analyzes
only the affected closure — serving every other file's diagnostics from
cache. Soundness (never serve a stale diagnostic) is the whole problem.

Grounding: [ADR-45](45-unchanged-project-fast-path.md) (the whole-run
cache + the "plugins read files during analysis" hazard) and
[ADR-24](24-self-method-call-resolution.md) (cross-file self-call
resolution).

## What a file's diagnostics actually depend on

A's diagnostics are a pure function of A's AST **plus** every cross-file
fact A's analysis consumed. Enumerated against the engine, the cross-file
fact kinds are:

1. **Class / method / constant declarations.** A resolves `Post`, or
   `Post#publish`, or `Admin::Report` against the project-wide
   `discovered_classes` / `discovered_def_nodes` / `discovered_superclasses`
   / `discovered_includes` indexes (seeded into every file's `Scope` by
   `seed_project_scope`). The 66 cross-file reads in the engine funnel
   through a small set of `Scope` accessors — `user_def_for`,
   `user_def_site_for`, `superclass_of`, `includes_of`,
   `top_level_def_for`, and the discovered-class lookups — which is the
   **choke point** this design instruments.
2. **Inferred return bodies (the deep edge).** `infer_user_method_return`
   resolves `Post#publish`'s `DefNode` and **evaluates its body** to infer
   the call's return type. So A depends not just on `Post#publish`'s
   existence but on its **body**: a body edit that changes the inferred
   return type changes A's diagnostics.
3. **Class-state inference.** Project-wide `class_ivars` / `class_cvars` /
   `program_globals` / `in_source_constants` carry types assigned in one
   file and read in another.
4. **Plugin contributions.** A plugin may read a project file
   mid-analysis (the `rigor-pundit` policy) and contribute a diagnostic or
   a return type. Already captured as file digests via each plugin's
   `io_boundary.cache_descriptor` (ADR-45).
5. **Global inputs.** The RBS environment (gems + `sig/`), the resolved
   configuration, and `Rigor::VERSION` — the ADR-45 fingerprint.

Source attribution already exists for the load-bearing kind:
`discovered_def_sources` maps `(class, method) → "path:line"`, so a
method-declaration or inferred-return dependency is attributable to a
file today. Class / superclass / include attribution is not recorded yet
but is cheap to add — the pre-pass holds the `path` while it merges each
file (`merge_discovered_defs` already does this for methods).

## Design

### 1. Record per-file dependencies at the accessor choke point

Thread a lightweight **dependency recorder** through `analyze_file(A)`.
Every time A's analysis resolves a cross-file symbol through a `Scope`
accessor, the recorder notes the **source file** of the resolved entry
(via `discovered_def_sources` and the to-be-added class/superclass/include
source maps). It also records **negative** lookups — symbols A queried
and did *not* resolve — because adding that symbol later must re-check A
(see §4).

The result is `deps[A] = { files A read declarations or bodies from }`
plus A's own digest, plus the global fingerprint. The plugin file reads
(kind 4) fold in from the io_boundary descriptors.

### 2. Invert into a dependents index

`dependents[X] = { A : X ∈ deps[A] }`. Persisted alongside the per-file
diagnostic cache. This is the reverse edge the incremental step walks.

### 3. Per-file diagnostic cache

Cache **each file's** diagnostics (not the whole run) keyed on
`(A.digest, {dep.digest for dep in deps[A]}, global fingerprint)` — the
ADR-45 record-and-validate machinery (`fetch_or_validate` +
`Descriptor#fresh?`) applied per file. A is a cache hit iff A and every
file it depended on are unchanged.

### 4. The incremental step: declaration-structure tier + body tier

On a run, diff the project against the last run's recorded file digests to
get the changed set ΔF. Then:

- **Declaration-structure fingerprint.** Digest the project's *declaration
  shape* — every class / module / def / constant *name* + its source
  file + each class's superclass/include names — but **not** method
  bodies. A body edit does not change it; adding / removing / renaming /
  moving a class/method/const does.
  - **Fingerprint unchanged (the common dev edit — a method body):** no
    symbol was created or destroyed, so negative dependencies are stable.
    Re-analyze exactly `ΔF ∪ ⋃_{X∈ΔF} dependents[X]` (the changed files and
    their transitive dependents); serve all other files from the per-file
    cache.
  - **Fingerprint changed (structural edit):** a symbol appeared /
    vanished / moved. Conservatively widen: re-analyze ΔF ∪ their
    dependents ∪ every file with a **negative** dependency on a name in
    the declaration delta (a file that looked up `Post#publish`, found
    nothing, and now would). A first cut may fall all the way back to a
    full re-analysis on any structural change; the negative-dependency
    refinement is a later slice.

### Worked examples

- **Edit `PostsController#create` body.** Declaration fingerprint
  unchanged. `dependents[posts_controller]` is empty (no file infers
  through a controller action; routes reference it by *string* name via
  the rails-routes plugin, which reads `routes.rb`, not the controller's
  return types). Re-analyze **1 file**. ✔ the "leaf" intuition.
- **Edit `Post#publish` body** (Post used by 12 services/controllers).
  Declaration fingerprint unchanged. Re-analyze `Post` +
  `dependents[post]` = **~13 files**, not 2,630. ✔ the "related files
  only" intuition.
- **Edit `ApplicationController`** (base of every controller). Its
  subclasses depend on it (inherited defs / inferred returns), so
  `dependents` is the controller tree — re-checked, correctly.
- **Add a method `Post#archive`.** Declaration fingerprint changes → the
  structural tier: re-analyze `Post` + its dependents + files that
  negatively looked up `archive`.

## Soundness — the hard part

The single failure mode that matters: **under-recording a dependency**
serves a stale diagnostic, which on a type checker is a manufactured
false positive/negative — the top-tier discipline this project will not
trade for speed. Defenses:

- **One choke point, audited.** Cross-file reads go through the handful of
  `Scope` accessors; instrumenting *those* (not 66 call sites) captures
  the declaration/body/state edges by construction. The accessor set is
  small enough to audit for completeness and guard with a test that fails
  if a new cross-file accessor is added without recording.
- **Conservative fallback over precision.** Any uncertainty widens the
  re-analysis set; it never narrows it. A structural change, a plugin that
  cannot describe its reads, a cache-schema bump, or a config/RBS/version
  change → full re-analysis. Over-analysis is slow but sound;
  under-analysis is unsound.
- **`--verify-incremental` cross-check.** A mode (and a CI job) that runs
  the incremental analysis and a full `--no-cache` analysis and asserts
  byte-identical diagnostics. This is how incremental compilers earn
  trust; it converts a latent soundness bug into a loud test failure
  rather than a silent stale result. It is the acceptance gate for every
  slice.
- **The ADR-45 invariants carry over.** Validate by re-digesting recorded
  files; the verification gate runs `--no-cache`; a cache error never
  breaks a run.

## Staging

1. **Attribution + recording.** Add class/superclass/include source maps;
   thread the dependency recorder through the `Scope` accessors; persist
   `deps` / `dependents` and per-file diagnostic entries. Land behind a
   default-off flag with `--verify-incremental` green on Mastodon + GitLab.
   - **Slice 1a landed** — `Analysis::DependencyRecorder` (thread-local
     accumulator + a module-level activation count so the disabled fast
     path is a plain integer read, since the instrumented accessor is on
     the per-dispatch hot path) records, per file, the source files its
     analysis read methods/bodies from plus the unresolved (negative)
     cross-class method lookups. `Scope#user_def_for` — the method
     resolution / `infer_user_method_return` choke point — is instrumented
     and attributes via the existing `discovered_def_sources`. Opt-in via
     `Runner.new(record_dependencies: true)`, exposed as
     `runner.file_dependencies`; off by default (diagnostics byte-identical,
     `make verify` green).
   - **Slice 1b landed** — the ancestry edge. A per-file `class_sources`
     map (`class_name → Set<declaring file>`, built in
     `accumulate_project_index` from every file that contributes a `def` /
     superclass / `include` / bare declaration for a name) is seeded onto
     the recording scope, and `Scope#superclass_of` / `#includes_of` record
     the full declaring-file set when they resolve an ancestry edge — so a
     class reopened across files makes a consumer that reads its ancestry
     depend on *every* reopening (over-records by design, the conservative
     direction). Fixing this surfaced a latent slice-1a gap: the ADR-44
     single-allocation body scopes
     (`ExpressionTyper#build_user_method_body_scope`,
     `StatementEvaluator#build_fresh_body_scope`) dropped
     `discovered_def_sources`, so the method-body edge (`user_def_for` →
     `def_sources`) was silently *not* recorded for implicit-self
     ancestor-resolved calls (slice 1a's spec only covered explicit
     receivers). Both body scopes now carry `def_sources` + the new
     `class_sources`; off by default, `make verify` green, diagnostics
     byte-identical.
   - **Slice 1c landed** — the §2 inversion. `Runner#file_dependents`
     builds `dependents[X] = { A : A read a declaration / body from X }`
     on demand from the recorded `sources` sets (frozen, default-proc
     dropped so a missing-key read returns nil rather than re-entering the
     builder on the frozen hash). This is the reverse edge slice 2 walks to
     re-analyse `{X} ∪ dependents[X]` on an edit. The negative (`missing`)
     edges are deliberately *not* inverted here — they feed the structural
     tier (slice 3). The positive **class-existence** lookup edge
     (resolving a bare constant to a project class) is also deliberately
     left un-instrumented: a class appearing / disappearing / moving is a
     *structural* change caught by the declaration fingerprint tier (§4),
     and a file that merely references `Post` depends on `Post`'s
     *methods* (already recorded via `user_def_for`), not on the bare
     class existence — so the class-lookup edge is redundant for the body
     tier and its diffuse read sites (`discovered_classes` is read
     directly, not through one accessor) are not worth a choke-point
     refactor here.
   - **Remaining in this slice:** persistence (`deps` / `dependents` +
     per-file diagnostic entries, reusing ADR-45's
     `Cache::Store#fetch_or_validate`) and the mandatory
     `--verify-incremental` cross-check.
2. **Body tier.** Wire the declaration-fingerprint-unchanged path
   (re-analyze ΔF ∪ dependents). This already delivers the MVC win.
   - **Soundness core landed** — `Analysis::Incremental` carries the
     side-effect-free set algebra: `affected(changed, dependents)` (the
     closure the body tier re-analyses = changed ∪ their dependents) and
     `changed_files(before, after)` (structural per-file diagnostic diff
     via `Diagnostic#to_h`). The spec drives real runs to assert the
     soundness *property* end-to-end: a leaf body edit whose declaration
     fingerprint is unchanged confines every diagnostic change to
     `affected`, and leaves an unrelated file's cached diagnostics
     untouched (the leaf-edit win). Runner-independent, so the invariant
     is unit-testable without the cache/subset machinery.
   - **Empirical finding (informs the tier).** Rigor's false-positive
     discipline makes inferred cross-file return types nearly never drive
     a *dependent's* diagnostic: `String#+ Integer`, `Integer#upcase` on an
     inferred receiver, and `if <inferred-bool>` all stay silent across a
     file boundary. So in practice `changed ≈ ΔF` for a body edit — the
     dependents re-analysis is conservative *insurance* (re-check to stay
     sound), not a frequent source of new diagnostics. This is what makes
     the leaf-controller → 1-file win the common case.
   - **Subset-analysis hook landed** — `Runner.new(analyze_only:)` takes a
     collection of paths; the whole-project pre-pass still runs over every
     file (the cross-file index stays complete), but `target_files` filters
     the analyzed set to the supplied paths. A subset run's diagnostics for
     a given file are byte-identical to the full run's for that file (spec
     `runner_subset_analysis_spec.rb`), so the body tier can re-analyze the
     affected closure and trust the result matches a full analysis. Pool
     mode inherits the filter for free (it dispatches `target_files`).
   - **Remaining in this slice:** per-file diagnostic cache serving for the
     non-affected rest (reuse ADR-45's `Cache::Store#fetch_or_validate`) +
     the `--verify-incremental` CLI flag that runs incremental vs full
     `--no-cache` and asserts byte-identical on Mastodon + GitLab (the
     acceptance gate). The set-algebra core, the property test, and the
     subset hook are the pieces those compose.
3. **Structural tier.** Negative-dependency tracking so adding a symbol
   re-checks only its would-be resolvers instead of falling back to full.
4. **Symbol granularity (optional).** Refine file-level deps to
   `(file, symbol)` so editing one model method re-checks only callers of
   *that* method, not every caller of the model.

## Rejected / deferred alternatives

- **Whole-run cache only (ADR-45).** The coarse predecessor; this ADR is
  its refinement, not a replacement — ADR-45 still wins the no-change case
  in one lookup.
- **Pure timestamp/mtime invalidation.** Unsound across the cross-file
  edges (a body edit with an unchanged mtime, or a dependent untouched on
  disk) and ignores the inferred-return dependency.
- **Salsa-style fact-level memoisation** (record every individual fact's
  value, re-validate per fact). The precise ideal, but it threads a query
  layer through the *entire* engine (all 66 read points + the dispatcher
  tiers) — a far larger rewrite. File-level deps at the accessor choke
  point get most of the win for a fraction of the surface; symbol
  granularity (stage 4) is the incremental step toward it.
- **Re-analyze the whole reverse-reachable set on every edit, no
  declaration tier.** Sound but needlessly re-checks dependents on a body
  edit that did not change the method's inferred return; the declaration
  tier plus (later) return-type summaries prune that.

## Risks

- **Completeness of recording is a correctness invariant, not a
  performance knob.** The `--verify-incremental` gate is mandatory, not
  optional.
- **Inferred-return volatility.** A body edit that changes a method's
  inferred return ripples to all callers; deep call graphs can make the
  "affected closure" large. Return-type **summaries** (re-check a
  dependent only if the dependency's inferred summary changed) bound this
  but are their own slice.
- **Persistence cost.** `deps` / `dependents` / per-file entries grow with
  the project; they share ADR-6's no-eviction backend and need a size
  story (the per-file entries are keyed by stable path, so they overwrite
  rather than accumulate, like ADR-45's slot).
