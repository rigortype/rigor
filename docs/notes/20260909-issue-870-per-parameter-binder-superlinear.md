# The mutually recursive walk PR #547 exposed: characterisation (2026-09-09)

Status: measurement note for [#870](https://github.com/rigortype/rigor/issues/870); names the cause
[#872](https://github.com/rigortype/rigor/issues/872) had to fix. The characterisation landed without an
engine change; the resolution section below records what #872 then changed.

## The question

`rigor check --no-cache` on `rufo-0.18.2/lib/rufo/formatter.rb` (4,221 lines, one class of mutually
recursive `visit_*` methods with optional and keyword parameters) does not finish: over 25 minutes at
v0.3.8, over 120 s at master `5cab4e07`, against 23 s for the whole 11-file gem at v0.3.4. Every other gem
in the reporter's 874-file corpus stays at or under 12 s. The reporter bisected it to
[`acd35612`](https://github.com/rigortype/rigor/pull/547) ("Bind user-method call args per parameter
instead of bailing per signature") and read the process as spending its time in `rb_ary_push` /
`ary_ensure_room_for_push` / GC sweep — array-growth churn from a superlinear walk, not a hang.

The reporter's hypothesis was that the per-parameter binder re-infers callee returns interprocedurally
without a memo or a budget. Half of that is right and the other half points at the wrong component: there
*is* a memo, it is keyed correctly, and the binder does not thrash it. What is missing is a bound on how
often the memo is allowed to *refuse a store*.

## The fixture

`spec/integration/fixtures/issue_870_mutual_recursion/` holds a generator and its committed size-6 output.
The shape is rufo's `formatter.rb` reduced to its load-bearing structure — one class, `size` mutually
recursive methods in a single strongly connected component, each with an optional positional and a keyword
parameter, each calling three siblings with literal argument values:

```ruby
class Visitor
  def visit_0(node, indent = 0, force: false)
    return node if force
    a0 = visit_1(node, indent + 0, force: true)
    a1 = visit_2(node, indent + 1, force: false)
    a2 = visit_3(node, indent + 2, force: true)
    a0 || a1 || a2
  end
  # ...
end
```

No gem, no `sig/`, no undefined mixin — the `Rufo::Settings` mixin failure the real file raises is
incidental and is not needed to reproduce. Sizes above 6 are for measurement and are not committed;
`ruby spec/integration/fixtures/issue_870_mutual_recursion/generate.rb 14 3` regenerates one.

## The timings

`rigor check --format json --no-cache --workers 0` at master `5cab4e07`, one file per run, macOS,
back-to-back. The ~2.0 s floor is process start plus the RBS environment build; the growth is the term
above it.

| Methods | Lines | Wall | Peak RSS | `infer` entries | Body evals | Memo hit rate |
|---|---|---|---|---|---|---|
| 8 | 58 | 2.5 s | 231 MB | 3,687 | 3,264 | 25.8% |
| 10 | 72 | 3.9 s | 309 MB | 14,709 | 13,316 | 22.2% |
| 12 | 86 | 7.0 s | 476 MB | 55,365 | 50,812 | 19.8% |
| 14 | 100 | 14.0 s | 725 MB | 207,609 | 192,414 | 18.0% |

Wall time doubles and inference entries multiply by ~3.7 for every two methods added, while the file grows
by 14 lines. The memo hit rate *falls* as the component grows. This is exponential in the size of the
strongly connected component, which is why one 4,221-line file behaves unlike an entire 874-file corpus.

## The bisect: what #547 actually changed

The same generator emits a control in which the identical call graph uses only required positional
parameters (`def visit_0(node, indent, force)` / `visit_1(node, indent + 0, true)`). Running both shapes
against a tree exported at `acd35612^` and at `acd35612`:

| Shape | `acd35612^` (pre-#547) | `acd35612` (post-#547) |
|---|---|---|
| required positionals only | 12.5 s | 12.6 s |
| optional + keyword (`opt`) | **1.25 s** | **14.1 s** |

The blowup is *not* new in #547. It is fully present at `acd35612^` for required-parameter methods and is
unchanged by the commit. What #547 changed is which signatures reach it: before the commit,
`user_method_param_shape_simple?` declined any signature with an optional, rest, keyword, or block
parameter, `build_user_method_body_scope` returned `nil`, and `infer_user_method_return` returned `nil` at
the first hop — so for a `visit_*` cluster written in the optional/keyword style the interprocedural edges
never existed and no component ever formed. #547 made those edges real and thereby unmasked a pre-existing
unbounded walk. Reverting the per-parameter binding would re-hide it, not fix it, which is why #872
forbids that.

## The cause

`ExpressionTyper#consult_and_store_return_memo` decides post-hoc whether a computed return may be stored
(ADR-84 WD3). The store is refused when `context_tainted?` finds that a transient-machinery event logged
during the compute referenced a stack frame *below* the bracket's entry depth. Inside a strongly connected
component that condition is true almost always: every nested compute's body eventually re-enters a
signature that is already on the recursion guard stack — an ancestor — and `note_transient_fallback` logs
that at the ancestor's (shallower) position. The counters at size 12 make it exact:

```
infer entries:   55365
memo consults:   22989  (hits 4553 / misses 18436; hit rate 19.8%)
body evals:      50812
non-stored:      on-stack 32376  unroll-in-flight 0  consult-tainted 0  transient-tainted 18412
top signatures by body-eval count (evals / distinct-keys / signature):
      5512       2  Visitor#visit_1
      5396       2  Visitor#visit_2
      ...
```

18,412 of 18,436 memo misses (99.87%) computed a result and were then refused a store. Nothing inside the
component is ever memoised, so every call edge re-walks its whole callee subtree: branching factor equal to
the fan-out, depth equal to the component size.

**The distinct-key column kills the competing hypothesis.** Each signature is memoised under exactly *two*
keys while being evaluated 5,000+ times. This is not arg-granularity thrash from the per-parameter binder's
value-pinned arguments, so widening or normalising `memo_key` — the optimisation headroom #547's PR body
noted — would buy nothing here. `RECURSION_UNROLL_FUEL` and `RECURSION_FIXPOINT_CAP` both read 0: the
existing budgets are on the wrong axis. There is no bound at all on *body evaluations per signature per
outermost entry*, which is the quantity that explodes.

### Confirmation

Neutralising exactly that gate (`context_tainted?` forced to `false` in an exported tree — unsound, it
serves transient Kleene iterates, and it is not the proposed fix) collapses the term:

| Target | master | gate neutralised |
|---|---|---|
| fixture, 12 methods | 7.0 s / 55,365 entries | 2.4 s / **111** entries |
| fixture, 14 methods | 14.0 s / 207,609 entries | 2.0 s / **129** entries |
| `rufo-0.18.2/lib/rufo/formatter.rb` | > 900 s (killed) | **4.0 s** |

Entry counts drop by three orders of magnitude and the real rufo file finishes in four seconds. The term
is single-homed in the store gate.

### The array churn the reporter sampled

`stackprof` (cpu mode, 1 ms, size-12 fixture, in-process runner) puts the taint machinery itself at the top
of the Rigor frames:

```
Samples: 4809   GC: 1339 (27.84%)
  1166 (24.2%)  (sweeping)
   525 (10.9%)  Rigor::Inference::ExpressionTyper#note_transient_fallback
   338  (7.0%)  Rigor::Inference::ExpressionTyper#context_tainted?
   159  (3.3%)  (marking)
   134  (2.8%)  Rigor::Inference::ExpressionTyper#consult_summary
```

That is the `rb_ary_push` / `ary_ensure_room_for_push` / sweep signature the reporter saw, and it has a
second-order cause of its own: `TRANSIENT_EVENT_DEPTHS_KEY` is an append-only Array cleared only when the
guard stack drains, so within one outermost entry it grows to the full event count, `note_transient_fallback`
keeps pushing onto it, and `context_tainted?` allocates a suffix slice (`log[event_mark..]`) on every
candidate compute. On top of the exponential re-walk that adds a quadratic-in-events allocation term. Both
disappear once the walk is bounded, but the log's growth is worth bounding on its own.

## What #872 did (2026-09-09)

Lever 1 shape (a) landed, in the narrow form that is sound without a component model: **a context-tainted
result is stored when it is `Dynamic[top]`** (ADR-84 WD6). Inside the component every result is that, so the
walk collapses; outside it the gate is unchanged. `untyped` is the lattice top and the ADR-5 degradation
floor, so serving a stored top can only be *less* precise than an untainted recompute — never a type the
ancestor context invented, and never a diagnostic a fresh evaluation would not raise. Shape (b), the
per-`(signature, outermost entry)` body-evaluation cap, was not implemented: it bounds the walk only to
*cap × signatures × outermost entries*, still quadratic on rufo, and it is a real precision budget where the
exemption is not. Lever 2 landed as well — `context_tainted?` scans the log by index instead of allocating a
suffix slice.

| Methods | before: wall / evals | after: wall / evals |
|---|---|---|
| 8 | 1.7 s / 3,264 | 1.1 s / 28 |
| 10 | 3.2 s / 13,316 | 1.1 s / 32 |
| 12 | 6.2 s / 50,812 | 1.2 s / 36 |
| 14 | 13.9 s / 192,414 | 1.2 s / 40 |

`rufo-0.18.2/lib/rufo/formatter.rb`: > 900 s (killed) → **2.7 s**; the whole gem's `lib` → **2.8 s**.
`--format json --no-cache` byte-identical over `lib`, `plugins/*/lib`, `examples/*/lib`, liquid, mail,
redmine and mastodon.

## Fix direction for #872 (as written before the fix)

Two independent levers, either of which bounds the walk; the first is the root, the second is cheap
insurance.

1. **Make the taint gate finalisation-aware for own-component events, or bound the re-walk.** The gate is
   sound but far too coarse: it treats "an ancestor's in-flight state was touched anywhere in my subtree" as
   "my result is context-dependent". Inside one SCC that is every frame. Two shapes worth measuring against
   each other: (a) store a *provisional* entry keyed by the component, invalidated when the outermost entry
   drains, so repeats within the same outermost walk hit; (b) a hard per-`(signature, outermost entry)`
   body-evaluation cap alongside `RECURSION_FIXPOINT_CAP`, degrading to `Dynamic[top]` on exhaustion. (b) is
   the smaller change and is ADR-5-legal — a bound that degrades to `Dynamic` rather than to a wrong type —
   but it must be shown not to fire on the corpus, since a degrade there would move diagnostics. (a) is
   strictly better if it can be made sound. Whichever is chosen, the acceptance test is byte-identical
   `--format json` over `lib`, `plugins/*/lib`, and the survey projects.
2. **Bound `TRANSIENT_EVENT_DEPTHS_KEY`.** `context_tainted?` only needs to know whether any event past
   `event_mark` referenced a frame below `entry_depth` — a running minimum-depth-since-mark, or a scan
   without the suffix slice, removes the allocation term regardless of lever 1. Note this is the same log
   that makes the current gate correct; do not truncate it in a way that loses a below-entry event.

The gate spec belongs over the size-6 fixture with a body-evaluation counter, not a wall clock:
`spec/rigor/inference/mutual_recursion_walk_growth_spec.rb` currently pins the *bad* shape (evals far above
the method count, distinct keys at most 4) so #872 can invert the first expectation into an upper bound and
have a red-then-green gate.

## Reproducing

```sh
# inside the Flake, from the repo root
ruby spec/integration/fixtures/issue_870_mutual_recursion/generate.rb 14 3 > /tmp/visitor_14.rb
RIGOR_BUDGET_TRACE=1 bundle exec ruby -I lib -I plugins/rigor-rbs-inline/lib exe/rigor \
  check --format json --no-cache --workers 0 /tmp/visitor_14.rb
```

`--workers 0` is required: the counters do not cross `fork`. Per the
[#775 note](20260908-v037-allocation-regression-attribution.md) the budget-trace counters drift about 1%
across hours on one host, so every comparison above is back-to-back on the same tree.
