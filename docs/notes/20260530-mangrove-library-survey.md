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

(Note: slice ① as built is *not* the `unwrap_in` control-flow walker sketched in
the table above — measurement during authoring redirected it to the simpler,
in-contract **carrier-generic instantiation** at unwrap call sites. The engine
does not infer generics from `Result::Ok.new("x")` (raw Nominal, no `type_args`),
but a method whose declared return is an applied generic (`-> Result[String, E]`)
*does* carry `type_args`, so the plugin reads `type_args[0]` and contributes it as
the unwrap return. This shipped as `plugins/rigor-mangrove` in commit f7b20275.)

## Survey-fixture findings (2026-05-30, post-landing)

Validated slice ① against the **real chain** — Mangrove typed via Sorbet sigs
(its actual type source), not the hand-authored RBS the plugin's own demo uses.
Fixture: `~/repo/ruby/rigor-survey/_mangrove-probe/` (+ a shallow clone of the
upstream gem at `~/repo/ruby/rigor-survey/mangrove/`, which carries real inline
sigs and a `sorbet/rbi/` tree).

Probe (the realistic shape — a producer whose return is a user-defined generic):

```ruby
# typed: true
class Factory
  extend T::Sig
  sig { returns(Mangrove::Result::Ok[String, StandardError]) }
  def self.make = Mangrove::Result::Ok.new("ok")
end
Factory.make.unwrap!.uppercaze   # typo on the unwrapped value
```

Run with `rigor-sorbet` + `rigor-mangrove` both active (both report `[OK]` under
`rigor plugins`): **zero diagnostics.** `Factory.make` resolves to `Dynamic[top]`,
so `unwrap!`'s receiver has no carrier Nominal, rigor-mangrove no-ops, and the
typo ships silently.

**Root cause (confirmed in source).** `rigor-sorbet`'s
`TypeTranslator#translate_t_subscript` (`type_translator.rb:177-188`) instantiates
a generic application into `Nominal[name, type_args]` **only for `T::`-namespaced
constants** (`T::Array[E]`, `T::Hash[K,V]`, `T::Class[T]`). A user-defined generic
like `Mangrove::Result::Ok[String, StandardError]` is not `T::`-namespaced, so
`translate_call` falls through to `degraded` → `untyped`. The receiver type is
lost before rigor-mangrove ever sees it.

**Consequence — the chain that works vs. the chain that doesn't:**

| Type source for the carrier + producer return | Receiver at unwrap | rigor-mangrove |
| --- | --- | --- |
| **RBS** (`-> Mangrove::Result::Ok[String, E]`) | `Nominal[…, [String, E]]` (engine instantiates natively) | **fires** ✓ (demo + 6 specs) |
| **Sorbet sig** via `rigor-sorbet` | `Dynamic[top]` (user generic degraded) | no-ops ✗ |

So the plugin is correct and useful, but on the **RBS-typed path only**. Mangrove
projects are Sorbet-first, so the realistic path is the one that doesn't fire
today. The plugin's value is currently gated behind a source-of-types it rarely
has.

**Highest-leverage follow-up (surfaced by this survey).** Extend `rigor-sorbet`'s
`TypeTranslator` to instantiate **user-defined** generic applications
(`Const[A, B]` → `Nominal[Const, [A, B]]`), not just `T::`-namespaced ones. This
is a small, well-scoped change to one existing plugin (an ordinary edit, not the
plugin-author pipeline), and it would unlock rigor-mangrove on the real
Sorbet-typed chain — plus benefit *any* generic user type expressed in a sig
(`MyBox[T]`, `Pagy::Result[T]`, …). A cheaper stopgap — ship a carrier RBS overlay
with rigor-mangrove via `signature_paths:` — only helps if the consumer's producer
methods are *also* RBS-typed, which a Sorbet project's are not, so it does not
close the gap on its own.

Recommended order: **rigor-sorbet user-generic translation → re-run this probe →
(then) rigor-mangrove ②/③**. Without the first, ②/③ would layer more precision on
a receiver type that is still `untyped` in practice.

### Update — the rigor-sorbet fix landed (2026-05-30)

`rigor-sorbet`'s `TypeTranslator` now translates user-defined generic
applications (`translate_user_subscript`): any non-`T::`-rooted `Const[A, B]` in
sig position maps to `Nominal[name, type_args]` (recursively translating the
arguments). Re-running the probe above with the fix:
`chain.rb:12:22: error: undefined method 'uppercaze' for String` — the chain now
resolves end-to-end (`Factory.make` → `Nominal["Mangrove::Result::Ok", [String,
StandardError]]` → rigor-mangrove reads `type_args[0]` → `String` → the typo is
caught). So on a Sorbet-typed Mangrove project, enabling `rigor-sorbet` +
`rigor-mangrove` together now delivers the precision; the RBS-only gating is
lifted.

