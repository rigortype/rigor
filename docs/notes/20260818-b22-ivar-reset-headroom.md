# The B2.2 ivar-reset skip (#389) has no diagnostic headroom on the corpus

Status: measurement note, no design commitments. The harness is the branch
[`measure/b22-yield`](https://github.com/rigortype/rigor/tree/measure/b22-yield) (commit `b39ee00b`,
deliberately unmerged); re-run it by checking that branch out.

Issue #389 proposes the effect system's first *typing* consumer: skip
`StatementEvaluator#invalidate_ivars_for_intervening_call` (the B2.2 reset, which widens every
narrowed ivar back to its class-ivar seed across an implicit-self / self-receiver call) when the
callee's effect summary is proven, exhaustive and free of `mutate.self` / `mutate.static` /
`global.write`. This note measures what that would buy before it is built. The answer is **nothing
measurable, and the acceptance fixture the issue names cannot report the diagnostic it promises to
remove.**

## Harness

Two env-gated hooks on the measurement branch:

- `RIGOR_B22_CENSUS=FILE` — one row per reset **event**: a call that actually widened at least one
  ivar (`class<TAB>selector<TAB>line<TAB>count`). Rows join offline against `rigor effects --format
  json --full`.
- `RIGOR_B22_DISABLE=1` — the reset does not happen at all. A diagnostic diff against a normal run
  is the **whole consumer's upper bound**: every criterion #389 could gate on is a subset of never
  resetting.

Scratch configs carry `effects: {}`, `parallel: {workers: 0}` (a forked worker's counters die with
`exit!`), absolute `paths:` and a scratch `cache.path`, wiped before every run. Survey checkouts:
redmine `a12198ea0`, mastodon `163f96cee`; `rigor lib` is this repo at `d5f1af6c`. Plugin lists are
each project's own plus `rigor-railties`; `severity_profile: lenient` for the two Rails apps, no
baseline, so every diagnostic counts.

## The headroom experiment

| subject | reset sites | diagnostics, B2.2 on | B2.2 off | delta |
| --- | --- | --- | --- | --- |
| `rigor lib` | 107 | 0 | 0 | identical |
| redmine `app`+`lib` | 336 | 792 | 792 | identical |
| mastodon `app`+`lib` | 366 | 2,349 | 2,350 | **+1 added** |

**809 reset sites, zero diagnostics removed.** The single added row is
`app/workers/activitypub/delivery_worker.rb:39` — `@performed = false; perform_request; ensure … if
@performed` — where the preserved narrowing folds `if @performed` to always-falsey. It is a false
positive, and it is exactly the shape B2.2 exists for: `perform_request` does set `@performed`. An
*effect-gated* skip would keep the reset there (the callee is not `mutate.self`-free), so this is
not a defect in #389's criterion — it is a demonstration that the criterion's protection is doing
work while its precision is not.

## Why zero: the reset has no diagnostic consumer

`call.possible-nil-receiver` fires only on a **local-variable** receiver —
[`check_rules.rb:1271`](../../lib/rigor/analysis/check_rules.rb) `return nil unless
call_node.receiver.is_a?(Prism::LocalVariableReadNode)`, restricting the rule to the one narrowing
surface that can prove a guard removed nil. An instance-variable receiver never reaches the rule.

So #389's first acceptance criterion — "`return unless @user; audit!; @user.name` with a pure
`audit!` no longer reports `call.possible-nil-receiver`" — **is not reproducible today**: the shape
reports nothing to remove. Verified on a fixture (`@user = ENV["U"]; return if @user.nil?; audit!;
@user.upcase`, `audit!` = `freeze`):

| | `type-of` at the use site | diagnostic |
| --- | --- | --- |
| B2.2 on | `String?` | none |
| B2.2 off | `String` | none |

Adding `@user: String?` as authored RBS changes neither column. The census confirms the reset does
fire there (`Probe<TAB>audit!<TAB>13<TAB>1`), so this is a live measurement, not a silent no-op — the
same negative-control discipline the `check_rules.rb` re-measure needed.

The benefit that *is* real is the type itself: `String?` → `String` at the use site. That is an
editor-mode / `type-of` improvement, not a `rigor check` one.

## The yield join, for the record

How many reset sites the effect gate would open, joining the census against the summary table:

| | reset sites | skippable via a project summary | via a core-catalogue row |
| --- | --- | --- | --- |
| `rigor lib` | 107 | 5 (4.7 %) | 33 (`freeze` 28, `raise` 2, `Integer`, `exit!`, `sleep`) |
| redmine | 336 | 11 (3.3 %) | 8 (`raise`) |

Two readings. First, **the project-summary half is small because exhaustiveness is** — the summary
table is 12.6 % exhaustive-and-mutate-free on redmine (589/4,683) and 17.0 % on `rigor lib`
(1,008/5,941), and every blocked site inherits that. Second, **what would actually open on plain
Ruby is the catalogue, not the fixpoint**: `self.freeze` alone is 28 of `rigor lib`'s 107, and
`data/effects/core.yml` already proves `freeze: effects: []`. On a Rails app the unresolved callees
are `redirect_to` (34), `respond_to` (30), `url_for` (13) and friends — plugin *attributions*, which
live in the declared lane and by design can never open a typing gate.

## What this suggests

- **Do not build #389 as specified.** Its measured ceiling is zero removed diagnostics across three
  projects, and its named acceptance fixture cannot produce the diagnostic it removes.
- If the B2.2 skip is revisited, the cheap half is the **catalogue** lane (a `mutate`-free core
  selector like `freeze`), which needs no on-demand summary recursion, no cycle handling and no
  fixpoint dependency — and it is where the sites actually are on non-Rails code.
- The consumer worth measuring first is the one whose rule reads **locals**: § 8 (2)'s computed
  purity for remembering call results across re-invocation (`if x.foo && x.foo.bar`) sits directly
  on `call.possible-nil-receiver`'s live surface, where B2.2's does not.
