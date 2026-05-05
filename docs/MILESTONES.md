# Release Milestones

Tracks the deliberately-scoped envelope around each preview release. Items inside a milestone are commitments; items outside it are deferred. The line between "in" and "out" is what makes each release shippable.

This file is informational, not normative. The binding contracts live in [`docs/adr/`](adr/) and [`docs/type-specification/`](type-specification/). When this file disagrees with an ADR or spec, the ADR / spec binds and this file is out of date.

## v0.0.3 — Released 2026-05-02

The third preview. Theme: **see literal values where the analyzer can prove them**, across a wide enough surface that real Ruby programs benefit without per-call-site annotation. See `CHANGELOG.md` for the full added/fixed list.

Major surfaces landed:

- Aggressive constant folding (unary + binary + Union[Constant…] cartesian + integer-range arithmetic + Tuple-shaped divmod).
- `Type::IntegerRange` carrier with the PHPStan-style `int<min, max>` family (`positive-int`, `negative-int`, `non-negative-int`, `non-positive-int`, `int<a, b>`).
- Built-in method catalog extraction pipeline (`tool/extract_builtin_catalog.rb`) covering Numeric / Integer / Float / String / Symbol / Array / IO / File. Generated YAML under `data/builtins/ruby_core/`. Catalog-driven dispatch with per-class mutator blocklists.
- Scope-level integer-range narrowing through `<` / `<=` / `>` / `>=` / `positive?` / `negative?` / `zero?` / `nonzero?` / `between?`.
- `case/when` integer-range and integer-literal narrowing.
- Iterator block-parameter typing for `times` / `upto` / `downto`.
- Branch elision on provably-truthy/falsey predicates.
- `Tuple`-shaped `Integer#divmod` / `Float#divmod` folds.
- `Type::Difference` carrier (point-removal half of OQ3); `non-empty-string`, `non-zero-int`, `non-empty-array[T]`, `non-empty-hash[K, V]` reachable through `RBS::Extended`'s new `rigor:v1:return:` directive.
- `always-raises` diagnostic for provable Integer division-by-zero.
- `File` path-manipulation folding gated behind `fold_platform_specific_paths` config (default off, platform-agnostic).
- ADR-5 (robustness principle) and the OQ1 / OQ2 / OQ3 working decisions in ADR-3.

## v0.0.4 — Released 2026-05-02

The fourth preview. Theme: **finish the OQ3 refinement-carrier strategy and broaden the RBS::Extended directive surface**. See `CHANGELOG.md`'s `[0.0.4]` section for the full added/changed/fixed list.

Major surfaces landed:

- `Type::Refined` carrier (OQ3 predicate-subset half) and `Type::Intersection` carrier (composed refinement names) — together with `Type::Difference` from v0.0.3, the OQ3 carrier triple is feature-complete.
- Fourteen imported built-in refinement names resolvable through `Builtins::ImportedRefinements`: the v0.0.3 point-removal four, the v0.0.3 IntegerRange-aliased four, the new predicate six (`lowercase-string`, `uppercase-string`, `numeric-string`, `decimal-int-string`, `octal-int-string`, `hex-int-string`), and the new composed two (`non-empty-lowercase-string`, `non-empty-uppercase-string`).
- `RBS::Extended` directive surface complete on both sides of the boundary: `rigor:v1:return:` (now accepts parameterised payloads), `rigor:v1:param:` (call-site argument-type-mismatch rule + body-side `MethodParameterBinder` narrowing), `rigor:v1:assert:` and `rigor:v1:predicate-if-*:` (now accept refinement payloads in addition to class names).
- Hash / Range / Set / Time built-in catalog imports through `tool/extract_builtin_catalog.rb`. `MethodDispatcher::ConstantFolding#catalog_for` is now table-driven (`CATALOG_BY_CLASS`) so further imports cost one row.
- Enumerable-aware `#each_with_index` block-parameter typing in `IteratorDispatch` — element type is projected per receiver shape, index slot tightens to `non-negative-int`.
- `tool/scaffold_builtin_catalog.rb` automates the mechanical 70 % of new built-in catalog imports (Stage 0 of the `rigor-builtin-import` skill).
- CLI `type-of` regression specs binding the kebab-case canonical-name display contract for refinement-bearing types in both human-readable and `--format=json` output.

## v0.0.5 — Released 2026-05-03

