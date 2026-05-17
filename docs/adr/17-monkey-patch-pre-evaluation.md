# ADR-17 — Project-side monkey-patch pre-evaluation

Status: **proposed, 2026-05-16.** Design fixed here so v0.1.x core
work can refer to it; implementation queued (no committed
milestone). Targets the "explicit list MVP" floor first; pattern
discovery and full-project pre-pass remain demand-driven.

## Context

Real-world Ruby projects routinely reopen core / stdlib classes to
add project-private helper methods. The dominant idiom is a
`lib/core_ext/` or `app/lib/ext/` directory containing one file per
patched class:

```ruby
# lib/core_ext/string_extensions.rb
class String
  def to_url
    self.gsub(/[^a-z0-9]+/i, "-")
  end
end
```

Other files in the project then call `s.to_url` on regular Strings
and expect static analysis to treat the call as defined. Rigor
today cannot satisfy that expectation without help:

- **File order does not save us.** Per-file inference today walks
  files independently. The walker that finds `def to_url` inside
  `String` runs the same as any other class-body discovery — but
  the **fact** that `String` now has `#to_url` does not propagate
  outward into a project-wide "patched-method registry" that
  *other* files consult when their inference engine asks "does
  `s.to_url` resolve?".
- **RBS bundles cannot cover project-private patches.** The
  v0.1.5 `examples/rigor-activesupport-core-ext/` bundle covers
  the *common* ActiveSupport `core_ext` selectors. Project-private
  patches are by definition outside any bundleable RBS.
