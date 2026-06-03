# Structural code repetition audit (non-catalog, non-plugin) — 2026-06-04

## Motivation

Follow-up to the built-in-typing boilerplate sweep
([20260603](20260603-builtin-typing-boilerplate-audit.md)). That note
covered the catalog + dispatch-tier machinery; this one sweeps the rest
of `lib/rigor/` for the same thing — code shapes copy-pasted or
re-implemented across many sites — explicitly EXCLUDING the catalogs
(`lib/rigor/inference/builtins/`) and the plugin surfaces
(`lib/rigor/plugin/`, `plugins/`, `examples/`).

Five subtrees were surveyed in parallel: the `Type::*` carriers, the CLI
subcommands, the inference engine (expression typer / statement
evaluator / scope indexer / narrowing), the analysis + diagnostics
layer, and the LSP / cache / sig-gen / environment cluster. The findings
collapse into **four cross-cutting themes**. Each cleanup must be a
behaviour-preserving, container-only refactor (the
`false-positive-discipline` rule); the type system and inference engine
are correctness-critical, so "well-tested" is doing the heavy lifting on
risk, not "looks mechanical."

Where a cleanup exposes a genuine shared **structural interface** (a
duck-typed module seam — several types responding to the same method
shape), declare it as an RBS `interface _Foo` per the AGENTS.md
terminology rule: it is an *interface* / *structural contract*, never a
"protocol" (that word is reserved for ADR-28 path-scoped protocol
contracts).

## Theme A — value-object `==` / `eql?` / `hash` / `inspect` / `to_h` boilerplate

The single most-repeated shape in the codebase.

- **`Type::*` carriers — 16 sites.** Every carrier hand-writes
  `==` (`other.is_a?(self.class) && field == other.field …`),
  `alias eql? ==`, `hash` (`[self.class, *fields].hash`), and `inspect`
  (`#<Rigor::Type::X #{describe(:short)}>`). E.g. `nominal.rb:69-81`,
  `constant.rb:118-130`, `union.rb:93-105`, `tuple.rb:70-82`,
  `hash_shape.rb:113-130`, … plus `AcceptsResult`.
- **`accepts` delegation — 15 sites.** Every carrier repeats
  `def accepts(other, mode: :gradual) = Inference::Acceptance.accepts(
  self, other, mode: mode)` with zero per-carrier logic.
- **`top` / `bot` / `dynamic` predicates — 15 carriers × 3.** Mostly
  constant `Trinary.no`; only Top/Bot/Dynamic/Refined/Difference/Union
  differ.
- **Cache descriptor entries — 5 classes.** `FileEntry` / `GemEntry` /
  `PluginEntry` / `ConfigEntry` / `DependencyEntry`
  (`cache/descriptor.rb:40-180`) each repeat `to_h` / `==` / `eql?` /
  `hash` / frozen-field init.

**Pain.** A new carrier author copies ~25 lines of identity boilerplate;
the bug class is real and severe — forget a field in `==`/`hash` and the
value silently vanishes from Sets/Hash keys or compares equal when it
should not. The contract is binding per
`docs/internal-spec/internal-type-api.md`.

**Direction.** A `ValueSemantics` mixin keyed on a declared
`equality_fields` list that supplies `==` / `eql?` / `hash` (and
optionally `inspect`); an `AcceptanceRouter` mixin for the fixed
`accepts` delegation. **Risk: per-carrier `==` semantics must be checked
first** — any carrier that compares order-insensitively or normalises
before comparing cannot use the naive field-wise mixin unchanged. The
type system's spec suite is the safety net.

**Interface opportunity.** The carriers already satisfy a single
structural contract (the "internal type API"). Worth an
`interface _Type` (or `_TypeCarrier`) in `sig/` enumerating the shared
surface (`==`, `hash`, `describe`, `erase_to_rbs`, `accepts`, `top` /
`bot` / `dynamic`, …) — interface, not protocol.

## Theme B — AST walk-gather skeleton

- **`scope_indexer.rb`** — 8 walk/gather methods, and
  `return unless node.is_a?(Prism::Node)` repeated at ~20 sites
  (325, 485, 501, 527, 620, 632, 645, 708, 737, 766, 794, 870, …). Each
  is "guard → case (Class/Module descend | specific node delegate) →
  recurse `compact_child_nodes`".
- **3 collector classes** (`check_rules/dead_assignment_collector.rb`,
  `always_truthy_condition_collector.rb`, `ivar_write_collector.rb`) each
  re-implement walk-gather-filter.
- **Union-on-accumulate** idiom repeated at `scope_indexer.rb:687, 750,
  776, 826` (`existing ? union(existing, t) : t`).

**Direction.** The small extractions are safe (a `union_accumulate`
helper; a shared `AstCollector` base for the three collectors). The full
generic tree-walker for scope_indexer is **HIGH RISK** — traversal order
and filtering are correctness-critical — and should be deferred or done
behind a shadow-run equivalence check, not as a casual cleanup.

## Theme C — CLI subcommand skeleton

- **12 commands** repeat `initialize(argv:, out:, err:)` + `run` +
  `parse_options` (annotate/type_of/type_scan/coverage/explain/diff/
  sig_gen/triage/plugins/plugin/skill/lsp/mcp). `$stdout` / `$stderr`
  defaulting is inconsistent across them.
- **Shared flags re-declared per command**: `--config` (10+),
  `--format` (7, identical `opts.on` + the same "unsupported format"
  error in 7 renderers), editor-mode `--tmp-file` / `--instead-of`. The
  buffer-binding validation is duplicated between `cli.rb:217-232` and
  `type_of_command.rb:79-95`.
