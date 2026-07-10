# Union-arm predicate polarity narrowing

Design note, 2026-07-10. The FP-removal slice the [module-singleton seed](20260710-module-singleton-cross-file-seed.md)
adjudication isolated, landed ahead of it per the front-load discipline (remove false positives
before adding precision — ADR-58 / ADR-78 ordering).

## The gap

```ruby
login = CodesetUtil.replace_invalid_utf8(raw)   # String | nil
login.downcase if login.present?                # `possible nil receiver` — a false positive
```

`login.present?` excludes nil at runtime, and Rigor could not see it. Three separate mechanisms all
miss:

1. `present?` is an **ActiveSupport** method. The hardcoded predicate catalogue in `Narrowing`
   (`nil?`, `empty?`, `respond_to?`, …) must not grow gem methods — the engine does not know which
   gems a project loads.
2. The `rigor:v1:predicate-if-true` RBS annotation exists for exactly this, but
   `Narrowing#resolve_rbs_extended_method` reads facts only for a `Nominal` / `Singleton` receiver:
   `rbs_extended_class_name` returns nil for a `Union`, so **a union receiver never receives
   predicate facts at all**. Verified — annotating `Object#present?` changes nothing.
3. The nilable receiver is precisely the case where the narrowing is needed.

The reach is not one call site. Any precision work that turns a `Dynamic` into `T | nil` under a
`present?` / `blank?` guard surfaces it, which is how it was found.

## The observation

The answer is already written down, in the signature the project already loads:

```rbs
class NilClass
  def present?: () -> false
  def blank?: () -> true
end
```

A method that always returns `false` for `nil` cannot have answered truthily on a `nil` receiver.
So on the truthy edge of `login.present?`, the `nil` arm of `String | nil` is impossible. No
annotation, no hardcoded method list, no plugin hook — the polarity is a consequence of the declared
return type.

## The rule

For a zero-argument, block-less predicate call `recv.m?` used as a condition, where `recv` is a
union with a scope binding (local / ivar / `self`):

- an arm whose every RBS overload of `m?` returns literally `false` is dropped from the **truthy** edge;
- an arm whose every overload returns literally `true` is dropped from the **falsey** edge;
- any other arm survives both edges.

No-ops when nothing is dropped or when an edge would be emptied.

### Where the soundness comes from

Only arms that are a **value-pinned `nil` / `true` / `false`** participate. A `Nominal[Foo]` arm
statically admits Foo's *subclasses*, any of which may override the predicate and return the other
polarity, so dropping it would be unsound. `NilClass`, `TrueClass`, and `FalseClass` have no
subclasses — the declared return is the runtime return. That restriction is not a conservative
approximation that costs coverage: the nilable union is the whole motivating population.

**Safe navigation is excluded.** `login&.blank?` yields `nil` (falsey) for a nil receiver rather than
`NilClass#blank?`'s declared `true`, so the falsey edge admits nil. Dropping the arm there would
manufacture the exact false negative the rule exists to avoid — `login.downcase unless
login&.blank?` really can raise. `analyse_safe_nav_receiver` continues to own that shape's truthy
edge. A regression spec pins it.

## Gate

`make verify`, `make bench-perf` (27.89 M allocations, ceiling 29.17 M), `make docs-check` clean.
Corpus diff (`check --no-cache --no-baseline`):

| corpus | before | after | |
|---|---:|---:|---|
| haml / kramdown / liquid / rgl `lib` | 59 / 68 / 2 / 70 | identical | no ActiveSupport |
| Mastodon `app/models` | 5 | 5 | |
| GitLab `app` | 284 | 284 | |
| Redmine `app`+`lib` | 72 | **69** | three false positives removed |

The three Redmine removals are the guarded shape the rule targets, hand-verified:

- `issue_import.rb:306` — `return if content.blank?` then `content.split(",")`
- `query.rb:765` — `values.present? ? values.split('|') : ['']`
- `time_entry_query.rb:247` — same shape

Zero new firings anywhere.

## What this does not do

It reads a *declared* return type, so a project gains the narrowing only where the signature declares
the literal. That is the AS core-ext bundle and the ADR-72 `data/gem_overlay/activesupport` twin
today. Nothing infers polarity from a Ruby body — a project's own `def present? = false` on a
NilClass reopen would not be read, and should not be: the rule's soundness rests on the signature
being the contract.

The general `rigor:v1:predicate-if-true`-facts-for-union-receivers gap in
`resolve_rbs_extended_method` remains open. It is a larger surface (arbitrary target refinements
across arms, not a boolean polarity) and no corpus demands it yet.
