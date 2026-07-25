# Plugins

Plugins exist for one reason: some methods' types depend on
the **shape of their arguments at runtime** in ways that no
RBS sig can express. This chapter helps you decide when that
is worth a plugin, and when it is not.

It does **not** teach plugin *authoring*. That lives in
[`examples/`](../../examples/README.md) — six tutorial
walkthroughs, each spotlighting one extension surface.
Ready-to-install gems for real frameworks live in
[`plugins/`](../../plugins/README.md), and activating one is
[manual — Using plugins](../manual/07-plugins.md). Read on to
decide whether you need a plugin; go to `examples/` once you
want to write one.

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
compares the six worked examples on architectural axes
(config schema, file I/O, cache producers,
engine-collaboration via `Scope#type_of`, cross-plugin facts,
return-type contributions, …) and recommends a reading order.

## Two authoring paths

> Still here? Most readers should jump to
> [Should you write one?](#should-you-write-one) first — the
> answer is usually "no, RBS and `RBS::Extended` get you
> there." What follows is for when it is "yes."

The decision that shapes everything else is *which* of the two
authoring paths your DSL falls into.

**Declare it.** If the DSL is a class-level call with literal
symbol arguments — a Rails-style `has_one_attached`, a
dry-struct `attribute`, a Devise `devise :strategy`, a Sinatra
`get "/foo" do … end` — the **macro-expansion substrate**
([ADR-16](../adr/16-macro-expansion.md)) already knows that
shape. You write a manifest entry describing the call, and the
substrate does the literal-symbol extraction, the name
interpolation and the per-method synthesis. The three bundled
plugins on this path are 60–110 lines of declarative Ruby with
no AST walking at all. The substrate also understands
`ActiveSupport::Concern`'s deferred `included do … end` block,
so a DSL call written inside a concern lands on the class that
includes it rather than on the concern.

**Walk it.** If the type depends on something the shape of the
call cannot tell you — argument *values* (`Lisp.eval` above), a
declaration made elsewhere in the project, or the contents of
an external file such as a route table or a schema dump — you
write a walker instead, and the plugin contract gives you the
hooks for it: a per-file emission pass, per-call-site
return-type and flow-narrowing contributions, sandboxed file
and HTTPS reads under a trust policy, cached producers for
expensive parses, and a cross-plugin fact store so one plugin's
parse feeds another plugin's checks.

The two paths coexist — one plugin can declare substrate
entries *and* walk files — and where you go next depends on
which of them you need:

- [`examples/README.md`](../../examples/README.md) — the six
  walkthroughs, each spotlighting one contract surface, with a
  map of which example demonstrates which one.
- [`docs/internal-spec/plugin.md`](../internal-spec/plugin.md)
  — the binding plugin contract: manifest, hooks, services,
  registry, load order. Its siblings
  [`plugin-trust.md`](../internal-spec/plugin-trust.md) and
  [`plugin-cache-producers.md`](../internal-spec/plugin-cache-producers.md)
  cover the I/O and caching surfaces.
- [`docs/internal-spec/macro-substrate.md`](../internal-spec/macro-substrate.md)
  — the substrate's tiers, the manifest field each one
  declares, and how much return-type precision each recovers.
- [The macro-expansion library survey](../notes/20260515-macro-expansion-library-survey.md)
  — which real Ruby libraries fit which tier, and which fall
  outside the substrate entirely.

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
