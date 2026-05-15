# Plugins

This is the shortest chapter. Plugins exist for one reason:
some methods' types depend on the **shape of their arguments
at runtime** in ways that no RBS sig can express.

## When you reach for a plugin

The classic case is a domain-specific evaluator:

```ruby
Lisp.eval([:+, 1, 2])           # Integer at runtime
Lisp.eval([:<, 1, 2])           # bool at runtime
Lisp.eval([:if, true, "a", 0])  # String | Integer at runtime
```

The return type depends on the literal first symbol of the
argument array. RBS can only say `untyped` here; Rigor's
inference can do nothing about it; an `RBS::Extended`
directive cannot vary by argument shape. **A plugin can.**

Other shapes that fit the plugin niche:

- **Units-of-measure DSLs** — `100.kilometers / 2.hours`
  produces a `Speed`, but Ruby's runtime sees a method on
  Integer that returns a user class.
- **Route helpers** — `users_path` returns a String, but
  whether the helper exists at all depends on a YAML file
  the analyzer has to read.
- **State machines** — `transition_to(:foo)` is fine if
  `:foo` is in a `state_machine do ... end` block declared
  somewhere; otherwise it is a typo.
- **Custom validators** — `validate(:email, value)` should
  catch a literal that does not match the named pattern at
  lint time.

Each of these has a worked example in
[`examples/`](../../examples/README.md). The
[`examples/README.md`](../../examples/README.md) page
compares the sixteen worked examples on architectural axes
(config schema, file I/O, cache producers,
engine-collaboration via `Scope#type_of`, cross-plugin facts,
return-type contributions, …) and recommends a reading order.

## What a plugin can do today

The v0.1.0+ plugin contract — pinned at
[`docs/internal-spec/plugin.md`](../internal-spec/plugin.md)
and laid out across a handful of slice specs in the same
directory — gives a plugin five primary surfaces:

1. **`#diagnostics_for_file(path:, scope:, root:)`** — the
   per-file emission hook. Walk the parsed AST, return an
   array of `Rigor::Analysis::Diagnostic` rows. The runner
   stamps each with `source_family: "plugin.<your-id>"`.
2. **`#flow_contribution_for(call_node:, scope:)`** — the
   per-call-site return-type contribution hook (v0.1.1
   Track 2 slice 7). Plugins return a `Rigor::FlowContribution`
   bundle naming the inferred return type at the call site;
   the analyzer's dispatcher merges the contributions and
   uses the merged return as if it were RBS-declared.
3. **`Plugin::IoBoundary#read_file`** / **`#open_url`** —
   sandboxed file and (since v0.1.2) HTTPS reads under the
   active `TrustPolicy`. Use this when the plugin needs to
   read project files (route tables, schemas, locale files)
   or fetch a stable URL.
4. **`Plugin::Base.producer` + `#cache_for`** — plugin-side
   cache producers. Use these for parses / lookups expensive
   enough to want cross-run caching. Auto-invalidates on
   the digest of every file (and content hash of every URL)
   the IoBoundary read while building the result.
5. **`Plugin::FactStore` + `#prepare(services)`** — the
   cross-plugin fact-publication surface (v0.1.1 Track 2,
   ADR-9). Plugins publish facts in `prepare`; downstream
   plugins consume them through `services.fact_store` so
   producer-side parsing (e.g., `config/routes.rb`) can be
   reused by every consumer (controller-side validators,
   factory-side validators, …).

The v0.1.2 release migrated four worked examples
(`rigor-lisp-eval`, `rigor-pattern`, `rigor-units`,
`rigor-activerecord`) from "diagnostic-only" to "narrowed
return type via `flow_contribution_for`", so chained calls
on plugin-typed values resolve through the analyzer's
normal dispatch rather than the RBS-level `untyped`
envelope. See the per-plugin README for which surface each
one demonstrates.

## Macro / DSL expansion substrate (ADR-16)

A second authoring path was added on top of the hand-rolled
walker contract above: the **macro expansion substrate**
(ADR-16). For metaprogramming-heavy DSLs — Rails-style
`has_one_attached`, dry-struct's `attribute`, Devise's
`devise :strategy`, Sinatra's `get '/foo' do ... end` — the
substrate lets a plugin author **declare** the call shape
instead of walking the AST by hand. The plugin's body becomes
a single manifest entry; the substrate handles literal-symbol
extraction, name interpolation, registry lookup, and per-method
synthesis.

Four tier shapes are recognised. The
[per-library survey](../notes/20260515-macro-expansion-library-survey.md)
identifies which libraries fit each tier and which fall
outside the substrate's scope.

| Tier | Shape | Manifest declaration | Worked example |
| --- | --- | --- | --- |
| **A — block-as-method** | DSL call's block runs as an instance method on the receiver class (`Sinatra::Base#generate_method`) | `block_as_methods: [Macro::BlockAsMethod.new(receiver_constraint:, verbs:)]` | [`rigor-sinatra`](../../examples/rigor-sinatra/) |
| **B — trait-inlining registry** | Class-level call enumerates symbols → bundled registry maps each to a module → substrate explodes the module's RBS methods onto the calling class | `trait_registries: [Macro::TraitRegistry.new(receiver_constraint:, method_name:, modules_by_symbol:, always_included:)]` | [`rigor-devise`](../../examples/rigor-devise/) |
| **C — heredoc template** | Class-level call interpolates a literal symbol into a method-name template; substrate emits synthetic readers | `heredoc_templates: [Macro::HeredocTemplate.new(receiver_constraint:, method_name:, symbol_arg_position:, emit:)]` | [`rigor-dry-struct`](../../examples/rigor-dry-struct/) |
| **D — external-file inclusion** | Files matching a glob run with `self` typed as a declared class | `external_files: [Macro::ExternalFile.new(glob:, receiver_type:, bound_ivars:)]` | (contract only as of v0.1.x — engine integration demand-driven) |

