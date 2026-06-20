---
name: rigor-ffi-plugin-author
description: |
  Decide whether an FFI-binding gem needs a Rigor sub-plugin at all (core `rigor-ffi` covers the literal-`attach_function` + thin-wrapper case), then author one if needed. Triggers: "Create a rigor-<gem> FFI plugin", "Our internal libfoo gem types as Dynamic", "FFI bindings in our project don't infer", "Write a plugin like rigor-rbnacl for our crypto wrapper". NOT for edits to bundled rigor-rbnacl / rigor-ethon / rigor-ffi-rzmq / rigor-sassc — those follow the general rigor-plugin-author SKILL.
license: MPL-2.0
metadata:
  internal: true
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor FFI Plugin Author

Sub-plugin for FFI-binding gems. Starts with an assessment phase that
will *talk you out of authoring a plugin* if core `rigor-ffi` already
covers the gem — that's the point. Plugins only exist where the four
binding-recovery hazards documented in [ADR-30](../../../docs/adr/30-rigor-ffi-plugin-shape.md)
appear.

## Phase 0 — When to trigger this SKILL

Trigger when the user wants to type FFI bindings on a gem that isn't
already one of the four bundled consumers (`rigor-rbnacl`,
`rigor-ethon`, `rigor-ffi-rzmq`, `rigor-sassc`). Typical asks:

- "Our internal `libacme` Ruby gem wraps libacme via FFI; the wrapper
  class methods all type as `Dynamic[Top]`."
- "Add a Rigor plugin for OSS gem X that uses the `ffi` gem."
- "The `ffx` translator complains about our binding file — can Rigor
  catch this statically?"

Do NOT trigger for:

- **Edits to an existing bundled `rigor-rbnacl` / `rigor-ethon` /
  `rigor-ffi-rzmq` / `rigor-sassc`** — use the general
  [`rigor-plugin-author`](../rigor-plugin-author/SKILL.md) SKILL or
  treat as ordinary edit work.
- **Core `rigor-ffi` engine changes** (the `BindingRecognizer`
  extension point, the typedef-nominal heuristic, the `ffx.unsupported-*`
  diagnostic family) — those are core development under
  `lib/rigor/`, not plugin authoring.
- **Hand-written C extensions** (`rb_define_method` in `ext/*.c`) — no
  Ruby-side static handle; out of scope per ADR-30 WD8.
- **Fiddle-based bindings** — separate `rigor-fiddle` SKILL / plugin
  family (sibling, not in scope here).

## Phase 1 — Coverage assessment (decide if a plugin is even needed)

Check the gem against this table. If every row is "core suffices", the
SKILL terminates with **"declare the dependency and stop — no plugin
needed."** This is the most common outcome; resist the pull to author
a plugin pre-emptively.

| Question about the wrapped gem's source | Answer | Verdict |
| --- | --- | --- |
| Does the binding file use literal `attach_function :name, [args], ret` calls (no wrapping DSL like `sodium_function`)? | yes | core suffices |
| | no (custom DSL) | **needs plugin** — `BindingRecognizer` registration (ADR-30 WD2) |
| Are the bindings in *this gem's* `lib/`, or in a sibling gem (like `ffi-rzmq-core` for `ffi-rzmq`)? | this gem | core suffices |
| | sibling gem | **needs plugin** — either [ADR-25](../../../docs/adr/25-plugin-contributed-rbs.md) bundled RBS or wait on [ADR-10](../../../docs/adr/10-dependency-source-inference.md) progress |
| Are method names generated dynamically from an option catalog (`define_method` over `iterate option_table`)? | no | core suffices |
| | yes (ethon-style) | **needs plugin** — [ADR-16](../../../docs/adr/16-macro-expansion.md) Tier B/C |
| Does the high-level wrapper class layer add semantics richer than what the FFI primitive return type captures (e.g. "this `:pointer` is always a 32-byte signing-key buffer")? | no — wrapper is a thin pass-through | core suffices |
| | yes — wrapper carries domain invariants the FFI types don't | **plugin recommended** for RBS refinement (the wrapper still types correctly without the plugin, just less precisely) |
| Does the gem use `typedef :pointer, :handle_name` aliases for opaque pointers? | yes — names follow `_ptr` / `_handle` / `Ptr` / `Handle` | core suffices (heuristic per [ADR-30 WD4](../../../docs/adr/30-rigor-ffi-plugin-shape.md)) |
| | yes — names diverge from the regex | core suffices but the project should add the alias to the `nominal_typedef_exceptions` list in `.rigor.yml` if it false-positives |

