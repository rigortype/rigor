# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.0.8 released.** Cache infrastructure (`Descriptor`, `Store`), the first cached producer (`RbsConstantTable`), CLI observability flags (`--cache-stats` / `--clear-cache`), and `Diagnostic#source_family` provenance landed. See `CHANGELOG.md`'s `[0.0.8]` section and the v0.0.8 row of [`docs/MILESTONES.md`](MILESTONES.md).

**v0.0.9 in development on `master`.** Per the single-digit version-component policy, `0.0.9` is the only pre-`0.1.0` slot — the next release after `0.0.9` is `0.1.0`, not `0.0.10`. Every pre-`0.1.0` slice continues to land inside `0.0.9` until the user authorises a release.

The v0.0.9 cluster, in commit order:

- 9378df2 — **A1**: `Analysis::Runner.cache_store` + `rigor check --no-cache`.
- ee021a2 — **A2**: `RbsLoader#constant_type` routes through `RbsConstantTable`; `Environment.for_project(cache_store:)` plumbs the Store down.
- 1407225 — **A3**: `Cache::Store#stats` + `--cache-stats` runtime breakdown.
- e764565 — **A4**: `Reflection.constant_type_for` confirmed cached end-to-end.
- c48f05f — **B**: `Rigor::FlowContribution` bundle struct (8 slots + `Provenance`).
- 8a94e7a — **C**: `Rigor::Cache::RbsKnownClassNames` + `RbsDescriptor` shared builder.
- 41aec51 — **D**: `RbsExtended.read_flow_contribution` rolls directives into a bundle.
- 3ae65e2 — **E**: paired-complement registry; `lowercase ↔ not_lowercase` pair.
- 908eb08 — **F**: `literal-string` carrier + interpolation flow tracking.
- 8951c1d — **C1**: `Store#fetch_or_compute(serialize:, deserialize:)` callable surface.
- 9b50e2b — **B (cache producer)**: `Rigor::Cache::RbsClassAncestorTable`.
- c601f40 — **A (cache producer)**: `Rigor::Cache::RbsClassTypeParamNames`.
- d662d4a — **E follow-up**: `uppercase ↔ not_uppercase` and `numeric ↔ not_numeric` pairs.
- 5600efc — **F follow-up**: `LiteralStringFolding` tier — literal-string through `String#+` / `String#*`.
- 8f7c32c — **C2**: `Rigor::Cache::RbsEnvironment` + `RBS::Location` Marshal patch — caches the full env, biggest cold-start win.

Working state: 1710 RSpec examples / 0 failures, RuboCop 160 files / 0 offenses, `bundle exec exe/rigor check lib` reports 0 diagnostics. Version stays at `0.0.8` until the user authorises a release.

### Notable carry-overs (deferred past the v0.0.9 cluster, queued for v0.1.0+ or further v0.0.9 slices)

- **More cached producers under `Rigor::Reflection`** (`instance_method_definition`, `singleton_method_definition`, …). Now feasible since C2 made every RBS-native value Marshal-clean.
- **Wire `FlowContribution` bundles through internal narrowing.** Built-in narrowing rules and `PredicateEffect`-style facts could round-trip through the bundle; the conversion sites stay analyzer-internal until v0.1.0's plugin merger requires them.
- **Decimal / octal / hex `int-string` complement pairs.** Complement domains are too vague to warrant separate carriers in practice; the Difference fallback stays.
- **literal-string propagation through `<<` mutation.** Requires a mutation-effect path the dispatcher does not currently expose.

## Where the Work Resumes

### Highest-leverage next slices

The next preview is **v0.0.8 / pre-v0.1.0** (or whichever version captures the next slice — bump deferred until that scope is decided). The v0.0.7 work closed the spec ↔ implementation gap on the type-language and built-in-coverage axes; the remaining levers are mostly pre-v0.1.0 substrate or low-leverage tail.

- **Cache persistence layer.** The cache slice taxonomy design doc ([`docs/design/20260505-cache-slice-taxonomy.md`](design/20260505-cache-slice-taxonomy.md)) fixed the schema; the next pre-v0.1.0 slice is the storage backend, locking model, and eviction policy. First cache-related code slice. Per the v0.1.0 readiness sequencing in [`docs/design/20260505-v0.1.0-readiness.md`](design/20260505-v0.1.0-readiness.md), this is the natural successor to the v0.0.7 design output.
- **Flow-contribution bundle struct.** ADR-2 § "Flow Contribution Bundle" specifies the eight-slot shape plugins return. The internal `PredicateEffect` etc. structs convert into bundles at the `RbsExtended` / `Narrowing` boundary; built-in rules produce bundles too. Plugin authors then return bundles. Modest implementation; unblocks the dynamic-return / type-specifying / dynamic-reflection extension protocols.
- **Diagnostic provenance prefix.** `Rigor::Analysis::Diagnostic` gains a `source_family` field; the formatter publishes `plugin.<id>.<rule>` style identifiers per ADR-2 § "Plugin Diagnostic Provenance". Small surface, prepares the v0.1.0 plugin observability story.
- **Public-API declaration for `Rigor::Scope`, `Rigor::Type`, `Rigor::Environment`.** Namespace policy + drift tests. No new code, just contract declaration. Catches accidental signature changes before plugin authors notice.
- **Predicate-complement narrowing for `Refined[base, predicate]`.** Architectural — needs either a mixed-case carrier (e.g. `mixed-case-string` for `~lowercase-string`) or a paired-complement registry. Not strictly pre-v0.1.0 but unblocks the `~T` symmetry the spec promises.
- **`literal-string` / `non-empty-literal-string` flow-tracking.** Needs the `Literal` flow flag propagated through `+` / `<<` / interpolation; bigger than a single slice and naturally lives alongside the plugin flow-effect bundle work.