The three Tier-A/B/C plugins above are each ~60–110 LoC of
**purely declarative** Ruby — no walker, no
`diagnostics_for_file`, no plugin-side state. The substrate's
pre-pass + dispatcher integration do the work.

### Concern re-targeting

`ActiveSupport::Concern.included do ... end` is a *deferred
class_eval*: any DSL calls inside the block fire on whoever
includes the concern, not on the concern module itself. The
substrate's scanner handles this re-targeting automatically.
For source like:

```ruby
module Auditable
  extend ActiveSupport::Concern
  included do
    attribute :audited_at, Types::Time
  end
end

class Address < Dry::Struct
  include Auditable
  attribute :city, Types::String
end
```

`Address` gets BOTH `city` (direct) AND `audited_at` (re-targeted
from `Auditable`) as synthetic readers. The same pattern works
for Tier B traits (Devise modules included via Concerns).

### Floor / ceiling

Per ADR-16 § WD13, the v0.1.x deliverable is the **floor**:
synthetic methods emit by NAME so cross-file dispatch resolves
(no more `call.undefined-method`). Return types degrade to
`Dynamic[T]` (Tier C) or `untyped` (Tier B). Precise
return-type promotion via the
[ADR-13](../adr/13-typenode-resolver-plugin.md) resolver chain
is the **ceiling**, reserved for a later iteration when concrete
plugin authors need it. The substrate never *fabricates*
precision per ADR-5 robustness.

### Choosing between the substrate and a hand-rolled walker

| If the DSL is… | Use the substrate | Use a hand-rolled walker |
| --- | --- | --- |
| `class-level call with literal symbol args + framework class_eval'd heredoc` | ✓ Tier C | — |
| `class-level call with literal symbol args + registry-driven module include` | ✓ Tier B | — |
| `class-level call with do…end block running as an instance method` | ✓ Tier A | — |
| `external Ruby files instance_eval'd under a declared self` | ✓ Tier D (contract only as of v0.1.x) | — |
| `domain DSL whose return type depends on argument shape` | — | `flow_contribution_for` ([`rigor-lisp-eval`](../../examples/rigor-lisp-eval/)) |
| `cross-file validation (collect declarations, then validate uses)` | — | Two-pass walker ([`rigor-statesman`](../../examples/rigor-statesman/)) |
| `parsing an external project file (routes, schema, locale)` | — | `IoBoundary` + cache producer ([`rigor-routes`](../../examples/rigor-routes/)) |
| `schema-graph recorder (GraphQL-Ruby-style)` | — | Schema-resolution pass (no plugin authored yet) |

The substrate and the hand-rolled walker contract coexist —
a plugin can mix `manifest`-declared substrate entries with a
`diagnostics_for_file` walker. The
[`.codex/skills/rigor-plugin-author/SKILL.md`](../../.codex/skills/rigor-plugin-author/SKILL.md)
SKILL captures the decision flow in detail; the survey at
[`docs/notes/20260515-macro-expansion-library-survey.md`](../notes/20260515-macro-expansion-library-survey.md)
records which Ruby libraries the substrate covers and which
fall outside.

## Should you write one?

Probably not — most projects benefit from RBS and
`RBS::Extended` long before they hit the plugin niche.
Reach for a plugin only when:

- A domain DSL's typing depends on argument shape, file
  contents, or cross-method declarations.
- You are willing to maintain the plugin gem alongside your
  application.
- The team can read the plugin's source — it is not a black
  box anyone can ignore.

If those are true, [`examples/README.md`](../../examples/README.md)
is your starting point. The
[`rigor-deprecations`](../../examples/rigor-deprecations/)
example is the smallest fully-shaped plugin — manifest +
single per-file walk + a couple of diagnostic emissions —
and is the recommended template for "I want to author my
first plugin."

## What's next

If your project uses [Sorbet](https://sorbet.org/), the
[next chapter](10-sorbet.md) covers the `rigor-sorbet`
adapter — Rigor reads `sig { ... }` blocks, RBI files, and
`T.let` / `T.cast` / `T.must` / `T.unsafe` assertions as
type sources, so you do not have to rewrite anything in RBS
to start running `rigor check` alongside `srb tc`. If you do
not use Sorbet, chapter 10 is safe to skip.

From here:

- Cover-to-cover re-reading is rarely useful — most readers
  return to specific chapters as questions arise.
- The [Handbook index](README.md) has the cross-references
  to deeper material in
  [`docs/type-specification/`](../type-specification/README.md),
  [`docs/internal-spec/`](../internal-spec/README.md), and
  [`docs/adr/`](../adr/).
- The [`CHANGELOG.md`](../../CHANGELOG.md) is the per-release
  truth for what shipped when.

Welcome to the small, growing community of static-Ruby
believers.
