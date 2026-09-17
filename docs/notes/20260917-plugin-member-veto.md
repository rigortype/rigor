# Plugin-supplied members as an own-method veto source — sizing the corpus first

Status: measurement note for [#963](https://github.com/rigortype/rigor/issues/963) item 2; no design
commitments beyond what the PR shipped. Taken against the branch `plugin-member-veto-source-963`
(base `cd30c74b`), Ruby 4.0.5, on private copies of the `mastodon` and `redmine` survey checkouts.

The issue says of item 2: *"Structural and unprobed on the corpus; size before fixing."* This note is
that sizing. The headline number is **zero**, on both projects, under their committed configurations —
and the interesting part is why, plus what the fix cost to prove safe.

## What was counted

The shape at risk is an implicit-self call inside a model / controller body whose name is BOTH a
plugin-supplied member of the receiver AND a project **top-level** `def`. Both halves are required:
`Scope#bindable_top_level_def_for` produces no candidate without a top-level `def` of that name, so
the veto is never even asked.

The two halves were enumerated separately.

**Top-level `def`s** — a Prism walk over each project's analysed paths, counting `DefNode`s with a
nil receiver that are not lexically inside a `class` / `module` / `class <<` body. (A `def` inside an
`RSpec.describe ... do ... end` block counts: Ruby defines it on `Object`, which is the whole
mechanism.)

**Plugin-supplied member names** — `rigor-activerecord`'s own run-time dispatch gate,
`#recognised_method_names` (finders ∪ scopes ∪ associations ∪ column readers ∪ `column?`
predicates), read off a real `Analysis::Runner` in the project's own working directory so the model
index is the one the engine would use.

## The counts

| Project | Analysed paths | Files | Top-level `def` names | Model entries | Plugin member names | Intersection |
| --- | --- | --- | --- | --- | --- | --- |
| mastodon | `app`, `lib` | 1325 | 0 | 112 | 1122 | **0** |
| redmine | `app`, `lib` | 347 | 2 | 82 | 137 | **0** |

Redmine's two are `setup_db` / `teardown_db`, both in
`lib/plugins/acts_as_tree/test/acts_as_tree_test.rb`, and neither is a member of anything.

Redmine's smaller member set is reduced mode, not a discovery failure: it commits no `db/schema.rb`,
so the plugin has associations and scopes but no column surface.

**No probe of the binding was needed, and none would have been meaningful.** With an empty
intersection there is no site at which a top-level `def` could bind ahead of a member, so the "how
many diagnostics does this produce today" question answers itself: zero. Reporting a `type-of`
sample here would have been measuring nothing — and per
[`docs/agents/measurement.md`](../agents/measurement.md) `type-of` builds no plugin registry, so it
could not have seen a plugin member in the first place.

## Where the shape does exist

Widening the scan past each project's committed `paths:` to `spec/` and `test/` changes mastodon's
top-level `def` count from 0 to 460 — RSpec support helpers, essentially all of them — and two of
those names intersect the member set: `reblog` (`spec/models/trends/statuses_spec.rb:150`) and
`success` (`spec/controllers/admin/base_controller_spec.rb:9`, five occurrences project-wide). Redmine
gains nothing.

So the issue's own framing is right on both counts. The shape is real — a project that analyses its
specs alongside its app, which nothing stops it doing, has it — and it is absent from the corpus as
the corpus is configured. The fix landed on that basis: structural, not corpus-driven.

## What the fix cost to prove safe

Diagnostics before and after, same engine, same private copies, `check --no-cache --format json`,
cwd the target:

| Target | Before | After | Removed | Added |
| --- | --- | --- | --- | --- |
| mastodon (`app`, `lib`) | 2536 | 2536 | 0 | 0 |
| redmine (`app`, `lib`) | 1702 | 1702 | 0 | 0 |
| rigor itself (`lib plugins examples`) | 140 | 140 | 0 | 0 |

Empty set-difference in both directions on all three, which is the expected result given the
intersection above: no site changed hands because no site was in contention.

## The measurement that changed the implementation

Getting the issue's own headline example to resolve — a top-level `def name` versus a model's `name`
column reader — needs `rigor-activerecord` to answer the implicit-self spelling at all. Both existing
instance paths key on a WRITTEN receiver (`user.name`), so `name` inside `def display_name` reached no
path, the dispatcher's plugin tier had nothing to report to the veto, and the top-level `def` bound.

The obvious implementation is to route the implicit-self read through the same
`association_return_type` / `column_return_type` pair the written-receiver path uses. That was built
and measured, and it is wrong:

| Target | Before | After (precise types) | Added |
| --- | --- | --- | --- |
| mastodon | 2536 | 2593 | **57** |
| redmine | 1702 | 1707 | **5** |

Every added row is new and every one is a false positive on working code. Two families:

- `flow.always-truthy-condition` (60 of the 62) — a `column?` predicate reader now carries a type the
  flow layer folds a guard on, e.g. `local? ? username : "..."` in
  `mastodon/app/models/account.rb:238`.
- `call.possible-nil-receiver` — a singular association's `nil` arm surviving a `.compact` the engine
  does not fold: `[author, assigned_to, previous_assignee].compact` then `u.active?` in
  `redmine/app/models/issue.rb:1154`.

Both are questions about the reader's **type**, and #963 item 2 asks only whether the member
**exists**. The shipped contribution is therefore `untyped` — the ADR-82 WD4 answer
`#ruby_type_to_type`'s decline already documents next door: the plugin knows the reader is there and
declines to type it at this spelling. The site keeps the `Dynamic` it already had, the veto gets its
answer, and the corpus is byte-identical. Making the implicit-self reader PRECISE is a separate
change that has to clear those two families first.

## Bounds recorded rather than fixed

**`errors` does not resolve, and not for a reason this change can reach.** The issue names it
alongside the column readers, but `errors` is not an enumerable member of any `rigor-activerecord`
model: the plugin's bundled `sig/active_record/framework.rbs` deliberately declines to declare
`ActiveRecord::Base` at all (an empty declaration would close every model in the project and turn its
whole generated surface into `call.undefined-method`), so no source Rigor has knows
`ActiveRecord::Base#errors`, and no tier can answer it. A top-level `def errors` still binds ahead of
it. What the veto *can* answer is a plugin that claims the name, and the spec pins that with a fixture
plugin rather than pretending the AR case works.

**A project class whose ancestry leaves the project is the general form of the same gap.** `User <
ApplicationRecord < ActiveRecord::Base` truncates at a class with no signature, so Rigor cannot assert
"self does not answer this name" for ANY name. Treating a truncated MRO as a veto source would cover
`errors` and every other framework-supplied method at once — and would also silence a genuinely
undefined call inside every Rails model and controller, which is the trade this project's
false-positive posture does not automatically settle. It is a separate decision, not a residue of
this one.

## Limitations

- Two projects, both Rails. The shape is a Rails shape, so that is the right corpus, but "zero" is a
  statement about mastodon and redmine as configured, not about Rails apps.
- The member-name half is `rigor-activerecord` only. Other plugins contribute members (`rigor-devise`
  Tier B traits, `rigor-dry-struct` Tier C emissions), and neither corpus project uses dry-struct;
  mastodon does use Devise, whose traits were not enumerated because the top-level `def` half was
  already zero.
- The intersection is by NAME. A name in both sets would still need the call to be implicit-self, on
  a receiver the plugin claims, with the `def` in an analysed file — so the counts above are upper
  bounds, and the upper bound is zero.