- **Plugin authoring is too heavy.** A user could author a
  one-off plugin that emits the discovered methods through ADR-9
  `flow_contribution_for`, but the activation surface (a whole
  gem-shaped plugin for a single project's `lib/ext/`) is
  disproportionate to the problem.

The Redmine real-world test surfaced this as the missing half of
the "close the Rails `call.undefined-method` long tail"
workstream. The other half (the RBS bundle) landed as O1 in
v0.1.5; this ADR carves out the project-side half.

## Decision

Add a new `pre_eval:` configuration axis to `.rigor.yml` that
names **explicit files** Rigor MUST analyse before per-file
inference begins. The discovered method definitions in those files
populate a project-wide patched-method registry consulted by
every subsequent per-file analysis:

```yaml
# .rigor.yml
paths:
  - app
  - lib

pre_eval:
  - lib/core_ext/string_extensions.rb
  - lib/core_ext/hash_extensions.rb
  - lib/redmine/setting_helpers.rb
```

The MVP shape is **explicit list only**. Pattern-based
auto-discovery and full-project pre-pass remain demand-driven
follow-ups (see "Implementation slicing" below).

### Inference contract

When Rigor's analyzer starts:

1. **Pre-pass.** Each path under `pre_eval:` is parsed with Prism
   and walked exactly like a normal source file, but with **only
   the discovery facets active**: `Inference::ScopeIndexer` runs
   to extract `def` / `define_method` / `attr_*` /
   `Data.define` / `Struct.new` declarations, plus the
   `class Foo; end` / `module Foo; end` shells. The inference
   engine itself does NOT run on the pre-eval files (no
   per-call-site dispatch, no narrowing, no diagnostics).
2. **Project-wide registry.** The discovered method declarations
   merge into a new `Inference::ProjectPatchedMethods` table
   keyed by `(class_name, method_name, kind)` carrying the
   declared (or `untyped`) return type and the source path /
   line of the definition.
3. **Per-file dispatch tier.** `MethodDispatcher` gains a new
   tier consulted **between** plugin contributions and
   dependency-source inference (so plugins still win, but
   project-side patches win over gem-source walks):

   ```
   core RBS > RBS::Extended > plugins > ProjectPatchedMethods
     > dependency-source inference > engine fallback
   ```

4. **Diagnostic provenance.** Methods resolved through the
   patched-method registry retain a `Diagnostic#source_family`
   of `:project_patched` (new) so end-users can audit which
   call sites are riding the pre-evaluation surface.

The contract is conservative: a method MUST appear with a `def`
keyword (or one of the recognised metaprogramming forms above) for
the registry to record it. Dynamic patches like
`String.define_method(:to_url) { … }` are out of scope for the
MVP.

### Hard exclusions

The pre-eval pass MUST NOT:

- **Execute** any project Ruby code. The pre-pass is a parse +
  walk only; the same `Plugin::Base` § "Plugins must not execute
  application code" rule that ADR-2 codifies applies verbatim.
- **Cross project boundary.** Files outside the project root
  (resolved per ADR-2's IO boundary) are rejected at config-load
  time with a clear `configuration-error` diagnostic.
- **Patch unconditionally-monkey-patchable receivers in
  `:dependency_source`-walked gem code.** Gems opted into
  source-inference ([ADR-10](10-dependency-source-inference.md))
  keep their own dispatch tier; project patches do NOT inject
  into gem source's view of its own classes. This is a
  one-way push: project-side analysis sees the patch, gem
  source-inference does not.

### Cache invalidation

Pre-eval results are cached using ADR-6's persistence backend
with a new `Cache::Descriptor::PreEvalEntry`:

- Cache key includes `(path, content_digest)` per pre-eval file.
- A change to a pre-eval file invalidates exactly that file's
  slice of the patched-method registry; other slices survive.
- A change to `pre_eval:` itself (adding or removing a path)
  invalidates the union of newly-listed and previously-listed
  files plus every file that consulted the patched-method
  registry during analysis. The descriptor tracks this via the
  existing `ConfigEntry` machinery.

### Failure modes

Pre-eval is **fail-soft by default**:

- **Parse error in a pre-eval file** → emit a `:warning`
  `pre-eval.parse-error` diagnostic; pre-eval continues with
  the remaining files; the project's per-file analysis proceeds
  as if that file's patches did not exist.
- **Missing pre-eval file** → `:error` `pre-eval.file-not-found`
  diagnostic at config-load time (ahead of analysis).
  Configuration mismatches should be loud.
- **Cycle in pre-eval discovery** (a pre-eval file `require`s
  another that's also in `pre_eval:`) → no special handling; the
  walker doesn't follow `require` so cycles are inert.
- **Pre-eval file declares the same `(class_name, method_name,
  kind)` as another pre-eval file** → last-listed wins; emit a
  `:info` `pre-eval.duplicate-declaration` diagnostic naming
  both source locations. Users can suppress via the standard
  `# rigor:disable` machinery.

### Boundary with ADR-16 Tier D

[ADR-16](16-macro-expansion.md) Tier D (external-Ruby-file
inclusion under declared `self`) and this ADR solve related but
distinct problems:

- **Tier D** wires *plugin*-declared external files into a
  *receiver class's body* (Redmine webhook payloads, tDiary
  plugin loader) with `self_type` narrowing and pre-bound
  ivars. The plugin author owns the manifest; the user has
  no direct knob.
- **ADR-17** wires *user-declared* external files into the
  *project-wide patched-method registry* with no `self_type`
  narrowing (the patched class IS the class being declared,
  no narrowing needed). The user owns `pre_eval:`; no plugin
  is involved.

The two systems coexist; a project that uses both reads through
the dispatcher tiers in the order above. Per-(class_name, method)
collisions between a Tier D synthetic emission and an ADR-17
pre-eval registry entry follow registration order (first
contributor wins per ADR-16 WD11).

## Public-API drift surface

This ADR adds:

- `Rigor::Configuration#pre_eval` (new attr_reader; frozen
  `Array<String>` of absolute paths).
- `Rigor::Inference::ProjectPatchedMethods` (new namespace; the
  in-memory registry built by the pre-eval pass).
- `Rigor::Cache::Descriptor::PreEvalEntry` (new frozen Data:
  `path:`, `content_digest:`).
- New diagnostic rules:
  - `pre-eval.parse-error` (`:warning`)
  - `pre-eval.file-not-found` (`:error`)
  - `pre-eval.duplicate-declaration` (`:info`)
- New `Diagnostic#source_family` symbol `:project_patched`.
- New configuration schema entry under `.rigor.yml`:
  `pre_eval: [string]` (paths relative to the config file).

All updates land in
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb)
in the same commit as the implementation slice that introduces
each surface.

## Implementation slicing

Recommended order; each slice independently shippable. Slices
1 – 3 deliver the MVP feature; slices 4 – 6 are demand-driven
expansions.

1. **Configuration plumbing.** `Configuration#pre_eval`,
   schema entry, JSON-schema validation, `pre-eval.file-not-found`
   `:error` diagnostic. No registry yet — loading a config with
   `pre_eval:` succeeds, but inference proceeds without the
   registry.
2. **Pre-eval walker + registry.** `Analysis::Runner` gains a
   pre-eval pre-pass that drives `ScopeIndexer` against each
   `pre_eval:` path and populates
   `Inference::ProjectPatchedMethods`. `MethodDispatcher` gains
   the new tier above the dependency-source tier.
3. **Cache descriptor + invalidation.**
   `Cache::Descriptor::PreEvalEntry` lands in the descriptor.
   Per-file slice invalidation; `pre_eval:` config change
   invalidates per-file slice consumers.
4. **Pattern-based auto-discovery (option B from the design
   discussion)** — `pre_eval:` accepts glob patterns
   (`lib/core_ext/**/*.rb`). Glob resolution happens at
   config-load time; the pre-eval pass sees the resolved file
   list. Demand-driven: ship only when users want it.
5. **Eager full-project 2-pass discovery (option C)** — a
   `discover_patches: true` config knob walks every project
   file once to find class-reopening shapes, populates the
   registry, then runs the second pass for diagnostics.
   Demand-driven; substantial cost trade-off (2x walk, cache
   complexity).
6. **Plugin pre-eval hook (option D)** — a
   `Plugin::Base#pre_analyze(services)` hook so a plugin can
   programmatically contribute patched-method entries. Useful
   if a plugin needs to declare patches the user doesn't want
   to enumerate manually. Lowest priority — falls out of
   slice 2's design naturally.

## Working decisions

### WD1 — Why explicit list, not auto-discovery, for the MVP?

Three arguments together:

1. **Predictability.** Users know exactly what's in scope.
   Auto-discovery would mean rigor's behaviour depends on
   project layout heuristics that vary by codebase shape.
2. **Cost-bounded.** The pre-eval cost is exactly the count of
   listed files × parse-and-walk cost. Auto-discovery's cost
   is open-ended and rises with project size.
3. **Reversibility.** A user can experiment with the MVP by
   listing one file. Auto-discovery would be opt-in too, but
   the failure mode (wrong files picked up) is harder to
   diagnose than "this list is wrong".

Pattern-based discovery (slice 4) is the natural follow-up
once users have lived with the explicit list for long enough
to notice the maintenance cost.

### WD2 — Why a separate dispatcher tier (not blended with plugins)?

Plugins are authored contracts with a stable API + lifecycle;
project patches are ad-hoc additions to receiver classes the
user owns. Routing them through the same tier would either:

- Force every project-patch user to author a Plugin::Base
  subclass (defeating WD1's reversibility), or
- Bend the plugin contract to accept "anonymous" contributions
  (breaking ADR-2's authored-plugin trust model).

A dedicated tier between plugins and dependency-source keeps
both surfaces clean and lets the dispatcher's tier-ordering
rule remain a simple linear chain.

### WD3 — Why fail-soft on parse errors?

A parse-error in a single `pre_eval:` file should NOT prevent
the rest of the project from being analysed. The user might be
mid-edit; the analyzer should surface the parse error as a
diagnostic and continue with the remaining files' patches in
scope.

The contrast is `pre-eval.file-not-found`, which is loud
(`:error`) because it indicates a configuration mistake the
user must fix before analysis is meaningful.

### WD4 — Why does pre-eval not run inference?

Two reasons:

1. **Cost.** Running full inference twice — once for pre-eval,
   once for the project body — doubles wall-clock for no
   correctness gain in the MVP. Discovery facets (the data the
   patched-method registry needs) are a strict subset of
   inference; running only the discovery pass keeps the
   pre-eval cost proportional to the listed file count.
2. **Cyclicity.** A pre-eval file might itself reference
   patched methods that the pre-eval pass has not yet
   registered (file order within `pre_eval:` matters in that
   case). Running inference inside pre-eval would surface
   spurious diagnostics. Skipping inference avoids the
   problem entirely.

Slice 5 (full-project 2-pass) does run inference twice, but
that's an opt-in expansion gated on demand.

### WD5 — Boundary with `paths:` (no overlap)

Files listed under `pre_eval:` MAY also appear under `paths:`.
When they do, the pre-eval pass + the regular per-file
inference both run on the same file. The patched-method
registry sees the file's declarations; the per-file inference
sees the file's call sites + diagnostics. No deduplication is
needed — the two passes' outputs don't overlap.

Files listed ONLY under `pre_eval:` (not also under `paths:`)
contribute to the registry but get NO diagnostics. This is the
expected case for `lib/core_ext/` files the user trusts and
doesn't want analyzed for `call.undefined-method` etc.

### WD6 — Why a new diagnostic family `pre-eval.*` instead of folding into existing families?

The `pre-eval.*` family makes the cause-of-diagnostic visible:
users can `# rigor:disable pre-eval.*` to silence the whole
pre-eval channel without affecting `call.*` / `flow.*` /
`def.*`. Folding pre-eval errors into `configuration-error` /
`call.*` would lose that surgical disability.

### WD7 — Boundary with the Robustness Principle (ADR-5)

The patched-method registry records whatever the project's `def`
declared. If a method has no RBS sig (the common case for
core_ext patches), its return type is `untyped` per ADR-5's
strict-on-returns / lenient-on-parameters asymmetry. Per-call-site
callers see `Dynamic[top]` returns.

When a project pairs a `def` in a `pre_eval:` file with an RBS
sig under `sig/`, the RBS wins on dispatch per the standard
tier ordering. Users who want precise project-patch returns
should write RBS for their patches.

## Alternatives considered

- **Auto-discovery via syntactic patterns** (option B). Rejected
  for the MVP per WD1. Tracked as slice 4.
- **Full-project 2-pass discovery** (option C). Rejected for the
  MVP per WD4 (cost) and stays open for slice 5.
- **Plugin-API hook** (option D). Useful but too heavy for the
  MVP. Tracked as slice 6.
- **Run inference (not just discovery) during pre-eval**.
  Rejected per WD4. The 2-pass shape lands separately if it
  becomes load-bearing.
- **Make `pre_eval:` files load-bearing for `paths:` analysis
  diagnostics** (i.e. treat them like any other source file).
  Rejected per WD5: most users want pre-eval files exempt from
  `call.undefined-method` because their RBS-less idiomatic
  patches would trip the rule constantly.

## Open questions

- **`pre_eval:` ordering semantics.** When two pre-eval files
  declare the same `(class_name, method_name, kind)`, last-wins
  is documented. But should ordering also affect the *resolution*
  semantics — e.g., does a pre-eval method *override* a later
  RBS declaration of the same method? Today's tier ordering says
  RBS wins; the ADR commits to that, but real-world projects
  might want the opposite for `core_ext`-style patches that
  *intentionally* shadow stdlib behaviour. Decision deferred to
  slice 2 dogfood feedback.
- **Should `pre_eval:` accept directories?** A directory expansion
  to all `.rb` files under it would make `pre_eval: [lib/core_ext]`
  shorthand for the typical use case. Decision deferred to slice
  4 (auto-discovery slice), since the same glob machinery
  handles both shapes.
- **Should `pre_eval:` participate in the cache `--cache-stats`
  output?** Probably yes — users want to see how many
  patched-method entries are populated, what the per-slice
  invalidation activity looks like. Decision deferred to slice
  3 implementation.
- **Does pre-eval need a CLI flag to inspect the registry?**
  `rigor pre-eval --dump` would print the resolved
  `(class_name, method_name, source_path:line)` table for
  debugging. Decision deferred to demand.

## Background Research Notes

- [`docs/notes/20260518-matsumoto-2010-cfa-rigor-review.md`](../notes/20260518-matsumoto-2010-cfa-rigor-review.md)
  — Matsumoto & Minamide 2010's semi-flow-sensitive CFA
  on SemiRuby is the *theoretical* solution to the same
  monkey-patch problem ADR-17 attacks engineering-side.
  The paper tracks per-program-point "method
  configurations" (which `def`s are visible at this
  exact location) and proves soundness. ADR-17 instead
  pays an explicit-pre-eval cost up-front, freezes the
  resulting (class, method, kind) registry into a
  dispatcher tier, and lets the rest of the analyzer
  stay flow-insensitive on method definitions. The paper
  reads as the alternative road we did not take, and
  records why semi-flow-sensitive method configuration
  remains a credible future precision-uplift path if the
  explicit-list MVP ever proves insufficient.

## Revision history

- 2026-05-16 — initial proposal. Triggered by the v0.1.6 cycle
  scoping discussion after v0.1.5 release. Surfaced during the
  Redmine real-world test as the missing half of the
  ActiveSupport core_ext workstream (the other half being O1's
  RBS bundle, which landed in v0.1.5).