- **`collect_paths`** is a verbatim copy in `type_scan_command.rb:70-83`
  and `coverage_command.rb:67-80` (only the error prefix differs).

**Direction.** `CLI::Command` base (init + defaults), a `CLI::Options`
flag-builder module (`add_config` / `add_format` / `add_editor_mode` +
shared `resolve_buffer_binding`), a `Renderable` mixin for the text/json
dispatch, and a shared `collect_paths`. Additive, low behavioural risk —
**but CLI has no dedicated unit specs**, so each extraction needs test
coverage added alongside (integration specs exercise the commands
end-to-end, which catches gross breakage).

## Theme D — handler skeletons

- **6 LSP providers** (hover/completion/signature-help/document-symbol/
  folding-range/selection-range) repeat the URI→buffer→Prism-parse→
  nil-guard preamble (~15 lines each); the LSP `loop.rb` and MCP
  `loop.rb` read/dispatch/write loops are near-identical.
- **6-7 RBS cache producers** (`cache/rbs_*.rb`) repeat
  `PRODUCER_ID` + `fetch` → `RbsDescriptor.build` →
  `store.fetch_or_compute` → private `compute`.
- **Diagnostic construction** — `location = call_node.message_loc ||
  call_node.location` + `Diagnostic.new(… column: location.start_column
  + 1 …)` repeated at 15+ sites in `analysis/check_rules.rb`.
- Smaller dispatch wrappers: ExpressionTyper's three variable-read
  twins (`expression_typer.rb:281-290`); StatementEvaluator's twelve
  compound-write one-liners (`statement_evaluator.rb:224-270`);
  narrowing's five polarity-branch wrappers (`narrowing.rb:1967-2007`).

**Direction.** `with_parsed_buffer` mixin for LSP providers; an
`RbsCacheProducer` base/macro for the cache producers (an **interface**
`_CacheProducer` declaring `fetch` is the natural RBS companion);
`Diagnostic.from_call_node` / `.from_node_name_loc` factories absorbing
the location+column boilerplate; table-driven dispatch for the
compound-write twelve and the narrowing five.

## Priority (ROI ÷ risk)

| # | Target | Scale | Risk | Verdict |
|---|---|---|---|---|
| 1 | **A: value-object semantics mixin** (carriers + cache entries) + `accepts` router | 21+ | low–med (well-tested) | strongest first move |
| 2 | **D: `Diagnostic.from_*` builder factory** | 15+ | low | high |
| 3 | **C: CLI base + `Options` + `Renderable` + `collect_paths`** | 12+ | low (add tests) | high |
| 4 | **D: LSP `with_parsed_buffer` + `RbsCacheProducer`** mixins | 12+ | medium | medium |
| 5 | quick wins: variable-read trio, `union_accumulate`, compound-write / narrowing dispatch tables | small | low | medium |
| 6 | **B: scope_indexer walker unification** | large | HIGH | defer / shadow-run |

**Deliberately NOT doing as a first move** (risk > reward): converting
the `Type::*` carriers to `Data.define` wholesale (changes
introspection / `is_a?` shape relied on in tests), rewriting
scope_indexer onto a generic visitor (traversal order is load-bearing),
and auto-generating the diagnostic `RuleCatalog` from `CheckRules`
(metadata-drift risk, large surface). The mixin / factory routes capture
most of the value at a fraction of the risk.

## Interface-ization (per AGENTS.md terminology)

Introduce RBS `interface _Foo` for the structural seams the cleanups
surface — these are *interfaces* / *structural contracts*, never
"protocols":

- `interface _Type` (or `_TypeCarrier`) — the internal type-object API
  every `Type::*` carrier satisfies. Pairs with Theme A.
- `interface _CacheProducer` — `fetch(loader:, store:) -> …` for the RBS
  cache producers. Pairs with Theme D.
- (Candidate) a `_DiagnosticSource` / collector contract if Theme B's
  `AstCollector` base lands.

Declarative, Steep-green, no forced conformance — consistent with the
`_DispatchTier` interface added in the Finding 3 work and the engine's
partial-signature idiom.

## Progress log (2026-06-04)

- **Theme A — DONE.** `Rigor::ValueSemantics` macro (`value_fields`,
  class_eval codegen so the generated `==`/`eql?`/`hash` run at
  hand-written speed on the hot path) applied to the 13 field-wise Type
  carriers and the 5 cache descriptor entries; `Rigor::Type::
  AcceptanceRouter` mixin for the 14 carriers' `accepts` delegation; and
  `interface _Type` declared in `sig/rigor/type.rbs`. Left hand-written
  by design: `Type::Constant` (distinguishes `value.class`), `Top`/`Bot`
  (field-free singletons), `Type::App#accepts` (delegates on `bound`),
  and `Descriptor#==` (canonical-bytes equality). Per-carrier `==`
  semantics were audited before migrating. No behaviour change; full
  suite (5406) / inference (1870) / cache (87) / steep all green.

## Execution order (high-value + easy-to-start first)

1. **Theme A** — `ValueSemantics` + `AcceptanceRouter` mixins across the
   carriers and cache entries, `interface _Type` in `sig/`. Per-carrier
   `==` audit first. **(done — see progress log)**
2. **Theme D builder factory** — `Diagnostic.from_call_node` /
   `.from_node_name_loc`; sweep the 15+ sites.
3. **Theme C** — CLI base + option-builder + renderer mixin (+ tests).
4. **Theme D handler mixins** — LSP `with_parsed_buffer`,
   `RbsCacheProducer` (+ `interface _CacheProducer`).
5. **Quick wins** — opportunistic alongside the above.
6. **Theme B** — only with a traversal-equivalence harness.

Every step gated by the full `rspec` suite + `rigor check lib` +
`make steep-check`, with behaviour held constant.
