> **Withdrawn draft, not adopted.** This is the draft ADR-118 from #1531, preserved verbatim from that
> branch's commit `9bf7feacd` (`docs/adr/118-declaration-walk-traversal-contract.md`). On 2026-09-28 the
> ports it was written for were paused and the draft withdrawn. The record is
> `docs/notes/20260928-declaration-walk-remaining-walkers.md` on master, which lists the review's open
> problems. Relative links below resolve from `docs/adr/`.

# ADR-118 — The declaration walk's traversal contract for the remaining walkers

Status: **Proposed, 2026-09-28. A maintainer decision, amending [ADR-116](116-hot-file-restructuring.md)
WD5.** Nothing has landed. WD5's amendment rule requires this before `walk_class_includes`,
`walk_class_extends`, `walk_method_visibilities` or `walk_singleton_def_nodes` is ported. WD1 and WD5 are
prototyped on the unmerged branch `walk-statement-sequences-prototype`.

Grounding: [`docs/notes/20260928-declaration-walk-remaining-walkers.md`](../notes/20260928-declaration-walk-remaining-walkers.md)
(each walker's rules as read from the code, the prototype and its measurements).

## Context

ADR-116 WD5 moves `ScopeIndexer`'s table walkers onto one declaration walk, so that what `self`, the cref
and the nesting are under each construct has one implementation (C2). Slices #1517, #1522 and #1527 ported
four walkers, and three collectors now build five tables in one run per file. Both production sites
(`merge_project_method_indexes` and the pre-pass's `accumulate_project_index`) still walk every file four
more times: for includes and prepends, extends, method visibilities, and singleton def nodes. Those walks
cost 0.056 s over `lib`, against 0.068 s for the whole shared run.

Each of the four needs something the walk's contract does not have:

- **State that flows from one sibling statement to the next.** The default visibility, and the
  `module_function` toggle.
- **The definee**, which is where a receiverless `def` installs, and which is not `self` under
  `class << Foo`, `class << self` or `instance_eval`.
- **`self` rebound at a `define_method` block**, which the walk walks as an ordinary call.
- **Traversal quirks.** `END { }` is skipped, eval receivers are kept as written, and block parameters are
  walked under the rebound owner.

The contract is also the walk's cost model. #1045 found one splatted `when` costing 2.33M allocations,
because a per-node cost is paid at every node of every walk. #1527 pins that a run of three allocates
nothing per node. The traversal costs about 175 ns a node, so any per-node check is visible in the total.

## Decision

The criterion: **The walk computes what the context IS at a node, once, for every collector: `self`, the
cref, the nesting, and now the definee (C2). A walker that disagrees names a variant. A collector owns
what its table ACCUMULATES, including state that flows between siblings: the walk hands it a cursor and
never threads that state. A handler answers `DESCEND` or `DECLINE`, and nothing else. An event reaches a
collector only where the collector is still live.**

Applied to the candidate contracts:

| Candidate | Verdict |
| --- | --- |
| Statement-sequence events: a list's start, each direct statement, the list's end | Adopted (WD1). Sibling-order state is table state, so the collector keeps it, and the walk hands it the cursor. |
| An exit event on every node | Rejected. The only exit a walker needs is a statement list's end, which WD1 carries. A general exit doubles dispatch at every node. |
| A `class <<` event | Rejected in favour of WD2. The class a `class <<` opens is context, so the walk resolves it once rather than each collector resolving it. |
| A "descend with `self` rebound" answer | Rejected in favour of WD3. Each collector would decide what `self` is, against C2. A rebind that names an owner is a value to allocate, and the walk would fork on every distinct answer. |
| Walking header parts for collectors that opt in | Adopted as a rule with variants (WD4), built with the first walker that needs it. None of the four does. |

### WD1 — Statement-sequence events

- **The events.**
  - `on_sequence(node, context, body)` is called at each `Prism::StatementsNode` before its first
    statement.
  - `on_statement(node, context)` is called before the walk enters each direct statement.
  - `on_sequence_end(node, context)` is called after the last statement.
- **`body`** is the node the walk entered a declaration-like body by: a `class` / `module`, `class <<`,
  meta-new, eval-family or bare-factory body. It is the body's `StatementsNode`, or its `BeginNode` for
  each clause list of a body-level `begin`. It is nil for any other list, including a bare factory block
  for a collector that walks it as an ordinary call (`factory_block: :ordinary_call`).
- **Answers.** `DECLINE` from `on_sequence` skips the list, and its end, for that collector. `DECLINE`
  from `on_statement` skips that statement for it.
- **Subscription.** A collector overriding any of the three takes all three.
- **The collector keeps its own stack.** It pushes at `on_sequence` and pops at `on_sequence_end`. An
  Array ivar costs no allocation per list once it has grown.
- **The rest of the run sees nothing new.** Children are still walked in `rigor_each_child` order, and a
  body-level `begin` is walked by hand in that same order.
- **Cost.** In the prototype, with WD5, a spine-only collector that takes these events and calls adds
  +4.4% to the shared run on `lib` and +8.2% on Mastodon `app`.

### WD2 — The definee in the context

- **What the context gains.** A def-owning table reads two things:
  - the definee: the class a receiverless `def` installs on, and whether that is its singleton;
  - inside `class <<`, the class whose singleton `self` is.
- **How the transitions answer them.**
  - `class` / `module`: the class, instance side.
  - `class << expr`: the singleton of what `singleton_class_prefix` resolves (`self`, a constant, or
    `Foo = expr`). Anything else is unnameable, and so is `class << self` inside a singleton body.
  - A meta-new body: the new class.
  - The `class_eval` family: the receiver.
  - The `instance_eval` family: the receiver's singleton. A self-receiver `instance_eval` inside a
    singleton body is unnameable.
  - A bare factory: unnamed.
- **Variants.** The walk's own rule is the resolved one. Extends names a variant that keeps the owner only
  for `class << self` outside a singleton body (`singleton_class_owner: :self_first_level`, #1521 item 6).
- **Cost.** These are values, so they add no fork and no event. A collector that does not read them sees
  exactly what it sees today.
- **Constructor.** `Context.new` already takes seven positional arguments, the lint cap. The `self`-side
  fields (`self_owner`, `singleton_cref` and the two new ones) become one frozen value, built per
  transition.

### WD3 — Block arms as rules

- `define_method` gets an arm: its body is walked with an unnamed `self`. `rebound_block_self` treats it as
  opaque today. The rule is `instance_block`; the walk's own variant is `:instance_self`, and the legacy
  one is `:ordinary_call`.
- Includes and extends follow the walk's rule. Visibilities, singleton defs and the ported collectors
  declare `:ordinary_call` wherever their tables would otherwise change. The shadow sweep in the PR that
  adds the arm decides which ones those are.
- `refine`, which the methods walker needs, takes the same mechanism when that walker is ported.

### WD4 — Rules for the remaining quirks

| Rule | The walk's rule | Legacy variant, and its walker |
| --- | --- | --- |
| `post_execution` (`END { }`) | `:children` | `:skip`: extends |
| `eval_receiver` | `:lexical` | `:as_written`: includes (#1521 item 9) |
| `rebound_block_parameters` | `:skip` | `:rebound`: includes, extends, visibilities; singleton defs when the block body is not a `StatementsNode` |
| `header_parts` | `:skip` | `:superclass`: deferred ranges, declared names. `:superclass_when_bodyless`: typed constant writes (#1521 item 4) |

Extends also skips every other block-carrying call entirely: receiver, arguments and block (#1521 item 12).
That needs no rule, because its `on_call` answers `DECLINE`, which prunes exactly those parts.

### WD5 — The live collectors as a bitmask, and the four design concerns

The walk carries the collectors live at a node as an Integer mask over the run's positions, not as an
Array. Declining clears a bit, and a variant fork is a mask intersection. Nothing is allocated, whatever the
run size or the number of declines.

An event is dispatched only where a collector that takes it is live, which costs one Integer AND. Gating
per run instead made a spine-only collector cost about +20% on `lib`, for the `def` bodies it had
declined. Gating per subset over Arrays still left +18% (108,034 hash lookups over `lib`).

The #1527 review left four concerns (#1197):

1. **Caching multi-collector traversals.** The traversal holds masks and classes, never collectors. The main
   Ractor keeps one per run shape, found through one identity table per position without allocating
   ([ADR-15](15-ractor-concurrency.md)). A run no longer builds a traversal or its subsets per file.
2. **Nesting tracking.** `:nesting_head` and `:body_with_lost_nesting` read `Context#nesting`, which an
   untracked root leaves nil. A variant declares that it needs a tracked root. `DeclarationWalk.run` then
   raises a `ContractError` when one of its collectors follows such a variant from a root that tracks none:
   one check per run. This is not prototyped.
3. **`without`'s copy in runs of four or more.** Masks never copy.
4. **Owner normalisation.** It stays as it is: `walk_rebound_body` compares owners as arrays. Normalising
   segmentation would hand the `:nesting_head` collectors a different `self_owner` from the one a run of
   their own gives them. A compact header's segmentation is itself what `lexical_prefix` turns on. The cost
   of not normalising is a second walk of a body whose two owners differ only in segmentation, and the
   reviewer measured none on the corpora.

Prototype, the production shared run from master to the bitmask, best of 11 passes:

| Target | YJIT on | YJIT off | objects / file |
| --- | --- | --- | --- |
| `lib` | 0.071 → 0.065 s | 0.185 → 0.186 s | 63.4 → 58.9 |
| Mastodon `app` | 0.039 → 0.033 s | 0.106 → 0.100 s | 35.2 → 31.3 |

Every table stayed byte-identical to its legacy walker over 67,137 files and 12,000 fuzzed programs.

### WD6 — Port order

1. **WD5 alone:** the bitmask live set and the nesting check. It is a byte-identical refactor that makes
   the run faster, and every later port measures against it.
2. **Includes and prepends:** WD3's `define_method` arm, and WD4's `eval_receiver` and
   `rebound_block_parameters`. With this port the shared run has four collectors.
3. **Extends:** WD2's definee, with `:self_first_level` and the `instance_eval` split; WD4's
   `post_execution`; and a `DECLINE` for the block calls it skips.
4. **Method visibilities:** WD1, and WD2 for `instance_eval` and `class <<`.
5. **Singleton def nodes:** WD1 (the toggle across a body's clause lists, and the named form over the whole
   body) and WD2 in full (`class << Foo`, and `instance_eval`'s unnameable definee).

Each PR brings at most two contract pieces with one consumer, and keeps #1517–#1527's slice discipline:

- the legacy walker stays as the shadow oracle;
- the table joins the shared run in both production sites;
- byte-identity is shown over the corpora and the fuzzer, with a positive control for every variant;
- the per-merge allocation sweep runs.

The order follows the dependencies. Includes needs neither sequences nor the definee, extends is the
smallest consumer of the definee, visibilities the smallest of the sequences, and singleton defs combines
both. `header_parts` and the `refine` arm wait for the walkers that need them.

### Guardrails

- A contract piece lands only with a consumer.
- Every existing collector's event trace stays byte-identical. #1527's trace-equality and zero-allocation
  specs cover each new event.
- Handlers answer only `DESCEND` or `DECLINE`, and an event is never dispatched to a collector that does
  not override it.
- ADR-116's guardrails apply as they stand.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| The walk threads sibling state (a fold the collector returns and the walk carries, so it keeps no stack) | Rejected | The walk would store one state per subscriber per list: an Array per list once two subscribe, or a per-run stack. The collector's own stack costs nothing per list, and only its owner pays for it. |
| Per-subset event gating over Arrays (a memoised event mask per subset) | Rejected | Measured: 108,034 lookups over `lib`, and a spine-only collector still cost +18%. |
| Keep the four on their legacy walkers | Rejected | 0.056 s of separate walks over `lib`, against about 0.009 s of dispatch for all four in the shared run, and the definee rules copied four times against C2. |
| Land a contract piece before its consumer | Rejected | There would be no table to hold it byte-identical against. |
| Normalise owner segmentation | Deferred | See WD5, concern 4. |

The rejected contract shapes (the general exit, the `class <<` event and the rebind answer) are in the
Decision's table.

## Consequences

Positive:

- The four walks fold into the shared run. Their dispatch costs about 0.009 s over `lib`, against 0.056 s
  for the separate walks (the note has the breakdown).
- The definee has one implementation. The methods, deferred ranges, class-method and alias walkers read it
  when they are ported.
- WD5 alone makes the current shared run faster and allocate less.

Negative:

- Three events and six rules to maintain, and each variant adds a #1521 item.
- The context grows. Its `self`-side fields are grouped to stay under the lint's parameter cap.

Carry-over: #1521 gains items for `eval_receiver` (item 9), `rebound_block_parameters` (item 9),
`singleton_class_owner` (item 6), `post_execution` (item 12) and `instance_block` (item 9).

## Relationship to other ADRs

- [ADR-116](116-hot-file-restructuring.md) WD5 — this is the amendment its rule requires; WD5 points here.
- [ADR-53](53-scope-discovery-index-separation.md) Track B — the source of C2, the criterion WD2 and WD3
  apply.
- [ADR-15](15-ractor-concurrency.md) — the per-shape traversal cache lives in the main Ractor only.
