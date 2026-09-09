# Census-walk gap probe (issue #693)

The movable-site instrument behind
[`docs/notes/20260909-census-walk-gap-movable-sites.md`](../../docs/notes/20260909-census-walk-gap-movable-sites.md).
Kept because the note's conclusion is a *decline*, and a decline that cannot be
re-derived has to be re-measured the next time the shapes come up.

It lives under `tool/` rather than `tmp/` only because `/tmp/` is in `.gitignore`.

## What it counts

Three shapes that `ScopeIndexer`'s census walks do not record the way an ordinary
`def` body is recorded:

| shape | what it is |
| --- | --- |
| `a_class_body_cvar` | `@@x = …` written directly in a class body. `walk_class_cvars` descends `DefNode`s only, so the write is never censused. |
| `b_singleton_ivar` | an ivar written in a `class << self` def or a `def self.x`. `StatementEvaluator#seed_instance_ivars` returns early for a singleton body, so the read is never seeded. |
| `c_anonymous_class_ivar` | an ivar written inside a `Class.new do … end` / `Module.new do … end` body. |

Prism only — Rigor is deliberately not in the loop, so the counts are independent
of the analyzer whose behaviour is being sized.

## Columns, and what each is a bound on

- **sites** — writes in the gap position. Exact for the three shapes above.
- **recoverable** — the rvalue is a constant, a `Const.new`, or a literal, so a
  fixed walk would record something better than `Dynamic`. An opaque rvalue
  (a call on a non-constant, a parameter) records `Dynamic` either way.
- **with_read** — the same variable name is read somewhere in the same census
  scope. A **floor**: a class reopened in another file contributes its reads only
  when both files are in the run.
- **consuming** — at least one of those reads is the RECEIVER of a call, which is
  where a recovered type reaches a dispatch decision. A read that is discarded or
  handed to an untyped sink moves nothing.
- **cross_method / MOVABLE** — the consuming read is in a *different* method from
  the write. This is the column that matters: the dominant idiom in every corpus
  is `@x ||= {}` immediately followed by `@x[k] = …` in the same body, where flow
  already supplies the type and the census seed buys nothing. MOVABLE is a
  **ceiling** — it does not check that the recovered type reaches a diagnostic.
- **COLLIDES** — the gap-shape write lands in the same census slot as an ordinary
  `def`'s write of the same ivar name, so the two types union. This is where the
  gap stops being precision-only: it can fire `def.ivar-write-mismatch` on correct
  Ruby. `def self.x` is excluded — the write-mismatch collector already recognises
  that spelling as singleton; `class << self` does not.

## Running it

Inside the Flake shell, from the repo root:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bundle exec ruby tool/probe-693/census_gap_sites.rb <root> [subdir ...]
```

`PROBE693_FORMAT=json` emits per-site rows instead of the summary table.

The whole corpus at once (`SURVEY_ROOT` defaults to `~/repo/ruby/rigor-survey`):

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bundle exec ./tool/probe-693/run-corpus.sh
```

## What it reported on 2026-09-09

`results-20260909.json` holds the per-target summaries plus every movable and
colliding row. Across 14 targets / 17,706 parsed files:

| shape | sites | movable | collides |
| --- | ---: | ---: | ---: |
| `a_class_body_cvar` | 52 | 28 | 0 |
| `b_singleton_ivar` | 605 | 25 | 3 |
| `c_anonymous_class_ivar` | 35 | 3 | 2 |

None of the 5 colliding sites fires today. The reading is in the note.