False-positive check: a `sig { returns(KnownClass[T]) }` over a normally-defined
(Ruby/Sorbet) carrier does **not** produce a spurious `undefined method []`
diagnostic — the engine does not analyse the sig block body as code for such
classes. (The only setup that surfaced a `[]` diagnostic was an artificial one
where the carrier was declared *only* in hand-written generic RBS, which is not a
real Mangrove shape.)

②/③ remain the open items, in that order, now that the receiver actually carries
its type at the unwrap site.

### Real-project false-positive validation (2026-05-30)

The user-generic translation turns previously-`untyped` sig returns into typed
`Nominal`s, which means more method calls become checkable — a precision win that
could, in principle, *introduce* false positives on real code. Validated with a
**before/after diff** on the most generic-heavy real Sorbet project available — the
upstream Mangrove gem itself (`~/repo/ruby/rigor-survey/mangrove/`, `lib` + `spec`,
under `rigor-sorbet`): run `rigor check --format json` with the
`translate_user_subscript` branch live, then with it commented out, and diff the
diagnostic sets.

Result: **860 diagnostics before, 860 after — 0 introduced, 0 removed.** The change
*does* fire (Mangrove's sigs return `Mangrove::Result[…]` / `Option[…]`, and the
spec chains carrier methods off those returns), yet it surfaced no new diagnostic
and silenced none. So on real Sorbet code the translation is **false-positive
neutral** — it sharpens types without frightening working code, honouring the
project's top-tier FP discipline. (It also added no *precision* diagnostics here,
because Mangrove's spec constructs carriers via `Result::Ok.new(...)` — a raw
nominal, no generic inference from the constructor — rather than consuming
sig-returned generics; the path the change sharpens is real but not Mangrove-spec's
dominant usage.)

## Survey-fixture findings — ② is_a? narrowing (2026-05-30)

Probed `is_a?(Result::Ok)` / `Err` narrowing against the engine directly
(`~/repo/ruby/rigor-survey/_mangrove-probe/narrow/`). **The contract-fit table's
②-row ("engine territory; no narrowing") was too pessimistic — measured against a
clean cache, the core narrowing already works.** (The first probe that suggested
otherwise was a stale-cache / formatter-shifted-column artifact; always
`rm -rf tmp` between narrowing probes.)

For a value typed as a **union of applied-generic variants** — the shape you get
from a producer whose RBS/sig return is `Ok[String, Integer] | Err[String,
Integer]` — `is_a?` narrowing is correct **and** type-arg-preserving in both
edges:

| Position | Inferred type |
| --- | --- |
| `if r.is_a?(Mangrove::Result::Ok)` → `r` | `Mangrove::Result::Ok[String, Integer]` ✓ |
| … `r.value` (Ok#value → OkType) | `String` ✓ |
| `else` → `r` | `Mangrove::Result::Err[String, Integer]` ✓ |
| … `r.error` (Err#error → ErrType) | `Integer` ✓ |

No false positive either way (and union method-dispatch is lenient, so even
*without* narrowing, calling an `Ok`-only method on `Ok | Err` does not
mis-fire). The engine path is `Narrowing#narrow_union_class` → per-member
`narrow_nominal_to_class`, with `Environment#class_ordering` returning
`:disjoint` for the sibling it drops. Core-class unions (`Array[String] |
Hash[…]`) behave identically; existing coverage lives in
`spec/rigor/inference/narrowing_spec.rb` ("narrows Union element-wise, dropping
disjoint members").

**The one real ② gap — downcast type-arg propagation.** When the value is typed
as the *parent / interface* generic (`Mangrove::Result[String, E]`) rather than a
union of the variants — which is the shape a Sorbet sig produces — narrowing
`is_a?(Result::Ok)` resolves the subtype but **drops the type args**:
`narrow_nominal_to_class`'s `:superclass` branch (narrowing.rb:2033) returns a
bare `Type::Combinator.nominal_of(class_name)`, so `Res[String, Integer]` narrows
to bare `ResOk` and `ResOk#value` degrades to `untyped` (measured). Carrying the
args correctly needs **generic substitution through the inheritance edge** (map
the parent's type args onto the child's params per the RBS `class Child[..] <
Parent[..]` decl) — positional copy is unsound in general (`class Foo[T] <
Bar[T, Integer]`). That is genuine, subtle core-engine work, normative under
`docs/type-specification/control-flow-analysis.md`, with **no false-positive
pressure** (it loses precision, never frightens working code). Demand-driven;
deferred. It is also what would let rigor-mangrove's unwrap fire after an
`is_a?` downcast (vs. only on already-union-typed receivers) — but that, again,
is a precision uplift, not a correctness fix.

Net: ② needs **no** narrowing-logic change for the common case (it works); the
remaining work is the downcast type-arg-propagation precision uplift, which is
core-engine generic-substitution and should be scoped + design-reviewed on its
own, not bundled into Mangrove work.
