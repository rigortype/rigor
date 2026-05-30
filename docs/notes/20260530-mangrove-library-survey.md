# Mangrove (Result / Option / Enum) — library survey + `rigor-mangrove` shape

Date: 2026-05-30.
Status: research note, no design commitments. Feeds a prospective
`plugins/rigor-mangrove` and clarifies its relationship to the already-shipped
[`rigor-sorbet`](../../plugins/rigor-sorbet/README.md) ([ADR-11](../adr/11-sorbet-input-adapter.md)).

Target: [kazzix14/mangrove](https://github.com/kazzix14/mangrove) (v0.40.0, MIT).
Source was read via the GitHub API; nothing is vendored as a submodule. The
goal is **type-checking Ruby code that *uses* Mangrove** — `result.and_then { … }`,
`opt.unwrap_or(x)`, `case variant; when MyEnum::IntVariant`, the `unwrap_in(ctx)`
early-return DSL — without that code degrading to `Dynamic[top]`.

## What Mangrove is

A Sorbet-enabled toolkit that ports Rust/Haskell idioms to Ruby:

| Carrier | Shape | File |
| --- | --- | --- |
| `Result[Ok, Err]` | `sealed! interface!`, `Ok` / `Err` variants, rich monadic API (`map_ok`, `and_then`, `or_else`, `unwrap!`, `expect!`, `and_err_if`, …) | `lib/mangrove/result.rb` |
| `Option[Inner]` | `sealed! interface!`, `Some` / `None`, `from_nilable` | `lib/mangrove/option.rb` |
| `Enum` | ADT — `variants do variant X, Type end`, each variant carries a distinct inner type | `lib/mangrove/enum.rb` |
| early-return DSL | `Collector#collecting` + `CollectingContext`; `result.unwrap_in(ctx)` short-circuits on `Err` | `lib/mangrove/result/collector.rb` |
| `Ext` | `value.in_ok` / `value.in_err` wrappers | `lib/mangrove/result/ext.rb` |
| `TryFromExt` | `try_convert_from(from:, to:, err:) { … }` → dynamic `try_into_<snake>` | `lib/mangrove/try_from_ext.rb` |
| Tapioca compilers | `lib/tapioca/dsl/compilers/mangrove_{enum,result_ext,try_from_ext}.rb` generate RBI for the dynamic surfaces | — |

The five questions from the macro-expansion survey, applied to the two
non-trivial surfaces:

### Enum DSL

1. **DSL** — `class MyEnum; extend Mangrove::Enum; variants do variant IntVariant, Integer; variant ShapeVariant, { name: String, age: Integer }; end; end`
2. **Mechanism** — pure runtime metaprogramming. `variants` stashes each
   variant's inner type via `variant.instance_variable_set(:@__mangrove__enum_inner_type, …)`,
   then installs a `const_missing` that `class_eval`s a **stringified Ruby
   heredoc** to lazily define each variant class (`initialize`, `inner`,
   `as_super`, `serialize`, `==`) the first time the constant is referenced.
3. **Generated surface** — one subclass per variant, each `MyEnum::IntVariant < MyEnum`
   with `#inner : <declared type>`.
4. **Static-expandability** — recoverable from source: the `variant X, Type`
   pairs are literal arguments in the block, and the generated method set is
   fixed. This is squarely an [ADR-16](../adr/16-macro-expansion.md) expansion
   target — the same shape as `rigor-dry-struct` (Tier C).
5. **Closest analogue** — Lisp `defmacro` over a literal spec list; Sorbet
   itself cannot see it statically, which is *why* Mangrove ships a Tapioca
   DSL compiler.

### Early-return DSL (`unwrap_in` / `collecting`)

1. **DSL** — `Collector[Ok, Err].new.collecting { |ctx| step1.unwrap_in(ctx); step2.unwrap_in(ctx); … }`
2. **Mechanism** — `collecting` wraps the block in
   `catch(:__mangrove_result_collecting_context_return)`; `Err#unwrap_in`
   `throw`s the enclosing `Err`, `Ok#unwrap_in` returns the inner value.
   Rust's `?` operator, hand-rolled.
3. **Generated surface** — none; it is a control-flow construct.
4. **Static-expandability** — the *type* (`unwrap_in : Ok` on the happy path)
   is in the sig, but the **control-flow divergence on `Err`** is not
   expressible in a sig. Recoverable only by a flow-aware analyzer.
5. **Closest analogue** — `T.must` / `T.absurd` (which `rigor-sorbet` already
   models as `flow_contribution_for` + an exceptional edge), or Rust `?`.

## Key finding — the type *source* is already covered

Two facts collapse the "type-source plugin" case:

1. **`sig/mangrove.rbs` is empty** (`VERSION: String` only). So the
   [ADR-25](../adr/25-plugin-contributed-rbs.md) `signature_paths:` route —
   ship the library's RBS with the plugin — is **not available**; there is no
   RBS to ship.
2. **`rigor-sorbet` (slices 1–8, feature-complete) already ingests Mangrove's
   real type source.** Mangrove's Result/Option API is fully `sig {}`-annotated
   (slices 1–3 cover these, including the generic applications), and the Enum's
   dynamic variants are materialised by Mangrove's **Tapioca DSL compiler** into
   `sorbet/rbi/{gems,dsl}/` — which `rigor-sorbet` slice 4 (RBI tree walk) and
   slice 8 (`Generated*` `include`/`extend` lift) already pull into the catalog.

So for a **Tapioca-using** Mangrove project, enabling `rigor-sorbet` already
flows Result / Option / Enum signatures into Rigor. A dedicated plugin adds no
new *type source*. This is the `rigor-ffi-plugin-author` "talk yourself out of
the plugin first" outcome.

## Where `rigor-mangrove` *does* earn its place

Three things `rigor-sorbet` (≈ Sorbet-level precision) structurally cannot do,
that are native to Rigor's engine:

| # | Capability | Why sig-ingestion can't | Rigor surface |
| --- | --- | --- | --- |
| ① | **`unwrap_in(ctx)` / `collecting` as flow** | happy-path is `Ok`, but the `Err` `throw` is a control-flow divergence absent from the sig | control-flow analysis + `flow_contribution_for` (exceptional edge), exactly as `rigor-sorbet` does for `T.absurd` (slice 6) / `T.must` |
| ② | **`is_a?(Result::Ok)` / `Some`/`None` exhaustive narrowing** | README itself deprecates `ok?`/`err?` in favour of `is_a?` "so Sorbet can type statically"; `sealed!` ADTs are textbook exhaustiveness targets | control-flow narrowing (discriminator on a sealed hierarchy) |
| ③ | **Enum DSL without Tapioca** | if the project does not run Tapioca, the `const_missing`/`class_eval` variants are invisible to Sorbet *and* to `rigor-sorbet` | [ADR-16](../adr/16-macro-expansion.md) macro expansion of `variants do … end` straight from source — same pattern as `rigor-dry-struct` |

④ (marginal) Result/Option are functors/monads, so [ADR-20](../adr/20-lightweight-hkt.md)
`App[F, A]` could thread `map_ok` / `and_then` precisely — but the Sorbet sigs
already pass `type_parameter(:NewOkType)` through, so the uplift here is small.
Not a launch justification.

The honest framing: **`rigor-mangrove` is a precision / control-flow plugin, not
a type-source plugin.** ③ is the strongest standalone justification (removes the
Tapioca dependency for Enum); ①② are the engine-collaboration wins that sig
ingestion can never reach.

## Recommendation

- **Placement** — Mangrove is a real gem, so `plugins/rigor-mangrove`
  (production), not `examples/`.
- **Scope** — define it as the ①②③ precision plugin layered *on top of*
  `rigor-sorbet`, not as a parallel type source.
- **De-risk first** — before committing plugin code, run a small survey: take a
  Mangrove-using fixture, check it with **`rigor-sorbet` alone**, and record
  exactly where it falls to `Dynamic[top]`. That measurement decides which of
  ①②③ actually fire and in what order to build them. Fixture belongs under
  `~/repo/ruby/rigor-survey/` per the
  [external-survey convention](20260519-oss-library-survey.md).
- **Process** — author via the `rigor-plugin-author` skill (Phase 0/0.5
  maintainer routing → requirements → template → scaffold → walker → integration
  spec). [ADR-31](../adr/31-contribution-and-supply-chain-policy.md) third-party
  path applies if a non-maintainer drives it.

Recommended sequence: **survey (rigor-sorbet alone) → plugin**. Validate the
"type source is already covered" hypothesis before building precision on top.

## Contract-fit check (2026-05-30, during plugin authoring)

Reading the actual v0.1.x plugin contract (`Macro::HeredocTemplate`,
`rigor-dry-struct`, `rigor-sorbet`) against the three slices changes the
buildability picture sharply:

| # | Slice | Contract fit | Verdict |
| --- | --- | --- | --- |
| ① | `unwrap_in(ctx)` / `collecting` early-return | **Buildable now.** Hand-rolled walker: `flow_contribution_for` recognises the `:unwrap_in` call, returns the receiver's `Ok` type on the happy path + an exceptional edge on `Err` — structurally identical to `rigor-sorbet`'s `T.absurd` (slice 6) / `T.must` recognisers. | **Ship as the v0 slice.** |
| ② | `is_a?(Result::Ok)` / `Some`/`None` narrowing | **Engine territory, not a plugin surface.** Narrowing on a `sealed!` hierarchy is core control-flow analysis; worse, Mangrove's sealedness is a *Sorbet* annotation, so the engine only learns it via `rigor-sorbet`. No clean plugin hook. | Defer; needs engine + `rigor-sorbet` sealed-hierarchy conveyance. |
| ③ | Enum `variants do variant Const, Type end` | **Does NOT fit ADR-16 Tier C.** Tier C extracts a literal **Symbol** at `symbol_arg_position` and emits **methods on the calling class**. Mangrove's `variant` takes a **constant** and must mint a **nested subclass** (`MyEnum::IntVariant < MyEnum`) carrying `#inner : <Type>`. `rigor-dry-struct` explicitly defers exactly this ("nested-block form minting `Address::Details` … needs Tier A + Tier C composition + `const_set` emission. Deferred."). | Needs an ADR-16 contract amendment (nested-class / `const_set` emission tier). Out of v0.1.x plugin scope. |

Net: a `rigor-mangrove` plugin shippable under the current contract = **slice ①
only**. ② is engine work; ③ needs an ADR-16 amendment. Per the
`rigor-plugin-author` "stop and ask rather than invent a workaround" rule, the
scope decision (ship ① alone vs. open the ②/③ engine/ADR work) goes back to the
maintainer.