### Items intentionally deferred past v0.0.7

- `literal-string` / `non-empty-literal-string` (see above; needs flow tracking).
- Predicate-complement narrowing for `Refined[base, predicate]` (see above).
- C-body classifier wider transitive mutator scan — guards against the `Array#to_a` regression that gated the v0.0.5 fix.
- `Data.define` override-aware initializer dispatch — block-body `def initialize(...)` as the canonical sig for `Const.new`.
- ObjectSpace catalog import — needs a singleton-module dispatch path the catalog tier does not yet provide.
- URI catalog import — pure-Ruby stdlib gem with no C surface; outside the standard import skill's premise.
- Pathname / URI delegation rules — wider refactor (Pathname facade routing through File projections).
- `numeric-string` regex-pattern recogniser.
- `self`-narrowing in `predicate-if-*` — no `self`-narrowing surface in the engine yet.
- `rigor:v1:conforms-to` directive — needs a structural-conformance checker.

### Out of v0.0.x scope (architectural)

- Caches and the plugin API (ADR-2) are reserved for v0.1.0. See [`docs/MILESTONES.md`](MILESTONES.md). The v0.1.0 readiness analysis — what the v0.0.x substrate already provides, what still needs pre-work, and the recommended next slice for a cold-start implementer — lives in [`docs/design/20260505-v0.1.0-readiness.md`](design/20260505-v0.1.0-readiness.md).
- New CheckRules rule families beyond the v0.0.3 `always-raises` line. Type-incompatible writes, return-type mismatch, unreachable branches stay deferred until the inference surface they depend on is sturdy.

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread:

1. **`spec/rigor/source/node_locator_spec.rb:82`** — `String#index` returns `Integer | nil` followed by an unguarded `+ 1`. The `possible-nil-receiver` rule flags it correctly; the spec uses a load-bearing nil-or-throw idiom that is awkward to express. Either add a `# rigor:disable possible-nil-receiver` line or rewrite the spec to guard explicitly. Not a blocker — the analyzer is correct.

2. **C-body classifier indirect mutators.** The catalog extractor's regex does not follow `str_modifiable` / `time_modify` / similar helper indirection; methods like `String#replace`, `Time#localtime`, and `Set#reset` land as `:leaf` even though they mutate. The pure-`rb_check_frozen`-wrapper detection landed in v0.0.5 narrows the gap, but per-class blocklists in `STRING_CATALOG` / `TIME_CATALOG` / `SET_CATALOG` still absorb false positives the narrow regex misses. Long-term: the classifier should track the helpers transitively without over-flagging legitimate non-mutators (the `Array#to_a` regression that gated the v0.0.5 fix).

3. **`numeric.yml` `unknown` entries.** Two methods stay `unknown` after the v0.0.3 extraction:
   - `Numeric#clone` (cfunc `num_clone` aliases to `rb_immutable_obj_clone` in `object.c`, not in the indexed C files).
   - `Integer#ceildiv` (prelude body delegates to user-overridable `#div`, classified as `composed`).
   Adding `references/ruby/object.c` to the Numeric topic's `c_index_paths` resolves the first; the second is intrinsically `dispatch` once the prelude classifier learns to flag `composed` bodies that call user-overridable methods.

## Reading Order for a Returning Implementer

1. `git log --oneline master ^v0.0.3` — every v0.0.4 slice in commit order.
2. `CHANGELOG.md` `[0.0.4]` section — user-visible summary.
3. [`docs/MILESTONES.md`](MILESTONES.md) — what v0.0.5 commits to and what stays out.
4. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes (with the v0.0.4 status notes).
5. [`docs/adr/5-robustness-principle.md`](adr/5-robustness-principle.md) — the asymmetric authorship rule that drives every catalog and refinement decision.
6. [`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md) — the procedure for importing a new built-in class. Stage 0 documents `tool/scaffold_builtin_catalog.rb`, the v0.0.4 automation that drives the mechanical 70 % of an import.

After those, the v0.0.4 implementation surface is locatable from grep over `lib/rigor/type/`, `lib/rigor/inference/`, `lib/rigor/inference/method_dispatcher/`, and `data/builtins/ruby_core/`.
