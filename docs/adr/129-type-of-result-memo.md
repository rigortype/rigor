# ADR-129 — Remember `type_of` results under a closed typing state

Status: **Proposed, 2026-11-04.** A design for [#2709](https://github.com/rigortype/rigor/issues/2709), put to the
maintainer before any code lands. Nothing is implemented. This is the third design: the first two each had a key
that missed an input. The ceiling of this one was measured with a harness (stage 0 below). The staged plan in WD6
says what lands first and what can stop it.

Grounding:
- [`20261104-work-multiplier-census.md`](../notes/20261104-work-multiplier-census.md): where `rigor check` repeats
  itself;
- [`20261104-type-of-memo-ceiling.md`](../notes/20261104-type-of-memo-ceiling.md): the measured ceiling, and what two
  independent design reviews agreed on;
- [#2773](https://github.com/rigortype/rigor/pull/2773) and [#2782](https://github.com/rigortype/rigor/issues/2782):
  the same defect class in the ADR-84 return memo.

## Context

Profiling-driven tuning ran out in [#1507](https://github.com/rigortype/rigor/issues/1507). A census then found the
engine deriving the same type again:

- On Mastodon, 74% of `type_of` calls repeat an identical `(scope object, node)` pair.
- `Scope#type_of` builds a fresh `ExpressionTyper` per query (`lib/rigor/scope.rb` ~2363).
- The main pass records a node's entry scope, not its type.
- About ten rules re-type each call node's receiver (`lib/rigor/analysis/check_rules.rb` ~303).

**The first design** memoised every `(scope, node)` pair. It was wrong.

- A nested block enters with the enclosing scope object, because `Scope#entering_opaque_block` returns `self`. So the
  value pass (threading suppressed) and the statement pass type one pair under different frames.
- That lost a real `call.undefined-method`, and a byte-identity check over three corpora did not notice.
- Frames are installed with `begin`/`ensure`, so comparing them before and after a computation detects nothing.

**The second design** opened the memo only in the rule walk, behind a list of conditions that shut it, stamps and a
write replay. Each of three review rounds found one more input its lists had missed:

- the retry frames;
- `optimistic_origins`, then `dynamic_origins` read back into typing;
- `Plugin::IoBoundary`'s `thread_variable_get`.

Each round also found a landing gate that passed with a mechanism removed. The lists were written by reading code,
and reading code missed one more input every time. The ADR-84 return memo shows the same failure: its key omitted the
reflective-ivar repeat depth (#2773) and the block-body threading suppression (#2782), four review cycles after it
landed.

**Two independent design reviews** (Fable 5.1 and Opus 5.5, neither reading the other) found that a token of the
installed frames still cannot cover typing's hidden state. Three more kinds exist:

- state mutated in place: the unroll fuel, the ADR-55 summaries and their `:consulted` flag, the guard stack;
- counters read as a before/after delta: `loops_evaluated`, the consult mark, the transient-event mark;
- one-slot caches keyed on scope identity: `LoopValueRecord`, the inject record, `MatchRebinding::Frame#memo`.

Typing state also lives outside `Thread.current[]`: thread variables, Fiber storage, module ivars. Both reviews
concluded that state must be classified by kind where it is declared, behind a deny-by-default spec, rather than
enumerated.

**The ceiling** was then measured with a live memo keyed on an integer state id (see the note):

| Memo opened in | Mastodon allocations | Redmine | Rigor's `lib` |
| --- | ---: | ---: | ---: |
| rule walk | −19.0% | −10.9% | −2.0% |
| rule walk + main pass + callee bodies | −30.2% | −18.2% | −5.4% |

- The main pass and callee bodies add 11.2% on Mastodon, which clears the 5% bar this ADR set itself. Their
  count-mode CPU projection is 7.25%.
- `lib` falls short: 3.4%, and 3.1% projected.
- Diagnostics were identical in every run.
- A shadow mode recomputed every hit with the memo suspended: about 400K to 1.3M hits per corpus, and **zero** type
  mismatches.

## Decision

Close the typing state, then memoise `ExpressionTyper#type_of` on top of it.

- Every piece of mutable state that typing reads or writes lives in a slot declared with one of four kinds (WD1).
- A deny-by-default static spec rejects any other state (WD5, G3).
- The memo needs no knowledge of any particular slot. It keys on `(scope identity, node identity, state id)`. It
  validates the table reads its entry logged and replays the table writes. It refuses to store a computation that
  touched a resource.

**Criterion:** a typing result may be reused exactly when both of these hold:
- every input it read is part of its key, or was logged and is unchanged;
- every effect it had is replayed, or it had none that a later reader could observe.

Which of these applies to a piece of state is decided by the kind declared where that state is declared, never by a
list kept beside the memo. State without a kind fails the gate.

## Working decisions

- **WD1 — Four kinds of typing state**, owned by one module (working name `Rigor::Inference::TypingState`):

  | Kind | What it is | The memo's rule | Members today (illustrative; the registry is the list) |
  | --- | --- | --- | --- |
  | **Frame** | an input installed for a dynamic extent and restored exactly | in the key, through the state id | yield and forwarded-argument frames, threaded flag, repeat depth, key-presence walk state, Acceptance refusal, writer scope, unentered evaluator, tracer and effects switches, sink presence |
  | **Table** | a keyed store typing writes and may read back | reads logged and validated on a hit; writes logged and replayed | `dynamic_origins`, `void_origins`, `plugin_typed_calls`, `optimistic_origins`, `LoopValueRecord` and the inject record, effects and self-call records, ADR-46 dependency reads |
  | **Resource** | state consumed or rewritten in place, or read as a delta | touching it refuses the computation and every enclosing one | unroll fuel, ADR-55 summaries, guard stack, consult and transient logs, `loops_evaluated`, sink and retry-frame pushes |
  | **Memo** | an extensional cache keyed on all its inputs | unlogged; its purity is audited | `RunScopedSlots` memo slots, the return memo, `class_graph_buckets`, `ResolutionChain`, `MatchRebinding::Frame#memo` |

  - A Table read records `(table, key, observed value or ABSENT)`. A read of a key the same computation already wrote
    is internal and is not validated.
  - The ADR-84 return memo is a Memo. Its key gaps (#2782) become visible to the static spec once its inputs are
    slots.
  - Instance state of the typer (`@operand_types`, `@tracer`) stays a bypass. A spec compares
    `ExpressionTyper#initialize`'s parameters with a declared list, so a new field must be classified.

- **WD2 — The state id.**
  - A per-thread integer.
  - `TypingState.with(slot, value) { }` saves the slot's value and the id, assigns a fresh id, and restores both in
    `ensure`. Equal ids mean the same state instance: sound by construction, with no interning or hashing.
  - Measured locally at 96 ns against 83 ns for today's `previous`/`ensure` idiom, with no allocation.
  - An identical-value install also takes a fresh id. Keeping the id there (ELIDE) would recover 95% of the hits the
    exact id loses (+1.3 points of allocations on Mastodon). But that is where the shadow's table mismatches
    concentrated (167 against 0–1), so it is deferred (re-evaluation triggers).
  - `State` is cached on the typer, so a slot read is an ivar and an array index rather than `Thread.current[]`.
- **WD3 — The journal, the store and the hit.**
  - **The journal:**
    - One flat per-thread array logs Table reads and writes.
    - A computation's capture is a start index plus a refusal flag.
    - A Resource touch sets the refusal flag on every open capture. This is the `any` rule; the alternative `escape`
      rule refused only captures outside the resource's owner. `any` cost 0.05–0.24 points of allocations and was
      the only rule with zero table mismatches.
  - **Store:** a computation that was not refused stores either its bare `Rigor::Type` (empty slice, no allocation)
    or a frozen entry `(type, read slice, write slice)`.
    - Leaf nodes (local, instance, class and global reads, `self`, literals, constant reads) are never stored.
      Storing them saved 0.7–1.1% CPU at +10.8% RSS on `lib`.
    - A computation that raises is not stored. The journal keeps what it appended, so the enclosing capture still
      sees its writes.
  - **Hit:**
    1. Validate the read slice by identity, ABSENT included. On any difference, recompute.
    2. Append the read slice to the journal, so enclosing captures inherit it.
    3. Replay the write slice in order. The replay is itself journaled.
  - **Memory:** entries reference tables, not scopes, which should shed the retained callee scopes that made
    prototype v2 cost +15% RSS. Stage 0 measured +2.4% (Mastodon) and +4.3% (`lib`) with the memo open in all phases.
- **WD4 — Where the memo sits.**
  - On `ExpressionTyper#type_of` and nowhere else. `@typing_node` is a function of the key only there, and a spec pins
    the budget-cutoff writes that key on it (`record_dynamic_origin(@typing_node`) to an adjacent
    `note_transient_fallback`.
  - The table is per file and registered in `RunScopedSlots`. It is cleared when a file's analysis ends, on the runner
    path and in `WorkerSession#analyze_body` alike.
  - Which phases open it is a stage decision (WD6).
  - ADR-46 recording keeps it shut until the dependency reads are a journaled Table. After that, `--incremental` can
    open it too.
  - The language server's per-buffer publishes build a plain `Runner`, so they open it once it is live.
- **WD5 — Gates that can fail.**
  - **G1 Shadow.** On every hit, recompute with every memo and Memo slot suspended (`MemoAudit.suspended`), on
    isolated tables and an isolated journal. Compare the type, the write slice and the read slice's validity.
    - Mismatches are collected per thread and asserted when the run ends. A raise would be swallowed:
      `MemoAudit::Mismatch` is a `StandardError`, and the engine has 46 and 139 `rescue`s on the path.
    - CI runs it beside `RIGOR_MEMO_AUDIT` over `lib`, the integration fixtures and the plugin fixtures, and on a
      sample of Mastodon.
  - **G1′ Fault injection, the gate's own gate.** Spec-only switches each disable one mechanism:
    - ignore a Frame slot;
    - skip read validation;
    - skip the replay;
    - skip the Resource refusal;
    - skip a restore.

    For each switch, a spec asserts that G1 reports a mismatch on a fixture. The threaded-flag fixture from Context is
    one of them. The specs iterate the registry, so a new slot gets its case automatically. This answers the second
    design's "the gate cannot fail".
  - **G2 Perturbation specs per kind**, generic over the registry:
    - Frame: distinct installs give distinct ids, and `ensure` restores the id exactly.
    - Table: an overwrite, or a new key that was read ABSENT, between store and hit makes the hit recompute. An
      out-of-band clear is restored by the replay, in recompute order.
    - Resource: a touch refuses the capture and every enclosing one.
    - Nested hit: its read slice reaches the enclosing entry.
    - Memo: each slot is wired to `MemoAudit.check`.
  - **G3 Deny-by-default static spec**, Prism over `lib/rigor/{inference,scope*,reflection,analysis,effects,environment,plugin}`.
    - It flags:
      - `Thread.current[]`, `thread_variable_get` / `thread_variable_set`, `Fiber[]` and `.storage`;
      - `WeakMap` / `WeakKeyMap`;
      - module-level `@x =` / `@x ||=` in singleton methods;
      - unfrozen constant collections;
      - any direct table access outside `Scope`.
    - Its allow-list names `TypingState` and the process counters (`BudgetTrace`, `MemoAudit`), each with a reason.
      Growing the allow-list needs an ADR line.
    - The precedent is `spec/rigor/run_scoped_slots_spec.rb`.
  - **G4 Reachability audit.** Sampling `type_of` entries over the fixtures, every object reachable from a scope field
    must be frozen, a Prism node, a slot, or a declared Memo. This would have flagged `MatchRebinding::Frame`.
  - **G5 Output gates.** Kept from the second design. They are detectors, not the soundness argument: the first
    design passed them.
    - `--format json --no-cache`, byte-identical with the memo on and off, over `lib`, `plugins/*/lib`,
      `examples/*/lib`, the fixtures, and Mastodon, Redmine and GitLab `app/models` (strict profile, no baseline).
    - The four tables dumped per file.
    - `--workers=2` parity.
    - Warm output equals cold.
    - `engine-warm` separation.

      `--verify-incremental` compares memo-on against memo-off only for its cache-served half, so it is not a memo
      gate.
  - **G6 Hit-rate floor.** CI fails if root-id rule-walk hits fall below a fraction of their baseline. That catches a
    frame that stopped restoring.
  - **Plugins.** The plugin contract gains one sentence: `dynamic_return` and `narrowing_facts` answers are a function
    of their arguments and the environment. In audit mode, plugins are frozen after `prepare`. G1's Mastodon sample
    covers ten Rails plugins.
- **WD6 — Stages, each with an exit that can stop the work.**

  | Stage | What lands | Exit |
  | --- | --- | --- |
  | 0 (done) | harness ceiling | ≥ 5% beyond the rule walk on a Rails corpus. Met: 11.2% on Mastodon |
  | 1 | `TypingState` with the four kinds, the id and the journal; behaviour-identical, memo off. Typer and evaluator first (about 90 of the 230 `Thread.current[]` sites), then the rest; G3 | `engine-wall` 0 ± noise; allocations within ±0.5%; G3 green |
  | 2 | Tables and the one-slot caches behind slots; Memos wired to `MemoAudit`; G4 | the audit job green; settles #2767 |
  | 3 | Shadow only: store and verify every computation, serve none; G1, G1′, G2 | zero mismatches over `lib`, the fixtures, the plugin fixtures, Mastodon and Redmine; every injected fault detected |
  | 4 | Live in the rule walk | G5, G6; `engine-warm` separates on Mastodon |
  | 5 | Live in the main pass and callee bodies; the recording evaluator's configuration becomes a Frame | as stage 4, plus at least half of stage 0's Mastodon allocation gain; RSS within +10% of stage 4 |

  - Stages 1 and 2 pay for themselves without the memo. They make every new piece of typing state reviewable by kind,
    and they settle #2767.
  - Stage 3 is the smallest step that proves the key complete before any output depends on it.
- **WD7 — The contract text.** This PR corrects [`inference-engine.md`](../internal-spec/inference-engine.md) where it
  is wrong today. It does not describe the memo, which does not exist yet.
  - Purity holds per `(scope, node)` under the same ambient inputs. Those inputs are listed, and they include the
    contents of the two tables typing reads back: `optimistic_origins` and `dynamic_origins`.
  - The advisory-table paragraph no longer claims that nothing reads the tables back.
  - § "Determinism and Caching" allows identity-keyed caches only on those terms, and forbids `==`-keyed ones.
  - `LoopValueRecord` and the inject record are named as caches that may not meet the rule (#2767).

## Rejected and deferred alternatives

| Alternative | Why not |
| --- | --- |
| Memoise everywhere, gating stores on frames being unchanged (first design) | Frames are restored by `ensure`, so the comparison detects nothing. It lost a real diagnostic that byte identity missed |
| A rule-walk window with a shut list, stamps and a replay (second design) | The lists were built by reading code. Three review rounds each found an input missing, and the gate passed with a mechanism removed |
| A token of interned frame values | Installed values are mostly fresh (yield types, sink objects), so only flags would share, and the intern table pins every value. The measured ceiling of a frame-value vector is 112.5K hits against the exact id's 101.3K, and 95% of that gap is the identical-value case ELIDE covers |
| The `escape` refusal rule, which scopes a Resource touch to its owner | 0.05–0.24 points more allocation gain, but it let stale `dynamic_origins` replays through (1 against 0) |
| Storing leaf nodes | +0.5 points worse allocations and +10.8% RSS on `lib`, for 0.7–1.1% projected CPU |
| An explicit typing-context object passed by hand | Not byte-identical by default: about 200 `type_of` call sites in `lib` and 40 in `plugins/` and `examples/` inherit frames today, and one that forgot the context would type at the default state silently. It replaces only the id, the cheap part; Tables and Resources remain. Its useful half, `State` cached on the typer, is in stage 1 |
| Share call facts across the rules first ("option 2") | Sound with no invariant, and it reaches the rule walk, which measured −19% on Mastodon. Stage 4 covers the same ground and stage 0's residual justified going further, so the refactor of `check_rules.rb` (about 4,700 lines) would be redone. Revisit if stage 3 stalls |
| Key on `Scope#==` | Unsound: `==` ignores the discovery index, lexical nesting, block-self marks, declared refinements and fold-safe locals, all of which typing reads |
| A generic read barrier over every object | Ruby has no ivar-read hook, and proxying `Hash` and `Array` on the hot path would cost more than the memo saves |
| Abstract the return memo's key, or seed it from the main pass (#2710) | The first changes diagnostics. The second measured under 1% of callee CPU |

## Consequences

- **Gains,** projected from stage 0. Stage 4 must reproduce them on CI.

  | Corpus | Allocations | CPU (count-mode projection) |
  | --- | ---: | ---: |
  | Mastodon | −30% | about −13% (rule walk ~6% + 7.25%) |
  | Redmine | −18% | — |
  | `lib` | −5% | about 0 |

  The gain grows with the number of rules and plugins that re-type a receiver.
- **Costs:**
  - Every change that adds typing state must declare its kind, and G3 enforces it. That is a standing tax on engine
    PRs, paid on purpose: it turns the class of defect behind #2773 and #2782 from "found in review" into "fails a
    spec".
  - Instrumenting the frames cost +0.5% allocations in the harness. Stage 1's exit holds production to ±0.5%.
  - RSS rises by +2.4% (Mastodon) to +4.3% (`lib`) with every phase open.
  - Plugin `dynamic_return` and `narrowing_facts` blocks run fewer times.
- **Unchanged:**
  - `lib`-shaped code gains little. #1228 (one shared block entry scope) and #2711 stay the levers there.
  - The return memo's #2782 is not fixed by this ADR. Stage 1 makes it a visible Frame gap, not a hidden one.
- **Settled on the way:**
  - #2767: the one-slot caches become Tables;
  - the purity contract's text (WD7).

## Re-evaluation triggers

- **Stage 3 finds mismatches that classification cannot close:** stop at stage 2, which still pays for itself.
- **Stage 4's `engine-warm` does not separate on Mastodon:** stop, and reconsider sharing call facts across the
  rules.
- **ELIDE:** enable it only once G1 shows zero table mismatches with it on.
- **A plugin found impure by G1:** fix the plugin, or declare its answers a Resource.

## Relationship to other ADRs

- [ADR-84](84-cross-file-return-memo-scoping.md):
  - its WD3 transient-event bracket is the precedent for the Resource rule;
  - its ADR-46 read-set capture and replay is the precedent for the journal;
  - its key gaps (#2773, #2782) are this ADR's motivating defect class.
- [ADR-127](127-callee-floor-graph-budget.md): `MemoAudit` audits the Memo kind.
- [ADR-55](55-recursive-return-precision.md): its summaries and fuel are Resources, so a computation inside a fixpoint
  is never stored.
- [ADR-56](56-block-captured-local-mutation.md): `BodyFixpoint` rebuilds each pass's entry scope, so no entry crosses
  passes.
- [ADR-46](46-incremental-dependency-graph.md): dependency reads become a journaled Table, after which recording runs
  can open the memo.
- [ADR-52](52-compiled-plugin-contribution-dispatch.md) WD5: answered by the identity key. Its conclusion for plugin
  contribution caches stands.
