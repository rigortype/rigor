# Real Sorbet/Tapioca app survey — strap + dependabot-core

Date: 2026-05-30.
Status: research note. Drove one shipped rigor-sorbet fix (attr-accessor
sigs, commit b1fe2aaf) and validated the user-generic translation change
(48f0719b) for false-positive safety on real code.

Targets (cloned under `~/repo/ruby/rigor-survey/`):

| App | Shape | Sorbet usage |
| --- | --- | --- |
| [strap](https://github.com/MikeMcQuaid/strap) | small Rails app | `sorbet/rbi/` (Tapioca), 4 sig files |
| [dependabot-core](https://github.com/dependabot/dependabot-core) | 30-gem monorepo, 1588 `.rb` | **745 sig files**, 13M `sorbet/rbi/` |

Method: run `rigor check --format json` with `rigor-sorbet` active, and — for
the user-generic change — diff the diagnostic set with the
`translate_user_subscript` branch live vs. commented out.

## Finding 1 — the user-generic translation change is FP-neutral *and* a no-op here

Both apps use **only `T::`-namespaced generics** (`T::Array`, `T::Hash`,
`T::Enumerator`) in sig position; neither writes a non-`T::` user generic like
`Result[T, E]`. So the 48f0719b translation change does not fire on either —
before/after diff is **0 introduced, 0 removed** (strap: 5→5; dependabot subset:
unchanged). Combined with the Mangrove result (fires, 0 introduced), the change
is confirmed false-positive neutral across three real Sorbet projects. The
user-generic-in-sig pattern it sharpens is **rare in mainstream Sorbet code**
(which leans on `T::*` generics) — it is mostly a library concern (Mangrove-style
`Result`/`Option`/custom-container carriers).

## Finding 2 — the attr-accessor sig FP (fixed)

dependabot-core surfaced a real false positive. A 10-file subset of `common/lib`
produced **85 `plugin.sorbet.parse-error`** diagnostics, all the same:
"`sig` block is not immediately followed by a method definition." Every one was
this idiom:

```ruby
sig { returns(String) }
attr_reader :name
```

rigor-sorbet's catalog walker only paired a `sig` with a following `def`, so a
sig over an `attr_reader` / `attr_writer` / `attr_accessor` read as a dangling
sig. This is a pervasive, valid Sorbet pattern (typing a generated accessor) —
85 spurious warnings in 10 files. **Fixed** (commit b1fe2aaf): the walker now
recognises the attribute macros as sig targets, records the accessor signature(s)
(reader `name`, writer `name=`, both for `attr_accessor`, each name for multi-name
forms), and stops warning. Subset diagnostics dropped **87 → 2**.

## Finding 3 — operational notes

- **Dependency RBS coverage:** dependabot's `Gemfile.lock` has **125 gems with no
  RBS available** (rigor reports this as `rbs.coverage.missing-gem` info). Their
  surfaces degrade to `untyped` (lenient, no FP) — but it caps how much rigor can
  check without `rbs collection install` or `dependencies.source_inference:`.
- **Performance:** a full `common/lib` (93 files) run did not finish in 4+ min —
  the 13M `sorbet/rbi/` walk plus dependabot's heavy-metaprogramming files are
  expensive. Per-file it is fast (~1.5s analysis after a ~2.6s cold env build).
  For the diagnostic profile + FP diff a 10-file subset (with `rbi_paths: []`) was
  used. A future perf pass on the RBI-tree walk / large-file analysis would make
  whole-monorepo runs tractable; out of scope here.
- **strap's diagnostics** (5 total) were 4× `String#html_safe` undefined-method —
  the ActiveSupport `core_ext` gap that `rigor-activesupport-core-ext` addresses,
  plus 1 missing-gem info. Not rigor-sorbet's concern.

## Takeaway

Running rigor against real Tapioca-using apps is the highest-yield way to find
rigor-sorbet false positives. The mainstream Sorbet idiom set (sigil discipline,
`T::*` generics, `attr_*` sigs, `Generated*` DSL modules) is what to harden
against — not the exotic surfaces. The attr-accessor sig was the one genuine FP
the two apps exposed; it is now closed.
