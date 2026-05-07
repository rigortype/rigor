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

## v0.0.8 — Released 2026-05-04

Theme: **first cache-related code slice**. Landed the persistence layer the v0.0.7 cache slice taxonomy design doc ([`docs/design/20260505-cache-slice-taxonomy.md`](design/20260505-cache-slice-taxonomy.md)) commits to, plus a Marshal-clean producer wired through it end-to-end. Backend per [ADR-6](adr/6-cache-persistence-backend.md): a sharded directory of binary entries written through a custom canonical format, zero new gem dependencies.

Slices (in commit order):

1. **`Rigor::Cache::Descriptor` value object.** The taxonomy doc's typed-slot schema (`FileEntry`, `GemEntry`, `PluginEntry`, `ConfigEntry`); composition (`union-by-key`, stricter-comparator-wins for `files`, `Conflict` on disagreement); canonical serialisation; SHA-256 cache-key derivation. Pure value object, spec-tested in isolation.
2. **`Rigor::Cache::Store` filesystem backend.** `<root>/<producer-id>/<2-prefix>/<62-suffix>.entry` layout; `"RIGOR\x00\x01"` magic + varint-prefixed descriptor + value + trailing SHA-256 file format; rename-into-place atomicity with `flock(LOCK_EX)` on the destination; schema-version marker at `<root>/schema_version.txt` (mismatch wipes the directory). Read failures (missing, short, bad magic, bad checksum, malformed varint, unmarshal-able) silently fall through to a cache miss. Producer ids constrained to `[a-z][a-z0-9._-]*` for filesystem safety.
3. **First cached producer — `Rigor::Cache::RbsConstantTable`.** Caches a `Hash<String, Rigor::Type>` mapping every RBS-declared constant to its translated `Rigor::Type`. The slice plan originally named the RBS environment loader as the first producer; implementation discovered `RBS::Environment` is not Marshal-clean (transitive `RBS::Location` lacks `_dump_data`). [ADR-6 § 8](adr/6-cache-persistence-backend.md) documents the finding; the slice caches a post-translation artefact instead. Adds `RbsLoader#constant_names` so the producer can enumerate constants through the public surface.
4. **`rigor check --cache-stats` and `--clear-cache`.** `--cache-stats` prints an on-disk inventory at end-of-run (per-producer entry counts, total bytes, schema version) sourced from `Store.disk_inventory`. `--clear-cache` wipes `.rigor/cache` before the run. Per-run hit/miss counters deferred until production code wires the cache.
5. **Diagnostic source-family provenance.** `Rigor::Analysis::Diagnostic` gains `source_family:` (default `:builtin`) and `qualified_rule` (`"#{source_family}.#{rule}"` for non-default families). JSON output carries both `source_family` and the bare `rule` side-by-side. Prepares ADR-2's plugin-observability story without committing to the plugin API itself.

## v0.0.9 — Released 2026-05-05

Per the single-digit version-component policy (next release after `0.0.9` is `0.1.0`, not `0.0.10`), every pre-`0.1.0` slice continues to land inside `0.0.9` until the user authorises a release. The cluster combines the original "wire the cache into `rigor check`" slate with the cache-surface completion and three pieces of type-language work (FlowContribution producer wiring, paired-complement narrowing for Refined predicates, literal-string flow tracking through interpolation and concat).

Commits in chronological order:

- 9378df2 — **A1**: `Analysis::Runner.cache_store` surface + `rigor check --no-cache`. Runner defaults to a `Cache::Store` rooted at `.rigor/cache`; the CLI flag threads `nil` through to disable.
- ee021a2 — **A2**: `RbsLoader#constant_type` routes through `RbsConstantTable` when `cache_store` is set; `Environment.for_project(cache_store:)` plumbs the Store down. First end-to-end cold/warm-start gap.
- 1407225 — **A3**: `Cache::Store#stats` (in-process hits / misses / writes counters); `rigor check --cache-stats` adds a "this run:" section alongside the disk inventory.
- e764565 — **A4**: `Reflection.constant_type_for` confirmed cached end-to-end; "Constant-lookup path under `cache_store`" docs added.
- c48f05f — **B**: `Rigor::FlowContribution` bundle struct (8 content slots + `Provenance`). Public read shape per ADR-2 § "Flow Contribution Bundle"; element-list flattening deferred to v0.1.0 alongside the contribution merger.
- 8a94e7a — **C**: `Rigor::Cache::RbsKnownClassNames` (`Set<String>`) + `Rigor::Cache::RbsDescriptor` shared builder; `RbsLoader#class_known?` consults the cached set.
- 41aec51 — **D**: `Rigor::RbsExtended.read_flow_contribution(method_def)` rolls every recognised directive on a single method into a `Rigor::FlowContribution` bundle (`:rbs_extended` source family). Internal narrowing keeps the typed Data carriers.
- 3ae65e2 — **E**: paired-complement registry on `Type::Refined` (`COMPLEMENT_PAIRS`). First pair: `lowercase ↔ not_lowercase`. `~lowercase-string` narrows `String` to `non-lowercase-string` instead of `Difference[String, lowercase-string]`.
- 908eb08 — **F**: `literal-string` and `non-empty-literal-string` carriers; `ExpressionTyper` lifts an interpolated string to `literal-string` when every part is literal-bearing.
- 8951c1d — **C1**: `Store#fetch_or_compute(serialize:, deserialize:)` callable surface. Defaults to `Marshal.dump` / `Marshal.load`. Pair must round-trip; deserialiser exceptions become cache misses.
- 9b50e2b — **B (cache producer)**: `Rigor::Cache::RbsClassAncestorTable` (`Hash<String, Array<String>>`). `RbsHierarchy#ancestor_names` consults the cached table; `class_ordering` benefits transitively.
- c601f40 — **A (cache producer)**: `Rigor::Cache::RbsClassTypeParamNames` (`Hash<String, Array<Symbol>>`). `RbsLoader#class_type_param_names` consults the cached table.
- d662d4a — **E follow-up**: registers `uppercase ↔ not_uppercase` and `numeric ↔ not_numeric` pairs alongside `non-uppercase-string` and `non-numeric-string` carriers.
- 5600efc — **F follow-up**: `LiteralStringFolding` dispatcher tier between ConstantFolding and ShapeDispatch. `String#+` and `String#*` lift to `literal-string` when every operand is itself literal-bearing.
- 8f7c32c — **C2**: `Rigor::Cache::RbsEnvironment` caches the full `RBS::Environment` via the C1 callable surface. Adds `lib/rigor/cache/rbs_environment_marshal_patch.rb` — a minimal `_dump` / `_load` patch on `RBS::Location` so the env round-trips through Marshal. Biggest cold-start win in the cluster.

## v0.1.0 — Version-bumped on `master` (release pending)

Theme: **first plugin contract**. ADR-2 § "Extension API" fixes the design surface; v0.1.0 ships the implementation. The pre-v0.1.0 substrate landed in v0.0.3 → v0.0.9 — type vocabulary, inference engine, persistent cache layer wired through `rigor check`, `Rigor::Reflection` facade, `Rigor::FlowContribution` bundle, public-API drift pins (`Scope` / `Environment` / `Type::Combinator` / `Reflection`), `Diagnostic#source_family`, RBS::Extended directive plumbing — leaving v0.1.0 as a finite assembly job rather than an open architectural exercise.

The public surface plugins attach to is documented in [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) and pinned by `spec/rigor/public_api_drift_spec.rb`. Slices that extend a pinned namespace update the drift spec in the same commit.

Slice plan — **all six landed (unreleased on `master`)**:

1. **Plugin registration / loading.** ✅ `Rigor::Plugin` namespace (Base / Manifest / Services / Registry / Loader / LoadError) per ADR-2 § "Registration, Configuration, and Caching". Spec [`docs/internal-spec/plugin.md`](internal-spec/plugin.md).
2. **Plugin trust / I/O policy.** ✅ `Plugin::TrustPolicy` + `Plugin::IoBoundary` + `Plugin::AccessDeniedError` + `.rigor.yml` `plugins_io:` section. Spec [`docs/internal-spec/plugin-trust.md`](internal-spec/plugin-trust.md).
3. **Plugin contribution merger.** ✅ `FlowContribution::Merger` + `Element` flattening + `MergeResult` + `Conflict`. Spec [`docs/internal-spec/flow-contribution-merger.md`](internal-spec/flow-contribution-merger.md).
4. **FlowContribution wiring through internal narrowing.** ✅ Slice 4a (substrate — `Fact` value object + carrier translations) + slice 4b (three consumer call sites — `analyse_rbs_extended_contribution`, post-return assertion, return-type override). Working decisions in [ADR-7 § "Slice 4"](adr/7-v0.1.0-slice-decisions.md).
5. **Plugin diagnostic emission protocol.** ✅ `Plugin::Base#diagnostics_for_file` per-file hook + `Analysis::Runner` auto-stamps `source_family: "plugin.<id>"` + `Conflict#to_diagnostic`.
6. **Plugin-side cache producers.** ✅ `Plugin::Base.producer` DSL + `Plugin::Base#cache_for` callable + auto-prefixed `plugin.<manifest.id>.` ids + auto-assembled `Cache::Descriptor`. Spec [`docs/internal-spec/plugin-cache-producers.md`](internal-spec/plugin-cache-producers.md).

V0.1.0 polish work that landed alongside the six slices:

- **Seven worked plugin examples** under [`examples/`](../examples/README.md) — `rigor-deprecations`, `rigor-lisp-eval`, `rigor-pattern`, `rigor-routes`, `rigor-statesman`, `rigor-units`, plus `rigor-activerecord` (the most architecturally complete: DSL interpretation + multi-file `IoBoundary` + chained cache producers + two-pass discover-then-validate). 67 integration examples across `spec/integration/examples/`.
- **Nine-chapter end-user handbook** under [`docs/handbook/`](handbook/README.md).
- **Two precision improvements** — named-capture regex narrowing through `if /(?<x>...)/ =~ str`; `;`-prefixed block-local `Constant[nil]` shadow.
- **Per-method Reflection caches** (carry-over from v0.0.9). `Rigor::Cache::RbsInstanceDefinitions` / `Rigor::Cache::RbsSingletonDefinitions` per-class producers landed; the v0.0.9 fail-soft `NameError` regression diagnosed and fixed (missing `require_relative "descriptor"` in two cache files).

`Rigor::VERSION` was bumped to `"0.1.0"` and `CHANGELOG.md` reorganised into the `[0.1.0] - 2026-05-07` section in commit `6170832`. Per the no-autonomous-version-bump rule in [`AGENTS.md`](../AGENTS.md), `bundle exec rake release` (which tags `v0.1.0`, pushes to origin, and publishes to RubyGems) waits for explicit user authorisation. Follow [`.codex/skills/rigor-release-prep/SKILL.md`](../.codex/skills/rigor-release-prep/SKILL.md) when the cut is authorised.