Theme: **continue catalog coverage, broaden the Enumerable-aware projections, and absorb the Steep cross-checker triage follow-ups**. See `CHANGELOG.md`'s `[0.0.5]` section for the full added/changed list.

Major surfaces landed:

- Comparable / Enumerable module catalog imports + `tool/scaffold_builtin_catalog.rb --module` mode.
- Date / DateTime catalog imports (stdlib gems under `references/ruby/ext/date/`).
- Rational and Complex catalog imports — landed via parallel worktree-isolated agents.
- Include-aware module-catalog fallthrough in `MethodDispatcher::ConstantFolding#catalog_allows?` activates the Comparable / Enumerable imports for direct (non-redefined) callers.
- 2-argument constant-fold dispatch (`try_fold_ternary`) folds `Comparable#between?(min, max)`, `Comparable#clamp(min, max)`, `Integer#pow(exp, mod)`.
- `narrow_not_refinement` extended to IntegerRange (paired-bound complement) and Intersection (De Morgan); refinement negation (`~T`) now accepted as the RHS of `assert` / `predicate-if-*` directives.
- C-body classifier — pure `rb_check_frozen` wrapper detection reclassifies `Time#gmtime` / `Time#utc` from `:leaf` to `:mutates_self`.
- `tool/catalog_diff.rb` + `make catalog-diff` target for surface-level diffs between two YAML snapshots.
- **Steep cross-checker scaffolding.** `tool/steep/` ships Steep 2.0 as an isolated sibling Bundler (`make steep-check`) for sig / impl drift detection. Triage report and category breakdown in [`docs/notes/20260503-steep-cross-check-triage.md`](notes/20260503-steep-cross-check-triage.md). The triage's mechanical fixes (A-1 through A-5: predicate sigs, IntegerRange narrowing, scope_indexer arity, env duplication, CLI kwarg defaults) all landed.
- **Branch-aware scope propagation for expression-position conditionals.** `Inference::ScopeIndexer.propagate` now routes IfNode / UnlessNode branches through `Narrowing.predicate_scopes`, fixing a class of false-positives where an `if` / `unless` buried inside a CallNode argument or `[]=` RHS never reached `eval_if`'s narrowing path.
- **`Kernel#Array` precision tier (`MethodDispatcher::KernelDispatch`).** Folds `Array(arg)` into a precise `Array[E]` whenever the argument's value-lattice shape lets us prove the element type. Distributes element-wise over unions and unifies.
- **`Const = Data.define(*Symbol)` discovery.** `Inference::ScopeIndexer.record_declarations` registers `Const` (qualified by the surrounding path) as a discovered class so `Const.new(...)` resolves to `Nominal[<qualified>]` via `meta_new`. Override-aware initializer-signature dispatch (using the block's `def initialize(...)` as the canonical sig) remains open as a follow-up.

Deferred from v0.0.5 (carried forward):

- Predicate-complement narrowing for `Refined[base, predicate]` — needs either a new mixed-case carrier or per-predicate paired-complement registry entries.
- Block-shaped fold dispatch — folding the block's *return* into a precise carrier on top of the existing `IteratorDispatch` block-parameter typing; IntegerRange operands on the 2-arg path are also still held back.
- Further catalog imports — URI and Kernel fall outside the standard import skill's premise (Kernel methods scatter across 20+ C files with no single Init function; URI is a pure-Ruby stdlib gem with no C surface). Both need a hand-rolled or custom-scaffold approach. Pathname (already partial) and ObjectSpace remain in the candidate pool.
- C-body classifier — wider transitive mutator scan that does not over-flag legitimate non-mutators (the `Array#to_a` regression that gated the conservative v0.0.5 fix).
- `Data.define` override-aware initializer dispatch — block-body `def initialize(...)` as the canonical sig for `Const.new` (today the auto-generated kw shape wins).
- `Trinary` return-type contract on type-carrier predicate methods — closing the strict-on-returns gap requires a new CheckRules rule family (`return-type-mismatch`), explicitly deferred by [`docs/CURRENT_WORK.md`](CURRENT_WORK.md) until the inference surface is sturdy enough to avoid false-positive churn.
- Cross-checker runner integration — `make steep-check` stays out-of-band; the Steep residual (6 warnings, all in `fact_store.rb` and rooted in Steep-side limitations Rigor closes natively) is the steady-state floor.

(Stretch surfaces carry forward into the v0.0.6 row below.)

## v0.0.6 — Released 2026-05-05

The sixth preview. Theme: **fold block-taking Enumerable methods through the constant-folding tier** so iterator-shaped expressions over literal collections produce precise carriers instead of widening through RBS. See `CHANGELOG.md`'s `[0.0.6]` section for the full added / fixed list.

Major surfaces landed:

- **`MethodDispatcher::BlockFolding` precision tier.** `dispatch_precise_tiers` consumes the existing `block_type:` and folds the constant-block side of `select` / `filter` / `reject` / `take_while` / `drop_while` / `all?` / `any?` / `none?` / `find` / `detect` / `find_index` / `index` / `count`. Filter methods collapse to either the receiver or `Tuple[]`; predicate methods produce `Constant[bool]` whenever the receiver-emptiness × block-truthiness combination is unconditional in Ruby's semantics; find-family methods fold to `Constant[nil]` on the falsey side and to `Constant[size]` / `Constant[0]` for `count`.
- **`ExpressionTyper#try_per_element_block_fold` over Tuple receivers** for `map` / `collect` / `filter_map` / `flat_map` / `find` / `detect` / `find_index` / `index`. The block body is type-checked once per Tuple position, then assembled per-method into a precise Tuple. Numbered parameters (`_1`) participate identically.
- **Per-element fold over short `Constant<Range>` receivers**, capped at 8 elements so `(1..3).map { |n| n.to_s }` resolves to `["1", "2", "3"]` without exploding for million-element ranges.
- **Branch elision for expression-position conditionals.** `if` / `unless` / ternary expressions whose predicate folds to a `Type::Constant` drop the unreachable branch. `&&` / `||` short-circuit on Constant-shaped left operands following Ruby's actual semantics. Composes through three layers so `[1, 2, 3].filter_map { |n| n.even? ? n.to_s : nil }` resolves to `Tuple[Constant["2"]]`.
- **IntegerRange-aware ternary fold.** The 2-arg `try_fold_ternary` path accepts `IntegerRange` receivers paired with scalar `Constant<Integer>` args for `Comparable#between?` / `Comparable#clamp`. `int<3, 7>.between?(0, 10)` folds to `Constant[true]`; `int<3, 7>.clamp(4, 6)` folds to `int<4, 6>`.
- **Empty array literal carrier — `[]` → `Tuple[]`.** Pins the literal's known arity so `:flat_map` can concatenate cleanly across all-empty per-position results.
- **Pathname catalog import** (102 instance methods, 2 singletons, 5 aliases) via `tool/scaffold_builtin_catalog.rb --init-fn InitVM_pathname`. Pathname is a thin wrapper that mostly delegates to File / Dir / FileTest, so the user-visible payoff is narrower than Numeric or String — the import buys receiver-class recognition, a defensive `:initialize_copy` blocklist entry, and `:leaf` folding for `<=>`.
- **Extractor BeginNode-bodied-`def` classifier fix.** `PreludeParser#analyse_body` previously raised on the rescue-on-def idiom (`def foo; …; rescue; …; end`). The classifier now descends into the begin-block's `statements`. Surfaced importing Pathname; every catalog regenerates cleanly under `make extract-builtin-catalogs`.

Deferred from v0.0.6 (carried forward):

- Predicate-complement narrowing for `Refined[base, predicate]` — still needs either a new mixed-case carrier or per-predicate paired-complement registry entries.
- C-body classifier wider transitive mutator scan that does not over-flag legitimate non-mutators.
- `Data.define` override-aware initializer dispatch — block-body `def initialize(...)` as the canonical sig for `Const.new`.
- `Trinary` return-type contract on type-carrier predicate methods — still deferred until the inference surface is sturdy enough to avoid false-positive churn.
- Cross-checker runner integration — `make steep-check` stays out-of-band.
- Further catalog imports — URI and Kernel still fall outside the standard import skill's premise. ObjectSpace is in the candidate pool but is a thin module (5 module functions defined under `Init_GC`); the user-visible payoff is small.
- `:flat_map` over `Nominal[Array[T]]` per-position results — largely subsumed by the existing RBS substitution; not worth a dedicated slice.

Stretch surfaces (carried forward unchanged):

- Pathname / URI delegation rules so `Pathname#exist?` etc routes through `File.exist?` projections.
- `String#%` format-string parsing for catalog-aware fold over `Constant<String>` template + `Constant<…>` values.
- `numeric-string` recogniser that classifies `String#match?(/\A\d+\z/)` as a `Refined[String, :numeric]` narrowing.

## v0.0.7 — Released 2026-05-05

Theme: **pre-plugin coverage push**. Close the gap between what the type-language and built-in-coverage specs already commit to and what the analyzer actually implements, so the plugin API designed against this surface in v0.1.0 has a complete substrate to attach to. Breadth-over-depth: sixteen feature slices plus three pre-v0.1.0 substrate slices (Reflection facade, consumer migration, two design docs).

See `CHANGELOG.md`'s `[0.0.7]` section for the full added list. Major surfaces landed:

- **Type-language type functions.** `key_of[T]` / `value_of[T]`, `int_mask[…]` / `int_mask_of[T]`, and the `T[K]` indexed-access operator — all spec-listed but previously unimplemented. Reachable from RBS::Extended directive payloads; the parser accepts integer-literal arguments and class-name-headed types directly.
- **Constant carriers expanded.** `Rational` / `Complex` (literal nodes + Kernel-call folds), `Regexp` (non-interpolated literal lift), and `Pathname` (constructor lift + 14-method unary / 8-method binary fold table covering pure path manipulation; filesystem-touching methods stay declined).
- **`Constant<Range>` unary precision.** `to_a` lifts to per-position Tuple (capped at 16); `first` / `last` / `min` / `max` / `count` / `size` / `length` fold to precise constants.
- **Tuple precision (eleven new handlers).** `empty?`, `any?`, `all?`, `none?`, `include?`, `sum`, `min`, `max`, `sort`, `reverse`, `to_a`, `zip`. Per-position semantics preserved; non-Constant elements decline.
- **HashShape projections.** `keys`, `values`, `count`, `length`, `empty?`, `any?`, `first`, `flatten`, `compact`, plus the Tuple ↔ HashShape conversion folds (`to_h`, `to_a`, `invert`, `merge`).
- **String precision.** `String#%` over Tuple / HashShape arguments; `Constant<String>#chars` / `#bytes` / `#lines` / `#split` / `#scan` lift Array results to per-position Tuples.
- **Refinement narrowing.** `~Refined[base, predicate]` narrows through `Difference[base, refined]` instead of falling back to `current_type` unchanged.
- **Empty literal carriers.** `{}` resolves to `HashShape{}`; `Array.new(n)` / `Array.new(n, value)` lift to per-position Tuples.

Pre-v0.1.0 substrate that landed in the v0.0.7 cycle:

- **`Rigor::Reflection` facade** — unified read API over `ClassRegistry` + `RbsLoader` + `Scope` discovered facts. Public read shape for v0.1.0 plugin-API readiness; spec at [`docs/internal-spec/reflection.md`](internal-spec/reflection.md).
- **Engine-internal consumer migration** to the facade. Mechanical refactor; no behaviour change.
- **v0.1.0 readiness design doc** at [`docs/design/20260505-v0.1.0-readiness.md`](design/20260505-v0.1.0-readiness.md).
- **Cache slice taxonomy design doc** at [`docs/design/20260505-cache-slice-taxonomy.md`](design/20260505-cache-slice-taxonomy.md).

Deferred from v0.0.7 (carried forward):

- `literal-string` / `non-empty-literal-string` — needs flow tracking, not a value-domain refinement.
- Predicate-complement narrowing for `Refined[base, predicate]` requires either a mixed-case carrier or a paired-complement registry (architectural decision).
- C-body classifier wider transitive mutator scan.
- `Data.define` override-aware initializer dispatch.
- ObjectSpace catalog import — needs singleton-module dispatch, which the catalog tier does not yet provide.
- URI catalog import — pure-Ruby stdlib gem with no C surface; outside the standard import skill's premise.
- `numeric-string` regex-pattern recogniser.
- `self`-narrowing in `predicate-if-*` — no `self`-narrowing surface in the engine yet.
- `rigor:v1:conforms-to` directive — needs a real structural-conformance checker beyond the v0.0.7 envelope.
- Caches and the plugin API — reserved for v0.1.0. The cache slice taxonomy design doc is the contract; the persistence layer is the next pre-v0.1.0 slice (and the first cache-related code).

## v0.0.8 — Released 2026-05-04

Theme: **first cache-related code slice**. Landed the persistence layer the v0.0.7 cache slice taxonomy design doc ([`docs/design/20260505-cache-slice-taxonomy.md`](design/20260505-cache-slice-taxonomy.md)) commits to, plus a Marshal-clean producer wired through it end-to-end. Backend per [ADR-6](adr/6-cache-persistence-backend.md): a sharded directory of binary entries written through a custom canonical format, zero new gem dependencies.

Slices (in commit order):

1. **`Rigor::Cache::Descriptor` value object.** The taxonomy doc's typed-slot schema (`FileEntry`, `GemEntry`, `PluginEntry`, `ConfigEntry`); composition (`union-by-key`, stricter-comparator-wins for `files`, `Conflict` on disagreement); canonical serialisation; SHA-256 cache-key derivation. Pure value object, spec-tested in isolation.
2. **`Rigor::Cache::Store` filesystem backend.** `<root>/<producer-id>/<2-prefix>/<62-suffix>.entry` layout; `"RIGOR\x00\x01"` magic + varint-prefixed descriptor + value + trailing SHA-256 file format; rename-into-place atomicity with `flock(LOCK_EX)` on the destination; schema-version marker at `<root>/schema_version.txt` (mismatch wipes the directory). Read failures (missing, short, bad magic, bad checksum, malformed varint, unmarshal-able) silently fall through to a cache miss. Producer ids constrained to `[a-z][a-z0-9._-]*` for filesystem safety.
3. **First cached producer — `Rigor::Cache::RbsConstantTable`.** Caches a `Hash<String, Rigor::Type>` mapping every RBS-declared constant to its translated `Rigor::Type`. The slice plan originally named the RBS environment loader as the first producer; implementation discovered `RBS::Environment` is not Marshal-clean (transitive `RBS::Location` lacks `_dump_data`). [ADR-6 § 8](adr/6-cache-persistence-backend.md) documents the finding; the slice caches a post-translation artefact instead. Adds `RbsLoader#constant_names` so the producer can enumerate constants through the public surface.
4. **`rigor check --cache-stats` and `--clear-cache`.** `--cache-stats` prints an on-disk inventory at end-of-run (per-producer entry counts, total bytes, schema version) sourced from `Store.disk_inventory`. `--clear-cache` wipes `.rigor/cache` before the run. Per-run hit/miss counters deferred until production code wires the cache.
5. **Diagnostic source-family provenance.** `Rigor::Analysis::Diagnostic` gains `source_family:` (default `:builtin`) and `qualified_rule` (`"#{source_family}.#{rule}"` for non-default families). JSON output carries both `source_family` and the bare `rule` side-by-side. Prepares ADR-2's plugin-observability story without committing to the plugin API itself.

Deferred from v0.0.8 (carried forward) — these are part of v0.1.0 or later:

- Eviction / LRU / size cap. v0.0.8 ships unbounded; users run `--clear-cache` if needed.
- Concurrent multi-process writes beyond the per-file `flock` model.
- LSP / long-running-daemon cache mode.
- Cross-machine cache sharing.
- Plugin-side cache producers — gated on the plugin API itself, which lands in v0.1.0.
- Inference / catalog / scope-index caches beyond `RbsConstantTable`. The architecture supports them; the implementation work is per-producer and naturally fans out into v0.0.9+.
- **Wiring the cache into `rigor check`.** v0.0.8 ships the cache infrastructure plus a working producer surface, but no production caller in `rigor check` exercises it yet. Connecting `RbsConstantTable.fetch` (or successor producers) into the analysis pipeline so cold-start runs see a measurable speed-up is the natural v0.0.9 follow-up.
- **Custom-serialiser plumbing on `Store` for `RBS::Environment` itself.** The biggest cold-start cost remains `RbsLoader#build_env`. Caching it directly requires either a `Store`-side `dump`/`load` callable surface (each producer registers its own serialiser) or a schema-stable intermediate that walks `RBS::Environment` into a Marshal-safe shape. Both are out of scope for v0.0.8.
- `Rigor::FlowContribution` bundle struct — the next pre-v0.1.0 substrate slice after the cache layer.

## v0.0.9 — Ready for release

Theme: **wire the cache into `rigor check`, then advance the next pre-v0.1.0 substrate.** v0.0.8 shipped the cache infrastructure plus a working producer surface but no production caller; v0.0.9 closes that loop, surfaces real per-run hit/miss/write counters, lands the public `FlowContribution` bundle, and adds a second cached producer.

Slices in commit order:

### Group A — wired the cache into `rigor check`

1. **`Analysis::Runner.cache_store` surface + `rigor check --no-cache`.** Runner defaults to a `Cache::Store` rooted at `.rigor/cache`; the CLI flag threads `nil` through to disable.
2. **`RbsLoader#constant_type` routes through `RbsConstantTable`** when `cache_store` is set. `Environment.for_project(cache_store:)` plumbs the Store down. First end-to-end cold/warm-start gap; `rigor check --cache-stats` now reports a non-empty inventory by default.
3. **`Cache::Store#stats` in-process counters.** Hits / misses / writes (and per-producer breakdown) bumped inside `fetch_or_compute` and surfaced through a frozen-snapshot accessor. `--cache-stats` adds a "this run:" section alongside the disk inventory; under `--no-cache` the section is omitted.
4. **`Reflection.constant_type_for` confirmed cached end-to-end.** Tests + the new "Constant-lookup path under `cache_store`" section in `docs/internal-spec/cache.md` document every call site that threads through the cache.

### Group B — pre-v0.1.0 substrate

5. **`Rigor::FlowContribution` bundle struct.** Eight content slots (`return_type`, `truthy_facts`, `falsey_facts`, `post_return_facts`, `mutations`, `invalidations`, `exceptional`, `role_conformance`) plus a `Provenance` Data carrier (`source_family`, `plugin_id`, `node`, `descriptor`). Frozen on construction; collection slots duped+frozen. Public read shape per ADR-2 § "Flow Contribution Bundle"; the element-list flattening ADR-2 mentions is intentionally deferred to v0.1.0 alongside the contribution merger that consumes it.

### Group C — second cached producer + shared descriptor builder

6. **`Rigor::Cache::RbsKnownClassNames`** materialises the Set<String> of every RBS-declared class / module / alias name. `RbsLoader#class_known?` consults it on the cached path. **`Rigor::Cache::RbsDescriptor`** extracts the rbs-environment descriptor builder both producers share, so a single signature change or rbs gem bump invalidates every RBS-derived cached producer in lockstep.

Deferred from v0.0.9 (mostly absorbed into the v0.0.10 cluster):

- ~~**Custom-serialiser plumbing on `Store` for `RBS::Environment` itself.**~~ Landed in v0.0.10 C1 + C2.
- ~~**More cached producers under `Rigor::Reflection`**~~ — partial: ancestor table and type-param-names landed in v0.0.10 (B+A); per-method `instance_method_definition` / `singleton_method_definition` still pending.
- **Wire `FlowContribution` bundles through internal narrowing.** Built-in narrowing rules and `PredicateEffect`-style facts could round-trip through the bundle; the conversion sites stay analyzer-internal until v0.1.0's plugin merger requires them. RbsExtended did lift directives into a bundle in v0.0.10 D.
- **Plugin-side cache producers.** Gated on the plugin API (v0.1.0).
- **LSP / long-running-daemon cache mode.**
- **LRU eviction / size cap.** Still unbounded; users run `--clear-cache` if needed.

## v0.0.10 — In development

Theme: **finish the cache surface and broaden the type language.** Builds on the v0.0.9 cluster: more cached producers, a custom-serialiser surface on Store, `RBS::Environment` itself cached on top of the new surface, and three pieces of language work (FlowContribution wiring on the producer side, paired-complement narrowing for Refined predicates, literal-string flow tracking through interpolation and concat).

Commits in chronological order:

- 41aec51 — **D**: `Rigor::RbsExtended.read_flow_contribution(method_def)` rolls every recognised directive on a single method into a `Rigor::FlowContribution` bundle. `:rbs_extended` source family. Internal narrowing keeps the typed Data carriers; the bundle is the public packaging the v0.1.0 contribution merger consumes.
- 3ae65e2 — **E**: paired-complement registry on `Type::Refined` (`COMPLEMENT_PAIRS`). First pair: `lowercase ↔ not_lowercase`. `~lowercase-string` narrows `String` to `non-lowercase-string` instead of `Difference[String, lowercase-string]`.
- 908eb08 — **F**: `literal-string` and `non-empty-literal-string` carriers; `ExpressionTyper` lifts an interpolated string to `literal-string` when every part is literal-bearing.
- 8951c1d — **C1**: `Store#fetch_or_compute` gains `serialize:` / `deserialize:` callable kwargs. Defaults to `Marshal.dump` / `Marshal.load`. Custom serialisers must round-trip; deserialiser exceptions become cache misses.
- 9b50e2b — **B**: `Rigor::Cache::RbsClassAncestorTable` (`Hash<String, Array<String>>`). `RbsHierarchy#ancestor_names` consults the cached table; `class_ordering` benefits transitively.
- c601f40 — **A**: `Rigor::Cache::RbsClassTypeParamNames` (`Hash<String, Array<Symbol>>`). `RbsLoader#class_type_param_names` consults the cached table.
- d662d4a — **E follow-up**: registers `uppercase ↔ not_uppercase` and `numeric ↔ not_numeric` pairs alongside `non-uppercase-string` and `non-numeric-string` carriers.
- 5600efc — **F follow-up**: `LiteralStringFolding` dispatcher tier between ConstantFolding and ShapeDispatch. `String#+` and `String#*` lift to `literal-string` when every operand is itself literal-bearing.
- 8f7c32c — **C2**: `Rigor::Cache::RbsEnvironment` caches the full `RBS::Environment` via the C1 callable surface. Pulls in `lib/rigor/cache/rbs_environment_marshal_patch.rb` — a minimal `_dump` / `_load` patch on `RBS::Location` so the env round-trips through Marshal. Biggest cold-start win in the cluster.

Deferred from v0.0.10 (carry forward):

- **Per-method `Reflection` caches** (`instance_method_definition`, `singleton_method_definition`). Now feasible since the C2 patch makes every RBS-native value Marshal-clean.
- **Wire `FlowContribution` bundles through internal narrowing.** Internal-only refactor; no user-visible behaviour change.
- **`literal-string` through `<<` mutation.** Requires a mutation-effect surface the dispatcher does not currently expose.
- **`decimal-int-string` / `octal-int-string` / `hex-int-string` paired complements.** Complement domains are too vague to warrant separate carriers in practice.

## v0.1.0 — Long Horizon (architecture commitments deferred)

Theme: **infrastructure**. v0.1.0 reserves two cross-cutting machinery surfaces that should not be retro-fitted later:

- **Caches.** A persistent on-disk cache for parsed RBS environments, scope indexes, and catalog data so warm runs are fast.
- **Plugin API (ADR-2).** The capability-role / fact-contribution / mutation-summary surface plugin authors will attach to.

These are explicitly out of scope for v0.0.x. The pre-v0.1.0 work is the type-language and inference-engine surface that the plugin API has to be designed against; v0.0.3 → v0.0.7 closed the substrate gaps that ADR-2 would otherwise stumble on.

Pre-v0.1.0 surfaces that can land independently as v0.0.x dot releases (see [`docs/design/20260505-v0.1.0-readiness.md`](design/20260505-v0.1.0-readiness.md) for the full breakdown):

- **Public-API declaration of `Rigor::Scope`, `Rigor::Type`, `Rigor::Environment`** — namespace policy + drift tests. No new code, just contract declaration.
- **Reflection facade** — a unified `Rigor::Reflection` read-side over `ClassRegistry` + `RbsLoader` + `Builtins::*_CATALOG`. Highest-leverage pre-v0.1.0 slice; every plugin protocol that asks "what does class X look like?" needs this.
- **Cache slice taxonomy** — design doc landed at [`docs/design/20260505-cache-slice-taxonomy.md`](design/20260505-cache-slice-taxonomy.md). Fixes the per-slot entry shapes (`FileEntry`, `GemEntry`, `PluginEntry`, `ConfigEntry`), comparator semantics, composition rules, cache-key derivation, granularity guidance, and the schema-versioning policy. The persistence layer it describes ships in v0.1.0; the design doc is the prerequisite contract.
- **Flow-contribution bundle struct** — a `Rigor::FlowContribution` with the eight ADR-2 slots (`return_type`, `truthy_facts`, `falsey_facts`, `post_return_facts`, `mutations`, `invalidations`, `exceptional`, `role_conformance`). Internal effect structs convert into bundles at the boundary.
- **Diagnostic provenance prefix** — `Diagnostic` gains a `source_family` field; formatter publishes `plugin.<id>.<rule>` style identifiers.

These do not block v0.0.x release cadence; they are the operational milestones that make v0.1.0 a finite assembly job rather than an open architectural exercise.
