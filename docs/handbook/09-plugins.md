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