Items deferred past v0.1.0 are tracked in the [v0.1.1 section](#v011--planned) below (Tracks 1–4 plus the v0.1.1 "Out of scope" list at the end). Items still queued past v0.1.1 (LSP / long-running daemon, LRU eviction, cross-machine cache sharing, ObjectSpace / URI / Kernel catalog imports, Pathname / URI delegation rules, `rigor:v1:conforms-to`, broader CheckRules rule families) are listed there.

## v0.1.1 — Planned

Theme: **deepen the literal-string narrowing surface, ship the cross-plugin API, and stabilise the plugin authoring DX**. v0.1.0 closed the plugin contract (six slices) and shipped seven worked plugin examples; v0.1.1 extends the substrate in two directions and cleans up persistent maintenance items.

### Track 1 — Literal-string / refinement narrowing depth (theme)

1. ✅ **Regex pattern → refinement-name recogniser** — landed unreleased. `Rigor::Builtins::RegexRefinement` (a curated table of canonical sub-patterns: `\d+`, `\d{N}`, `\d{N,M}`, `\h+`, `[0-9a-fA-F]+`, `[0-9a-f]+`, `[0-9A-F]+`, `[0-7]+`, `[a-z]+`, `[A-Z]+`, `[[:digit:]]+`, all admitting `+` / `{n}` / `{n,m}` quantifiers with `n >= 1`) is consulted from `Inference::Narrowing.analyse_match_write` so the truthy branch of `if /(?<year>\d+)/ =~ str` narrows `year` to `decimal-int-string` instead of plain `String`. Bodies that admit zero-length matches (`*`, `?`, `{0,N}`) or sit outside the audited table fall back to plain `String`. Whole-regex anchored forms (`/\A\d+\z/.match?(str)` narrowing `str` itself) are deferred — the v0.1.1 hook is named-capture only, since anchored-whole-regex narrowing requires a separate consumer site (probably `String#match?` predicate narrowing) that is not yet wired.

2. ✅ **`numeric-string` / `decimal-int-string` propagation through Integer-conversion predicates** — landed unreleased. Two consumer sites tightened:
   - **2a — `String#to_i` / `#to_int`.** `MethodDispatcher::ShapeDispatch.dispatch_refined` recognises `decimal-int-string` (`/\A\d+\z/`) and `numeric-string` (Rigor's numeric-string predicate) receivers and projects `to_i` / `to_int` (no args) to `non-negative-int`. Both refinements describe digit-only ASCII strings, so the parse is total over the carrier domain.
   - **2b — `Kernel#Integer`.** `MethodDispatcher::KernelDispatch.try_integer_from_refinement` mirrors the same rule for the `Kernel#Integer(s)` (single-arg) form.
   - End-to-end, `if /(?<year>\d+)/ =~ str; year.to_i; end` and `… Integer(year); end` both fold to `non-negative-int`. `Float(s)` / `s.to_f` are deferred — Rigor has no FloatRange carrier to express tighter Float precision than the RBS baseline.

3. ✅ **`self`-narrowing in `predicate-if-*` / `assert-if-*` / `assert` directives** — landed unreleased. Four receiver shapes now narrow self-targeted facts: `LocalVariableReadNode` (already worked in v0.1.0), `InstanceVariableReadNode` (new — narrows the ivar via `Scope#with_ivar`), `Prism::SelfNode` (new — narrows `scope.self_type`), and the implicit-self call (nil receiver, new — narrows `scope.self_type`; `Inference::Narrowing#analyse_call` was relaxed so nil-receiver shapes can flow into the RBS::Extended path). Same handling for `assert self is T` post-return facts in `StatementEvaluator#apply_self_post_return_fact`. Spec at [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) updated.

4. ✅ **Additional `String` predicate narrowing** — landed unreleased as a FactStore-based flow fact (the lightweight option). `Inference::Narrowing#analyse_string_predicate` matches `s.start_with?("foo")`, `s.end_with?(...)`, `s.include?(...)` against a `Prism::LocalVariableReadNode` receiver and a `Constant<String>` needle, attaching a `bucket: :relational` Fact with `predicate: <method_name>`, `payload: <needle>`, polarity `:positive` on the truthy edge and `:negative` on the falsey edge. No type narrowing — Rigor has no "starts-with-X" refinement carrier today, so the receiver's type stays unchanged on both edges. The lightweight form lets downstream consumers (a future plugin's `prepare(services)` hook, internal post-narrowing rules) read the predicate semantics; if a heavier carrier-based form turns out to be needed, it can be added later without breaking the fact contract.

5. ✅ **`literal-string` propagation through additional methods** — three sub-slices landed unreleased.
   - **5a — `String#strip` / `#lstrip` / `#rstrip` / `#chomp` (no-arg) / `#chop` / `#scrub` (no-arg).** `LITERAL_PRESERVING_METHODS` in `LiteralStringFolding`. Each strips a known character subset from the ends (or replaces invalid bytes), so a literal-bearing receiver stays literal-bearing. `non-empty-literal-string` collapses to plain `literal-string` because `"   ".strip == ""`.
   - **5b — `Integer#to_s(base)` on non-negative `IntegerRange`.** `MethodDispatcher::ShapeDispatch.dispatch_integer_range` recognises an `IntegerRange` receiver with `lower >= 0` and lifts `to_s` (no args, default base 10) → `decimal-int-string`, `to_s(8)` → `octal-int-string`, `to_s(16)` → `hex-int-string`. Bases without a digit-only refinement (2, 36, …) and signed ranges (whose `to_s` could carry a leading `-`) decline.
   - **5c — `String#center` / `#ljust` / `#rjust`.** `LiteralStringFolding.fold_width_pad`. Width arg MUST be Integer-typed; optional padding arg MUST be literal-bearing (the default-padding form passes through). The result is `literal-string`.
   - **`Numeric#to_s` (no args)** is not implemented; the bullet doesn't fit cleanly because `Float#to_s` produces a `.`-bearing string that no Rigor refinement currently captures, and `Integer#to_s` on signed ranges leaks a `-` sign. The non-negative-Integer case is covered by 5b.

### Track 2 — Cross-plugin API + return-type contributions (parallel)

6. ✅ **ADR-9 cross-plugin API — slices 1 → 5** all landed unreleased.
   - **Slice 1** — `Plugin::FactStore` value object (`#publish` / `#read` / `#published?` / `#each_fact`, plus the `Fact = Data.define(:plugin_id, :name, :value)` shape and `Conflict` exception). Thread-safe; canonicalises `plugin_id` to String and `name` to Symbol.
   - **Slice 2** — `Plugin::Services#fact_store` accessor. A fresh `FactStore` is constructed per Services when none is supplied; the runner threads its own per-run instance through.
   - **Slice 3** — `Plugin::Base#prepare(services)` default-no-op hook. `Analysis::Runner.run` invokes `#prepare` on every loaded plugin once per run, after `#init` and before per-file iteration; failures isolate as `:plugin_loader runtime-error` diagnostics.
   - **Slice 4** — `manifest(produces: [...])` / `manifest(consumes: [{plugin_id:, name:, optional:}])` declarations + the `Manifest::Consumption` Data shape. The loader doesn't yet enforce them in slice 4.
   - **Slice 5** — `Plugin::Loader.load` topologically sorts plugins by `consumes:` (configuration-order tie-break), emits `Plugin::LoadError(reason: :"missing-producer")` when a non-optional consume names a `(plugin_id, name)` no loaded plugin produces, and `Plugin::LoadError(reason: :"dependency-cycle")` when consumes form a cycle. `Plugin::LoadError` gains an optional `reason:` field for the new codes. Topo sort skips entirely when no loaded plugin declares a `consumes:` entry, preserving v0.1.0 observable behaviour for projects that don't opt into the cross-plugin API.
   - Tier 2 Rails plugins (`rigor-actionpack` Phase 1, `rigor-factorybot`) are now unblocked.

7. ✅ **Plugin return-type contributions slice 1** — landed unreleased. New `Plugin::Base#flow_contribution_for(call_node:, scope:)` default-no-op hook returns a `Rigor::FlowContribution`. `MethodDispatcher.dispatch` gains optional `call_node:` / `scope:` keywords; when both are present and the scope's environment carries a non-empty `Plugin::Registry`, a new dispatcher tier between precision tiers and `RbsDispatch` walks every plugin's hook, merges contributions via `FlowContribution::Merger`, and uses the merged `return_type`. `Environment#plugin_registry` new optional reader; `Analysis::Runner` threads its per-run registry through `Environment.for_project(plugin_registry:)`. Plugin-side raises in `flow_contribution_for` are silently dropped per-call so the dispatch chain continues. Migrating the seven example plugins from "info diagnostic only" to "narrowed return type" is deferred — slice 7 lands the substrate; per-plugin migration is incremental follow-up.

### Track 3 — Plugin authoring DX (parallel)

8. **Plugin spec helper module extraction.** ✅ **landed (commit `ce64bb6`).** `Rigor::IntegrationSupport::PluginHelpers` extracted to `spec/integration/examples/support/plugin_helpers.rb`; seven plugin specs migrated; `rigor-plugin-author` SKILL Phase 6 updated with the slimmed boilerplate.

9. ✅ **Demo cache directory handling** — landed unreleased as the explicit-config form (no "demo mode" concept in the CLI). Each `examples/rigor-*/demo/.rigor.yml` sets `cache.path: tmp/.rigor/cache`; each demo carries a `/tmp/`-only `.gitignore` so the cache stays out of git automatically. `Rigor::CLI#run_check` previously hardcoded `cache_root = ".rigor/cache"` and ignored `.rigor.yml`'s `cache.path:` setting; the CLI now consults `configuration.cache_path` so demo configs actually take effect. The `tmp/`-anchored layout matters for the eventual `git subtree split` per the `rigor-plugin-author` SKILL — discipline survives the split without depending on the parent repo's `.gitignore`. SKILL Phase 5 template updated.

10. ✅ **Examples RuboCop relaxation** — landed unreleased. `.rubocop.yml` removed the blanket `examples/**/*` exclusion and added a documented relaxation block: `Metrics/*` and `Naming/FileName` disabled (kebab-case file names are part of the gem-id convention; mid-sized example methods keep illustrations end-to-end legible), `Style/TopLevelMethodDefinition` and `Style/OneClassPerFile` relaxed for `examples/*/demo/**/*` (demos run as scripts and pack a small ad-hoc class hierarchy into one file), `Lint/StructNewOverride` / `Layout/LineLength` / `Lint/DuplicateBranch` / `Style/EmptyElse` excluded for `examples/**/*` (deliberate domain words like the `:method` Struct member, message strings that exceed 120 cols for readability, multi-arm switches that share a body for documentation, comment-bearing trailing `else` extension points). Autocorrect ran on the touched files (`require "set"` removal, block-pass shorthand `&`, redundant Metrics suppressions cleared, etc.). RuboCop now inspects 262 files / 0 offenses (was 210).

### Track 4 — Maintenance (any v0.1.x release)

11. ✅ **Three `lib/` sig drifts** — landed unreleased. `Trinary#negate` collapsed the `:maybe` arm into `else` so the case is exhaustive without changing semantics (the constructor invariant `value ∈ [:yes, :no, :maybe]` already guaranteed the third path). `IntegerRange#lower` / `IntegerRange#upper` rewrote the `is_a?(Symbol) ? ∞ : m` ternary as an `is_a?(Integer)` early return, so the analyzer's narrowing path produces `Integer | Float` directly without leaking the Symbol branch. `bundle exec exe/rigor check lib` now reports `No diagnostics`. Categories A-1 / A-2 in [`docs/notes/20260503-steep-cross-check-triage.md`](notes/20260503-steep-cross-check-triage.md) closed.

12. ✅ **`spec/rigor/source/node_locator_spec.rb:82` — `String#index + 1` unguarded** — no longer surfaces as a diagnostic. Constant-folding on `Constant<String>#index(Constant<String>)` (added in v0.0.7's "Constant carriers expanded" wave) produces a `Constant<Integer>` for `source.index("\"")`, so the `+ 1` receiver is a known `Integer` and `possible-nil-receiver` does not fire. The maintenance item is moot; the spec line is unchanged.

13. ✅ **`numeric.yml` `Integer#ceildiv` `unknown` entry** — landed unreleased. `tool/extract_builtin_catalog.rb` `classify_purity` now classifies `body_kind: composed` prelude bodies as `dispatch` instead of `unknown`. `composed` means the body is neither `Primitive.attr!(:leaf)`, a literal return, nor `self`, so it invariably ends in a Ruby method dispatch (and Ruby methods are all user-overridable). Both `unknown` and `dispatch` are non-foldable per `FOLDABLE_PURITIES`, so folding behaviour is unchanged; the rename is purely catalog self-documentation cleanup. Catalogs regenerated via `make extract-builtin-catalogs`.

Out of scope for v0.1.1 (deferred to v0.1.2 or beyond):

- **New CheckRules rule families.** `flow.unreachable-branch`, `flow.dead-assignment`, `flow.always-truthy-condition`, `def.ivar-write-mismatch`, `def.method-visibility-mismatch`, plus `def.return-type-mismatch` for type-carrier predicates. Each needs careful false-positive triage.
- **C-body classifier wider transitive mutator scan.** Long-deferred catalog-extractor work that needs to track `str_modifiable` / `time_modify` / similar helpers without over-flagging legitimate non-mutators (the `Array#to_a` regression that gated the v0.0.5 fix).
- **`Data.define` override-aware initializer dispatch.** Block-body `def initialize(...)` as the canonical sig for `Const.new`.
- **`Plugin::IoBoundary#open_url` allowlist.** Currently always raises; relaxed network-policy lands when a concrete plugin needs it.
- **`rigor:v1:conforms-to` directive.** Needs a real structural-conformance checker.
- **DX tooling track.** `rigor explain <rule-id>` / `rigor diff <baseline>` / `# rigor:disable-file <rule>` / `.rigor.yml` JSON schema for editor autocomplete. Separate user-facing surface; queue for v0.1.2.
- **LSP / long-running daemon mode.** Requires concurrent multi-process safety beyond the per-file `flock` model. Increasingly relevant as the plugin ecosystem grows, but still substantial.
- **Cache eviction / LRU / size cap.** Cache stays unbounded; users run `--clear-cache` if needed.
- **Cross-machine cache sharing.**
- **ObjectSpace / URI / Kernel catalog imports.** ObjectSpace needs a singleton-module dispatch path the catalog tier does not yet provide. URI is a pure-Ruby stdlib gem with no C surface; Kernel methods scatter across 20+ C files with no single Init function. Both need hand-rolled or custom-scaffold approaches.
- **Pathname / URI delegation rules.** Wider refactor (Pathname facade routing through File projections).
- **Lightweight HKT / type-level type computation.** Conditional and indexed-access types per [`docs/type-specification/rigor-extensions.md`](type-specification/rigor-extensions.md) rows 22 / 51. Sketched in `examples/rigor-lisp-eval/demo/sig/lisp.rbs` and `examples/rigor-units/demo/sig/units.rbs`. Larger surface; not a single-slice item.
- **Interface-strictness on overload selection.** Surfaced during v0.1.1 self-analysis: `Array#[](Range) -> Array[Elem]?` loses to `Array#[](int) -> Elem` because the RBS `int` alias expands to `Integer | _ToInt` and Rigor translates the `_ToInt` interface to `Dynamic[top]` (which gradually accepts any type — including a Range). Symptom: `arr = Array<String>; arr[0..i]` returns `String` instead of `Array[String]?`. Suppressed at the one site in `tool/extract_builtin_catalog.rb` for v0.1.1 via `# rigor:disable call.undefined-method`. Real fix needs the overload selector to demote matches that depend on `Dynamic[top]` (from interface translation) so a non-interface match wins when both are arity-compatible.

## v0.1.2 — Planned

Theme: **migrate the example plugin family to the v0.1.1 `flow_contribution_for` substrate.** v0.1.1 landed the cross-plugin API and the per-call return-type contribution tier; v0.1.2 puts that substrate to work — the four example plugins whose runtime returns a typeable value migrate from "info diagnostic only" to "narrowed return type", so chained calls resolve through the analyzer's normal dispatch instead of the RBS-level `untyped` envelope. The diagnostic trace stays — both channels run from the same interpretation.

### Track 1 — Example plugin return-type migration

1. ✅ **`rigor-lisp-eval`** — `Lisp.eval(literal)` narrows to the carrier the literal interpreter produces (`Nominal[Integer]`, `Nominal[Float]`, `Union[Constant[true], Constant[false]]`, or unions across `:if` branches). Type-error and unknown-expression cases stay at the RBS untyped envelope so the existing `:error` / silent fall-through behaviour is unchanged.

2. ✅ **`rigor-pattern`** — `validate(:name, value)` narrows to the value argument's type on a successful match (typically `Constant<String>` after Rigor's literal-string folding). Mismatches keep the `literal-mismatch` diagnostic and stay untyped — propagating `bot` would silence the diagnostic-driven feedback the README centres on.

3. ✅ **`rigor-units`** — Dimensional arithmetic / chained constructors / queries narrow through the existing `MethodTable` dispatch (`Distance / Time -> Speed`, `Distance + Distance -> Distance`, `Speed * Time -> Distance`, `.in_<unit>` queries return `Float`, etc.). `dimension_for_type` folds Rigor's nominal carriers back into the table's dimension Symbols and `DIMENSION_NOMINALS` translates the result back.

4. ✅ **`rigor-activerecord`** — `Model.find(id)` narrows to `Nominal[Model]`; `Model.find_by(...)` narrows to `Nominal[Model] | nil`. `where` / `find_or_*` are intentionally deferred (relations need a richer carrier than the current Nominal/Tuple shapes carry).

The other three example plugins (`rigor-deprecations`, `rigor-statesman`, `rigor-routes`) stay diagnostic-only by design: deprecation reports and state-machine declarations have no return-type fit, and route helpers are already RBS-expressible.

### Plugin authoring DX

5. ✅ **`spec/integration/examples/support/plugin_helpers.rb` accepts `signature_paths:` keyword.** Lets a plugin integration spec materialise an RBS sig file under the per-test tmpdir and thread its directory through `Configuration#signature_paths`. The new narrowing tests use this to provide minimal sigs for user-defined classes (`User` for `rigor-activerecord`, the `Distance / Time / Speed` family for `rigor-units`) so `call.undefined-method` can fire on them — the rule's `rbs_class_known?` gate would otherwise silence the diagnostic.

### Out of scope for v0.1.2 (deferred to v0.1.3 or beyond)

The full "Out of scope for v0.1.1" list above applies — interface-strictness on overload selection, new `flow.*` / `def.*` rule families, `Data.define` initializer dispatch, `Plugin::IoBoundary#open_url`, `rigor:v1:conforms-to`, DX tooling track, LSP daemon, cache LRU, ObjectSpace / URI / Kernel catalog imports, Pathname / URI delegation, lightweight HKT.

## Rails ecosystem plugins (running track, parallel to v0.1.x core work)

The full roadmap is in [`docs/design/20260508-rails-plugins-roadmap.md`](design/20260508-rails-plugins-roadmap.md). Summary of the running track:

**Already landed (unreleased on `master`):**

- [`rigor-activerecord`](../examples/rigor-activerecord/) — schema + finders + columns. The seventh worked plugin example and the most architecturally complete (DSL interpretation + multi-file IoBoundary + chained cache producers + two-pass discover-then-validate).

**Tier 1 (current API, no analyser-side change required) — author next:**

- `rigor-rails-routes` — real `config/routes.rb` DSL → `*_path` / `*_url` validation.
- `rigor-rails-i18n` — `config/locales/*.yml` → `t('key.path')` validation.
- `rigor-actionmailer` — Mailer methods + view template existence.
- `rigor-activejob` — Job `perform` arity.

**Tier 2 (needs the cross-plugin API per [ADR-9](adr/9-cross-plugin-api.md)):**

- `rigor-actionpack` Phase 1 (strong parameters → AR column validation).
- `rigor-factorybot` (factory attributes → AR column validation).
- `rigor-actionpack` Phase 2-4 (filter chains, render targets, route-helper consumption).
- `rigor-activerecord` extensions (associations, enums, scopes, validations, callbacks — landed as 0.2.0+ minor bumps in the existing gem rather than separate gems).

**Tier 3 (specialised, author when there is concrete user demand):**

- `rigor-rspec`, `rigor-pundit`, `rigor-sidekiq`, `rigor-graphql`, `rigor-activestorage`, `rigor-actioncable`.

Each plugin is staged in `examples/rigor-<id>/` per the [`rigor-plugin-author`](../.codex/skills/rigor-plugin-author/SKILL.md) SKILL discipline and extracted via `git subtree split` once its contract is stable. The eventual `rigor-rails` meta-gem will declare the Tier 1+2 plugins as gem dependencies so a single Gemfile line opts the user into the whole stack.

[ADR-9](adr/9-cross-plugin-api.md) is queued for v0.1.x — Tier 1 does not block on it; Tier 2 does. Slicing per ADR-9 § "Implementation slicing" allows partial landings.