**Vanilla case (most common).** The gem just declares
`attach_function :acme_open, [:string], :pointer` plus a thin
`MyCorp::Acme#initialize(path)` that stores the result. The user-
facing class methods type correctly via ordinary inference. **No
plugin needed** — just list the gem under `dependencies:` in
`.rigor.yml` so the binding file is in ADR-10 scope.

**Stop here if Phase 1 says core suffices.** Don't author.

## Phase 2 — Where this plugin will live (per ADR-31)

Per [ADR-31](../../../docs/adr/31-contribution-and-supply-chain-policy.md)
(project-wide plugin contribution policy), the default for **all**
new plugins — private, public, anyone — is the same: **author the
plugin as a third-party `rigor-<gem>` gem in your own repo**,
depending on `gem "rigortype"` ([ADR-31 WD4](../../../docs/adr/31-contribution-and-supply-chain-policy.md)).
There is no path to land a new plugin via a pull request to this
monorepo.

### Layout

Three options depending on your context:

- **Standalone gem `rigor-<gem>`** in its own repo. The clean choice
  for OSS gems and for internal gems consumed by multiple projects.
- **Sibling gem in a private gem server** (`gem "rigor-<acme>"` from
  your company's internal gem index). Same shape as standalone but
  not published to rubygems.org.
- **Inline inside the consuming project's `lib/rigor/plugins/rigor-<gem>/`**.
  Simplest for single-project use; no separate gem to maintain.

This SKILL is procedural — it doesn't care which of the three you
pick. Continue to Phase 3+ inside whichever tree you chose.

### Optional: propose for official bundling

If the wrapped gem reaches significant community adoption
([ADR-31 WD3](../../../docs/adr/31-contribution-and-supply-chain-policy.md)),
you can file an issue at
[rigortype/rigor](https://github.com/rigortype/rigor) proposing
the plugin for bundling. The issue should include:

- The wrapped gem's identity, homepage, license.
- Evidence of community adoption (named in major projects' dependencies,
  cited in widely-read write-ups, multiple unrelated requesters,
  etc. — see ADR-31 WD3 for the intentionally-vague criterion).
- A pointer to your working third-party plugin (the implementation
  the maintainers will use as reference).
- Confirmation that the wrapped gem's upstream maintainers are
  not authoring a parallel rigor plugin in their own repo.

If accepted, the Rigor team **re-implements** the plugin in
`plugins/rigor-<gem>/` from scratch ([ADR-31 WD2](../../../docs/adr/31-contribution-and-supply-chain-policy.md)).
Your contribution is credited via `Co-authored-by:` in the
implementation commit(s) (GitHub renders the co-author on the commit
and counts it toward your profile). The supply-chain rationale —
maintainers must author every line of code that ships in the
`rigortype` gem — is the reason this isn't a PR-merge.

In rare cases where re-implementation would be strictly redundant
with a well-shaped third-party plugin (significant adoption,
maintenance-transfer willingness, code-style match, MPL-2.0
license or relicensable), `git subtree merge` is available as an
option ([ADR-31 WD5](../../../docs/adr/31-contribution-and-supply-chain-policy.md))
to absorb your plugin while preserving its git history. This is
not a path to plan around — default expectation is "your plugin
stays in your repo, indefinitely."

## Phase 3 — Scaffold

The procedural shape is gem-type-agnostic. Use the existing
[`rigor-plugin-author`](../rigor-plugin-author/SKILL.md) SKILL for:

- Directory layout (`lib/` / `demo/` / `README.md` / `CHANGELOG.md`).
- Gemspec, `Plugin::Base` subclass skeleton.
- Spec layout — under `spec/integration/` for an in-repo plugin or
  under your gem's own `spec/` tree for the standalone case.
- IoBoundary + cache-producer pattern (read BEFORE `cache_for`).
- Demo directory with `tmp/`-anchored cache + per-demo `.gitignore`.
- `make verify` expectations + commit subject convention.

**Gemspec note — wrapped-gem version pinning.** Pin the wrapped
FFI gem's version range in your plugin's gemspec:

```ruby
spec.add_dependency "acme", "~> 1.4"   # match the version your bindings target
```

When the wrapped gem releases a new version that changes its
`attach_function` declarations, RBS surface, or DSL shape, **the
plugin author tracks the change by updating the plugin in their
own repo** ([ADR-31 WD4](../../../docs/adr/31-contribution-and-supply-chain-policy.md)).
Orphan-plugin risk (the wrapped gem evolves, the plugin doesn't)
is the plugin author's responsibility, not Rigor's. The version
pin makes the supported-wrapped-version boundary explicit so
downstream users get a clean resolution failure rather than a
silently wrong recognition.

The FFI-specific divergences are documented in Phase 4 below.

## Phase 4 — FFI-specific extension points

> **Status note (2026-05-25).** Core `rigor-ffi` slice 1 has not
> shipped at the time this SKILL was authored. Step 4 below describes
> the *intended* extension points per [ADR-30](../../../docs/adr/30-rigor-ffi-plugin-shape.md);
> the concrete API surface stabilises once slice 1 lands and slice 2
> (`rigor-sassc`) provides the first reference implementation. Until
> then, treat Step 4 as a design sketch — check the ADR for the
> current state before relying on specific method names.

### 4a — DSL recognizer (only if your gem has a custom DSL wrapping `attach_function`)

If Phase 1 row 1 said "needs plugin — custom DSL", register a
`Plugin::FFI::BindingRecognizer`. The recognizer takes an AST node
(`Prism::CallNode`-shaped) and returns zero or more synthesized
`attach_function` facts:

```ruby
class Rigor::Plugins::RigorAcme < Rigor::Plugin::Base
  ffi_binding_recognizer :acme_function do |node, scope|
    # node: Prism::CallNode for `acme_function :foo, :c_foo, [:int]`
    # Return Array<AttachFunctionFact> or [] if not a match.
    next [] unless node.name == :acme_function
    args = node.arguments&.arguments || []
    next [] if args.size != 3
    AttachFunctionFact.new(
      ruby_name: args[0].unescaped.to_sym,
      c_name: args[1].unescaped.to_sym,
      arg_types: args[2].elements.map(&:unescaped).map(&:to_sym),
      return_type: :int,
    )
  end
end
```

The core processes the synthesized facts through the same pipeline as
literal `attach_function` calls.

### 4b — High-level wrapper RBS refinement (only if Phase 1 row 4 said "yes")

For domain-invariant returns the FFI primitive type can't express,
ship hand-authored RBS via `signature_paths:` (ADR-25):

```ruby
class Rigor::Plugins::RigorAcme < Rigor::Plugin::Base
  signature_paths ["sig/rigor-acme.rbs"]
end
```

The RBS lives at `sig/rigor-acme.rbs` inside the plugin and refines
the wrapper class:

```rbs
module MyCorp
  class Acme
    def initialize: (String path) -> void
    def signing_key: () -> String  # always 32-byte binary
  end
end
```

### 4c — `ffx` target awareness (optional)

If the wrapped gem is authored for ffx (or dual-target), Phase 1's
assessment is identical — ffx is a strict subset of the `ffi` gem
([ADR-30 addendum](../../../docs/notes/20260525-ffi-library-survey.md)).
The plugin doesn't need ffx-specific logic; the core's
`ffx.unsupported-*` diagnostic family handles ffx-incompatible
declarations automatically when an `extconf.rb` / `Gemfile.lock`
signal is detected ([WD5+WD6](../../../docs/adr/30-rigor-ffi-plugin-shape.md)).

### 4d — Demo fixture

The demo project should:

- `require` the wrapped FFI gem.
- Include a `lib/` example exercising every binding shape the
  recognizer matches.
- Have a `.rigor.yml` activating the plugin.
- Produce diagnostic output verifying the plugin's typing wins
  (e.g. a deliberately wrong-arity call surfaces as
  `call.wrong-arity` instead of `Dynamic[Top]`-silenced).

## Phase 5 — Test

Integration spec covers:

- Every binding shape the recognizer handles (positive and negative
  cases).
- The recognizer's output passing the same engine pipeline as a
  literal `attach_function` (i.e. a synthesised binding and a
  literal binding produce identical downstream behaviour).
- Wrapper class typing improves measurably with the plugin active.

Mirror the bundled-four spec patterns as a reference — copy the
structure from whichever of `rigor-rbnacl` (DSL recognizer) /
`rigor-ethon` (option catalog) / `rigor-sassc` (literal + nominal
typedef) is closest to your gem's shape.

## Phase 6 — Ship

The plugin lives in **your repo** (per Phase 2). Verify via
`rigor check` against real code that depends on the wrapped gem —
the success criterion is "wrapper class methods that previously
typed `Dynamic[Top]` now type concretely."

For a published standalone gem: cut a release per your own
release process. For an inline (`lib/rigor/plugins/`) layout: no
release process — the plugin is consumed in-tree.

### Optional: propose for official bundling

If the wrapped gem reaches significant community adoption later
([ADR-31 WD3](../../../docs/adr/31-contribution-and-supply-chain-policy.md)),
file an issue per Phase 2's "propose for bundling" template. The
Rigor team evaluates the request; if accepted, they re-implement
the plugin from scratch in `plugins/rigor-<gem>/`, crediting your
work via `Co-authored-by:` in the implementation commit(s)
([ADR-31 WD2](../../../docs/adr/31-contribution-and-supply-chain-policy.md)).

You don't open a PR for a new bundled plugin — new bundled
plugins are classified as sweeping changes under
[ADR-31 WD1](../../../docs/adr/31-contribution-and-supply-chain-policy.md)
and go through the issue-first route. The re-implementation is
by Rigor team only; the rationale is the supply-chain + review-
capacity argument in ADR-31 WD1. (Bug fixes to your own
third-party plugin land in your own repo; bug fixes to existing
bundled `plugins/rigor-*` from the rigor monorepo are welcome as
minor direct PRs per ADR-31's direct-PR path.)

## What "done" looks like

- **Phase 1 said core suffices** — no files changed; user instructed
  to add the gem under `dependencies:` in `.rigor.yml`. Done.
- **Phase 1 said plugin needed** — plugin gem (or inline plugin)
  exists in your repo, spec passes against real code that
  depends on the wrapped gem, `rigor check` shows concrete types
  where it previously showed `Dynamic[Top]`, wrapped-gem version
  pin in place. Done.
- **Promotion-for-bundling proposal filed** — issue opened with the
  Phase 2 fields (wrapped gem identity, adoption evidence, pointer
  to your working plugin, upstream-effort confirmation). Rigor team
  takes it from there; your role becomes "answer clarifying
  questions, test the official version once it lands". The
  `Co-authored-by:` attribution lands in the implementation
  commit(s).

## Common pitfalls

- **Authoring a plugin for a vanilla gem.** Phase 1 exists to
  prevent this. If every row of the table says "core suffices", the
  plugin adds noise and maintenance burden for zero precision gain.
  Stop.
- **Mistaking core absence for plugin opportunity.** "Rigor doesn't
  type my wrapper class precisely" might mean "core hasn't shipped
  yet" rather than "I need a plugin." Check the
  [CHANGELOG](../../../CHANGELOG.md) for `rigor-ffi` slice status
  before authoring.
- **Attempting to open a PR to this repo for a new bundled plugin.**
  New bundled plugins are sweeping changes under
  [ADR-31 WD1](../../../docs/adr/31-contribution-and-supply-chain-policy.md)
  and take the issue-first path. File an issue with the Phase 2
  fields instead. (Bug fixes to existing bundled plugins are
  minor PRs and welcome directly.)
- **Skipping the upstream-effort check.** Duplicating a plugin
  the wrapped gem's maintainers are authoring wastes both efforts.
  Search the wrapped gem's repo before authoring.
- **Forgetting the wrapped-gem version pin.** Without a version
  pin in the gemspec, your plugin silently misbehaves when the
  wrapped gem releases an API-changing version. Pin and follow
  semver-aware update patterns in your own repo.
