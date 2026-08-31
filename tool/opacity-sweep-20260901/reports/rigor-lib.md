# rigor-lib — opacity attribution (2026-09-01 corpus sweep)

Target: Rigor's own `lib` (`/Users/megurine/repo/ruby/rigor`, config `.rigor.dist.yml`, paths=`lib`).
All commands via the Nix Flake; repo never modified; probes are driver-side
(`probe_attrib.rb`, `probe_fullseed.rb`, `probe_else_census.rb`, `probe_fallback_census.rb`,
`probe_case.rb`, minimal repros `t_kwargs.rb` / `t_prism.rb` / `t_modfunc.rb`, all in this scratchpad).
Prior audit consumed, not re-derived: `docs/notes/20260831-self-check-type-coverage-audit.md`
(parameters 27.8% of opacity = ADR-67 closed; opaque calls ~91% propagation; PR #508 landed).

## Numbers

| metric | value |
| --- | --- |
| files | 430 (0 parse errors) |
| typed expressions | 167,079 |
| precision (official `rigor coverage lib`) | 58.9% (precise 98,460 / dynamic 68,619) |
| precision (probe, lens-equivalent seed) | 0.5894 |
| precision (product-equivalent full seed) | **0.5927** (+0.33pp vs lens) |
| protection (`--protection`) | **0.4573** (protected 14,552 / unprotected 17,268; lower_bound_typed 2,659) |
| tractability | engine_gap 11,024 / add_rbs 371 |
| cause_site_counts | none 5,873; inferred_return_untyped 9,789; **unsupported_syntax 1,234 (7.1%)**; explicit_untyped 371; analyzer_budget_cutoff 1 |

Opaque split (68,609 sites = dynamic_top 68,339 + top 270, lens seed):

| bucket | count | share |
| --- | --- | --- |
| local reads | 28,822 | 42.0% — def_param 17,329 / assigned_local 7,766 / block_param 3,727 |
| calls | 24,608 | 35.9% — receiver dynamic_top 16,922 / implicit_self 4,220 / **receiver precise 3,466** |
| ivar reads | 2,111 | 3.1% |
| join/write mirrors (EmbeddedStatements 1,443, If 915, Or 802, And 685, LocalWrite 3,498, …) | ~8,000 | ~11.7% |

Named-receiver-but-opaque pairs: 1,121 pairs / 3,466 sites (lens), 1,063 / 3,330 (full seed) —
**2.1% of all opacity here**, consistent with the audit's ~9.8%-of-CallNodes sizing vs ~50% on Rails apps.

## Headline findings (new, beyond the 2026-08-31 audit)

1. **G — the precision lens misclassifies five of Rigor's own type classes as opaque.**
   `PrecisionScanner#classify` (`lib/rigor/inference/precision_scanner.rb:151-165`) has no branch for
   `Type::DataClass`, `Type::DataInstance`, `Type::StructClass`, `Type::StructInstance`,
   `Type::BoundMethod`; its `else` returns `:dynamic_top`. Census: **810 sites** under the
   product-equivalent seed (DataInstance 466, DataClass 297, StructInstance 27, StructClass 10,
   BoundMethod 10) are *precisely folded values counted as opaque* — the official `rigor coverage`
   number under-reports by ~0.4–0.5pp. Verified at `lib/rigor/analysis/rule_catalog.rb:84`: the type
   is a fully folded `Entry(id: non-empty-string, …)` `DataInstance`, tier reported dynamic_top.
   This affects both `singleton(Data)#define` (160 sites, #1 pair) and every `.new` on a Data/Struct
   subclass (`RuleCatalog::Entry#new`, 31 sites). Fix: classify these five as `:constant`/`:nominal`-grade.

2. **D — RBS type aliases and intersections translate to untyped, wholesale.**
   `lib/rigor/inference/rbs_type_translator.rb:67-68`: `RBS::Types::Alias => :translate_untyped`,
   `RBS::Types::Intersection => :translate_untyped`. Prism's RBS (loaded by default —
   `DEFAULT_LIBRARIES` includes `prism`) declares `attr_reader receiver: Prism::node?` with
   `type node = Node & _Node`, so every structural read of the AST answers `Dynamic[top]?` —
   empirically verified (`t_prism.rb`: narrowed `Prism::CallNode`, `.receiver` → `Dynamic[top]?`,
   while `.name` → `Symbol` proves simple attrs resolve). Cluster in the pair list:
   `Prism::CallNode#receiver` 57, `Prism::ConstantPathNode#parent` 20, `Prism::ArgumentsNode?#arguments`
   17, plus a long tail of prism attribute pairs — in a codebase that walks Prism nodes for a living.
   Fix direction: resolve aliases through the RBS environment (recursion-guarded expansion), and
   translate class-&-interface intersections by keeping the nominal member as the dispatch carrier
   (Rigor interfaces are structural; `Node & _Node` ≈ `Nominal[Prism::Node]`).

3. **D — any project method with an optional keyword parameter is never dispatched.**
   Minimal repro (`t_kwargs.rb`, same file, bare scope): `def self.with_kw(topic, mutating_selectors: {})`
   → callers answer `Dynamic[top]` whether or not the kwarg is passed; the positional twin resolves to
   the class. Same for instance methods: `def lookup(node, tracer: nil)` → `InstKw.new.lookup(n)` is
   Dynamic. Explains the stayed-opaque pairs `MethodCatalog.for_topic` (19),
   `Reflection.instance_method_definition` (14), `Scope#type_of` (14 — `tracer:` kwarg),
   `RbsTypeTranslator.translate` (12), and an unquantified slice of the 4,220 implicit-self sites.
   Fix direction: the def-node acceptance/arity check that gates inferred-return dispatch must accept
   optional kwargs (bind supplied ones, default the rest), instead of declining the call form.

4. **G/D-lite — an index-write expression takes the dispatch return, not the rvalue.**
   `h[k] = true` types `Dynamic[top]` (verified `t_kwargs.rb:37`) although Ruby's assignment
   expression value is the rvalue. Affects `{}#[]=` 66, `Hash[Dynamic,Dynamic]#[]=` 91, `Hash#[]=` 42,
   `Thread#[]=` 32 (~230 sites). Cheap sound fix: type `[]=`/index-write expressions as the rvalue type.

5. **Lens-vs-product artifact — the coverage lens still seeds a weaker scope than the check walk.**
   `CLI::CoverageScan.discovery_seeded_scope` (`lib/rigor/cli/coverage_scan.rb:58-76`) seeds only
   `discovered_classes` (#505's fix); the check walk seeds def-nodes, def-sources, superclasses,
   includes, visibilities, methods and Data/Struct layouts (`lib/rigor/analysis/runner.rb:1577-1604`).
   Re-running the attribution with the full tables: +0.33pp precision, and six pairs dissolve outright
   (~91 sites in the top-80): `ConstantPath.qualified_name` 37 + `qualified_name_or_nil` 13,
   `Options.add_config` 17, `FileDigest.hexdigest` 9, `SingletonFolding.constant_string` 8,
   `Incremental.invert` 7 — all cross-file `module_function`/singleton methods the product types fine
   (verified: `qualified_name` callers Dynamic under lens seed; body infers `String?`; same-file
   module_function repro resolves). The residual of audit Finding 1, one table deeper. On Rails-shaped
   corpora this artifact should be larger than +0.33pp (more cross-file dispatch).

## Case list (top pairs, full-seed counts; category / mechanism / example / fix)

| # | pair | sites | cat | mechanism | example |
| --- | --- | --- | --- | --- | --- |
| 1 | `singleton(Data)#define` | 160 | **G** | `Type::DataClass` falls to classify's `else` → counted dynamic_top; fold itself works (block form included) | lib/rigor/analysis/buffer_binding.rb:13 |
| 2 | `Type::Constant#value` | 147 | **A** | `attr_reader :value`; `@value = value` param-sourced in `initialize` (type/constant.rb:45-47); ADR-58 cannot type it, ADR-67 closed | lib/rigor/analysis/check_rules.rb:868 |
| 3 | `singleton(Type::Combinator)#union` | 124 | **A** | inferred return of `collapse_union(normalized_union_members(*types))` is genuinely input-dependent; params Dynamic (combinator.rb:374-383) | lib/rigor/analysis/check_rules.rb:2500 |
| 4 | `Hash#[]` (bare) | 97 | **C** | receiver narrowed to bare `Nominal[Hash]` by `is_a?(Hash)` over YAML data; no element type exists anywhere | lib/rigor/analysis/baseline.rb:105 |
| 5 | `Hash[Dynamic,Dynamic]#[]=` | 91 | **C** (+finding 4) | container of Dynamic; element source is params | lib/rigor/analysis/dependency_source_inference/builder.rb:60 |
| 6 | `Hash[Dynamic,Dynamic]#[]` | 76 | **C** | same | lib/rigor/analysis/baseline.rb:252 |
| 7 | `{}#[]=` | 66 | **D-lite** | index-write expression ignores rvalue (finding 4); `seen[subclass] = true` with Constant rvalue answers Dynamic | lib/rigor/analysis/check_rules.rb:1006 |
| 8 | `Prism::CallNode#receiver` | 57 | **D** | RBS alias+intersection → untyped (finding 2) | lib/rigor/analysis/check_rules.rb:1179 |
| 9 | `Hash[Dynamic,Dynamic]#fetch` | 55 | **C** | container of Dynamic | lib/rigor/analysis/runner/pool_coordinator.rb:401 |
| 10 | `Type::Union#members` | 46 | **A** | param-sourced attr_reader | lib/rigor/analysis/check_rules.rb:1414 |
| 11 | `Thread#[]` | 43 | **B** | RBS core: `def []: (interned) -> untyped` (references/rbs/core/thread.rbs:229) — upstream-declared untyped | lib/rigor/analysis/dependency_recorder.rb:96 |
| 12 | `Hash#[]=` | 42 | **C** (+finding 4) | bare Hash write | lib/rigor/analysis/check_rules.rb:491 |
| 13 | `Type::Nominal#class_name` | 42 | **A** | param-sourced attr_reader | lib/rigor/analysis/check_rules.rb:768 |
| 14 | `Type::Tuple#elements` | 41 | **A** | param-sourced attr_reader | lib/rigor/inference/acceptance.rb:702 |
| 15 | `Type::Singleton#class_name` | 33 | **A** | param-sourced attr_reader | lib/rigor/analysis/check_rules.rb:1713 |
| 16 | `Thread#[]=` | 32 | **B** | RBS `-> untyped` (thread.rbs:243) | lib/rigor/analysis/dependency_recorder.rb:98 |
| 17 | `RuleCatalog::Entry#new` | 31 | **G** | `Type::DataInstance` fold works both scopes; classifier miscounts (finding 1) | lib/rigor/analysis/rule_catalog.rb:84 |
| 18 | `singleton(JSON)#pretty_generate` | 25 | **B** | rbs stdlib json: `-> untyped` (json.rbs:1170) | lib/rigor/cli/baseline_command.rb:168 |
| 19 | `Prism::Node#rigor_each_child` | 22 | **E** | method exists only via `class_eval` string codegen (source/node_children.rb:97-101) — statically invisible metaprogramming, plugin-API territory by policy | lib/rigor/analysis/check_rules/rule_walk.rb:156 |
| 20 | `{}#[]` | 21 | **C** | open/empty HashShape read is untyped by contract (PR #249) | lib/rigor/analysis/check_rules.rb:1004 |
| 21 | `Hash[String,Dynamic]#fetch` | 20 | **C** | value side Dynamic (parsed YAML config) | lib/rigor/configuration.rb:480 |
| 22 | `Prism::ConstantPathNode#parent` | 20 | **D** | finding 2 | lib/rigor/analysis/check_rules.rb:1183 |
| 23 | `MethodCatalog.for_topic` | 19 | **D** | optional-kwarg decline (finding 3); body's `new(...)` types fine in-file | lib/rigor/inference/builtins/array_catalog.rb:14 |
| 24 | `Array#[]` (bare) | 18 | **C** | bare Array receiver | lib/rigor/analysis/effects_cache_probe.rb:105 |
| 25 | `Prism::ArgumentsNode?#arguments` | 17 | **D** | finding 2 (`Array[Prism::node]` payload); optionality of receiver itself is handled | lib/rigor/analysis/reachability/scan.rb:179 |
| 26 | `Reflection.instance_method_definition` | 14 | **D** | optional kwargs `scope:`, `environment:` (finding 3) | lib/rigor/analysis/check_rules.rb:837 |
| 27 | `Scope#type_of` | 14 | **D** | optional kwarg `tracer:` (finding 3), instance-method variant | lib/rigor/inference/precision_scanner.rb:140 |
| 28 | `RbsTypeTranslator.translate` | 12 | **D** | optional kwargs (finding 3) | lib/rigor/analysis/check_rules.rb:2520 |
| 29 | `BudgetTrace.hit` | 12 | **A** | body returns `@mutex.synchronize { @counts[cat] += 1 }` — ivar-hash increment, param-keyed (budget_trace.rb:139-143) | lib/rigor/inference/body_fixpoint.rb:62 |
| 30 | `singleton(Marshal)#load` | 11 | **B** | RBS `-> untyped` by design | lib/rigor/analysis/reachability/scan_cache.rb:111 |
| 31 | `Proc#call` | 13 | **B** | bare `Nominal[Proc]`; RBS `(*untyped) -> untyped` | lib/rigor/builtins/imported_refinements.rb:161 |
| 32 | `bot#class` | 11 | **G** | receiver is `Bot` inside a raise-guard branch the engine proved unreachable; a call on Bot could soundly stay Bot | lib/rigor/analysis/fact_store.rb:101 |
| — | lens-artifact pairs (dissolve under full seed) | ~91 | **G(lens)** | finding 5 — `qualified_name` 37, `add_config` 17, `qualified_name_or_nil` 13, `hexdigest` 9, `constant_string` 8, `invert` 7 | lib/rigor/analysis/check_rules/ivar_write_collector.rb:72 |

## F — unsupported_syntax (1,234 sites, 7.1% of causes)

Two producers (`ExpressionTyper#fallback_for`, expression_typer.rb:960-963), root-censused with a
driver-side prepend. True unmodeled-construct roots under the lens seed:

| root node class | count | named construct |
| --- | --- | --- |
| `Prism::ConstantPathNode` | 1,535 | qualified constant paths the resolver cannot bind — including **dynamic-base paths** (`collector.class::NODE_CLASSES`, rule_walk.rb:111), genuinely static-opaque |
| `Prism::ConstantReadNode` | 389 | project-constant reads whose values the walk does not evaluate (`LEGACY_RULE_ALIASES`, check_rules.rb:71; `in_source_constants` is opt-in) |
| `Prism::CallOrWriteNode` | 8 | attribute or-writes `A::B.attr \|\|= v` (project_pre_passes.rb:82) — the #501 operator-write family's call-attribute variant |

The 19,520 `CallNode` fallbacks all route through `unresolved_call_result` (unresolved dispatch, mostly
Dynamic receivers) — propagation, not syntax. The provenance label smears down chains (ADR-82 WD6),
which is why protection groups like `sum`/`to_f`/`cache_store` carry `unsupported_syntax` at sites far
from any unmodeled node.

## Attribution split (named-receiver pairs, 3,330 full-seed sites)

- **A param-sourced (closed, ADR-67/58)**: ~640 sites in top-80 (own-type attr_readers ~360 + inferred
  returns genuinely input-dependent ~280). Plus nearly all of implicit-self (4,207) and
  dynamic-receiver (16,889) opacity per the audit's closed propagation finding.
- **B missing/declared-untyped RBS**: ~125 (Thread 75, JSON 25, Marshal 11, Proc#call 13). Note config
  has no `libraries:` gaps — everything relevant loads by default; these are *upstream `-> untyped`
  declarations*, matching protection's tiny add_rbs=371.
- **C container-of-Dynamic**: ~530 (Hash/Array/tuple/shape pairs) — one hop downstream of params.
- **D engine dispatch gaps**: ~330+ directly countable — prism alias/intersection cluster (~120 incl.
  tail), optional-kwarg decline (59 in top pairs + implicit-self share), index-write rvalue (~230,
  overlapping C rows 5/12) — three named mechanisms, each with a repro and a fix direction.
- **E metaprogramming**: 22 (`rigor_each_child`).
- **G metric artifacts**: 810 classifier-else sites + ~91 lens-seed pair sites + `bot#class` 11.

## Cross-repo table row

`rigor-lib: files=430 exprs=167079 precision=0.589 protection=0.457 pairs=3466(2.1% of opacity) top-mechanisms: classifier-else(G,810) rbs-alias-untyped(D) kwarg-decline(D) param-attr-readers(A)`
