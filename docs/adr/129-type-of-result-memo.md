# ADR-129 — Remember `type_of` results under a closed typing state

Status: **Accepted, 2026-11-04.** A design for [#2709](https://github.com/rigortype/rigor/issues/2709), accepted by the
maintainer after three adversarial review rounds. Stage 0 (the harness ceiling) is done. Stage 1 is under way:
`TypingState` and G3 have landed with the typer, the statement evaluator and the key-presence guard converted
([#2796](https://github.com/rigortype/rigor/pull/2796)), and the remaining sites convert in later PRs. WD6 says what lands in each stage and what can stop it. This is the third design: the first two each
had a key that missed an input. Sharing call facts across the rules ("option 2", § Alternatives) lands independently
as [#2786](https://github.com/rigortype/rigor/issues/2786).

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
and reading code missed one more input every time. The ADR-84 return memo shows the same failure: its key omitted
the reflective-ivar repeat depth (#2773) and the block-body threading suppression (#2782).

**Two independent design reviews** (Fable 5.1 and Opus 5.5, neither reading the other) found that a token of the
installed frames still cannot cover typing's hidden state. Three more kinds exist:

- state mutated in place: the unroll fuel, the ADR-55 summaries and their `:consulted` flag, the guard stack;
- counters read as a before/after delta: `loops_evaluated`, the consult mark, the transient-event mark;
- one-slot caches keyed on scope identity: `LoopValueRecord`, the inject record, `MatchRebinding::Frame#memo`.

Typing state also lives outside `Thread.current[]`, in thread variables and module ivars. Both reviews concluded that
state must be classified by kind where it is declared, behind a deny-by-default spec, rather than enumerated.

**The ceiling** was then measured with a live memo keyed on an integer state id (see the note). Allocations are the
deterministic axis:

| Memo opened in | Mastodon | Redmine | Rigor's `lib` |
| --- | ---: | ---: | ---: |
| rule walk | −18.9% | −10.9% | −1.9% |
| rule walk + main pass + callee bodies | −30.1% | −18.1% | −5.1% |

- Live CPU was noise on the shared host (load average about 70 on 12 cores).
- A count-mode projection puts the main pass and callee bodies at 7.1% of Mastodon's CPU beyond the rule walk, 4.2%
  of Redmine's and 3.0% of `lib`'s. The projection is gross: it does not subtract lookup and store costs, and it
  overstated the rule walk against that phase's live figure.
- These figures are for the refusal rule WD3 states: a Resource write refuses, and so does a Resource read, except
  the two read exemptions it names. Refusing those two reads as well measured −24.2% on Mastodon (9.0 points beyond
  the rule walk, about 5.1% projected).
- Diagnostics were identical in every run.
- A shadow mode recomputed every hit with the `type_of` memo suspended and every other memo live, and compared the
  type and the final table state. Under the refusal rule chosen below it checked 101K (Mastodon), 158K (`lib`) and
  119K (Redmine) hits with **zero** mismatches.

## Decision

Close the typing state, then memoise `ExpressionTyper#type_of` on top of it.

- Every piece of mutable state that typing reads or writes lives in a slot declared with one of four kinds (WD1).
- A deny-by-default static spec rejects any other state (WD5, G3).
- The memo needs no knowledge of any particular slot. It keys on `(scope identity, node identity, state id)`. It
  validates the Table reads its entry logged and replays the Table writes. It refuses to store a computation that
  touched a Resource.

**Criterion:** a typing result may be reused exactly when both of these hold:
- every input it read is part of its key, or was logged and is unchanged;
- every effect it had is replayed, or it had none that a later reader could observe.

Which of these applies to a piece of state is decided by the kind declared where that state is declared, never by a
list kept beside the memo. State without a kind fails the gate.

## Working decisions

- **WD1 — Four kinds of typing state**, owned by one module (working name `Rigor::Inference::TypingState`):

  | Kind | What it is | The memo's rule | Members today (illustrative; the registry is the list) |
  | --- | --- | --- | --- |
  | **Frame** | an input installed for a dynamic extent, restored exactly, and frozen while installed | in the key, through the state id | yield and forwarded-argument frames, threaded flag, repeat depth, the key-presence walk's installation, Acceptance refusal, writer scope, unentered evaluator, tracer and effects switches, sink presence |
  | **Table** | a keyed store typing writes and may read back | reads logged and validated on a hit; writes logged and replayed | `dynamic_origins`, `void_origins`, `plugin_typed_calls`, `optimistic_origins`, `LoopValueRecord` and the inject record, effects and self-call records, ADR-46 dependency reads, ADR-84 return-memo entries |
  | **Resource** | state consumed or rewritten in place, or read as a delta | a write refuses the computation and every enclosing one; so does a read, unless the slot declares one of WD3's two read exemptions | unroll fuel, ADR-55 summaries, guard stack, consult and transient logs, `loops_evaluated`, sink and retry-frame pushes, the key-presence walk's `record`, entering a region protected by `rescue SystemStackError` |
  | **Memo** | an extensional cache keyed on all its inputs | unlogged; its purity is audited | `RunScopedSlots` memo slots, `class_graph_buckets`, `ResolutionChain`, `MatchRebinding::Frame#memo`, the environment's and `RbsLoader`'s lazy memos |

  - **Frame values must be frozen.** State that changes after it is installed is a Table or a Resource. The
    key-presence walk is therefore split: its installation is a Frame, and `record`, which rewrites `guard_ends` in
    place, is a Resource touch. Stage 0's harness bumped the id on `record` and refused the captures open at that moment.
  - **Table reads:**
    - A read records `(table, key, observed value or ABSENT)`.
    - A read of a key the same computation has already written is internal and is not validated.
    - A Table may declare itself a read-through cache of the computation's own value (`LoopValueRecord`, the inject
      record): reading its own write answers what reading ABSENT would have computed. For such a Table, a key the
      computation read ABSENT and then wrote validates when it is still ABSENT or holds the value the computation
      wrote. For every other Table, an ABSENT read validates only while the key is ABSENT.
  - **The ADR-84 return memo is a Table, not a Memo.** It is not extensional by design: its WD3 serves a standalone
    result where a fresh compute inside a cycle would be tainted, and its WD6 serves a stored `untyped`. A `type_of`
    computation that hits it logs the entry it read. Entries are never removed or rewritten within a run, so that
    read validates. A computation that misses it pushes the guard stack, which is a Resource touch, so it is refused.
  - **Two Memo rules:**
    - A Memo miss that writes a Table counts as a Resource touch, and so does a read-through-cache Table's miss whose
      computation writes another Table. The inject record's miss folds the block body, and that typing writes
      `dynamic_origins` causes; a later hit would validate its own value and replay causes that a newer typing has
      overwritten.
    - **The key audit.** A Memo, or a Table filled by a computation (the ADR-84 return memo), whose computation
      reads a Frame must key on the state id or on that Frame's value.
      - Audit mode records the Frame slots each miss computation reads, with the `type_of` memo suspended so that
        reads behind its hits are seen.
      - It compares them with the Frame terms the key reads through the `TypingState` API when the key is built, so
        the audit checks what the key actually carries. A read Frame that the key does not carry is a mismatch.
      - A Frame the miss computation installs itself (the return memo's `with_return_sink`) is internal. A Frame the
        memo forces to a constant at its entry (the key-presence walk under `without_guards`, the forwarded-argument
        list derived from `arg_types`) declares that form instead of a key term.
      - Process switches read during typing (FlowTracer, effects) surface as named exceptions with their reasons.
      - This is the check that turns the class behind #2773 and #2782 into a failing gate: the return memo reads the
        threading suppression without keying on it. A known gap is allowed only by naming its issue.
  - **Instance state of the typer** (`@operand_types`, `@tracer`) stays a bypass. A spec compares
    `ExpressionTyper#initialize`'s parameters with a declared list, so a new field must be classified.

- **WD2 — The state id.**
  - A per-thread integer.
  - `TypingState.with(slot, value) { }` saves the slot's value and the id, assigns a fresh id, and restores both in
    `ensure`. Because Frame values are frozen, equal ids mean the same frame values: sound by construction, with no
    interning or hashing.
  - Measured locally at 96 ns against 83 ns for today's `previous`/`ensure` idiom, with no allocation.
  - An install of an identical value also takes a fresh id. Keeping the id there (ELIDE) closes 95% of the hit gap
    between the exact id and a frame-value vector (73% of the gap to the plain `(scope, node)` key). It was measured
    only under the `escape` rule, and its 43–198 table mismatches there belong to the stale-replay class that the
    `any` rule refuses. ELIDE under `any` is unmeasured, so it is deferred to stage 3.
  - `State` is cached on the typer, so a slot read is an ivar and an array index rather than `Thread.current[]`.
- **WD3 — The journal, the store and the hit.**
  - **The journal:**
    - One flat per-thread array logs Table reads and writes.
    - A computation's capture is a start index plus a refusal flag.
    - A Resource touch sets the refusal flag on every open capture: the `any` rule.
      - The alternative `escape` rule refused only captures outside the resource's owner.
      - `any` lost 0.05–0.24 points of allocations, and it was the only rule with zero table mismatches.
    - **A touch is a write, or a read the slot does not exempt.** A Resource slot may declare one of two read
      exemptions, each a claim G1 checks:
      - **Id-determined:** the slot's value is fixed while the state id is fixed. The guard stack qualifies once its
        push and pop each take a fresh id, as stage 0's harness did. The push inside `with_call_site_frame` alone
        does not give this, since the push happens at that frame's own id.
      - **Delta-internal:** the read only feeds a before/after delta taken within the same computation, so with no
        write in between the delta is zero. `loops_evaluated` in `record_conditional_value` qualifies.

      The ADR-55 summaries' lazy initialisation (`||= {}` on entry) moves off the hit path in stage 1, so a
      return-memo hit neither reads nor writes them. Stage 0's harness counted writes and bumped the id on every
      Resource write, which approximates this rule. Refusing the two exempt reads as well loses hits but stays sound:
      it measured −24.2% on Mastodon instead of −30.1%.
  - **Store:** a computation that was not refused stores either its bare `Rigor::Type` (empty slice, no allocation)
    or a frozen entry `(type, read slice, write slice)`.
    - Leaf nodes (local, instance, class and global reads, `self`, literals, constant reads) are never stored.
      Storing them improved allocations by 0.8 points on Mastodon and 1.4 on Redmine, but cost 0.5 points on `lib`
      and raised `lib`'s RSS to +10.8%. The projected CPU was 0.7–1.1%.
    - A computation that raises is not stored. The journal keeps what it appended, so the enclosing capture still
      sees its writes.
  - **Hit:**
    1. Validate the read slice by identity, ABSENT included. On any difference, recompute.
    2. Append the read slice to the journal, so enclosing captures inherit it.
    3. Replay the write slice in order. The replay is itself journaled.
  - **Memory:**
    - Entries hold their scope keys strongly, and Table reads of the one-slot caches log `[scope, type]` values.
    - Stage 0 measured +1.6% RSS on Mastodon and +9.6% on `lib` under `any` with every phase open.
    - The table is per file (WD4), which bounds the retention.
- **WD4 — Where the memo sits.**
  - On `ExpressionTyper#type_of` and nowhere else. `@typing_node` is a function of the key only there, and a spec pins
    the budget-cutoff writes that key on it (`record_dynamic_origin(@typing_node`) to an adjacent
    `note_transient_fallback`.
  - The table is per file and registered in `RunScopedSlots`. It is cleared when a file's analysis ends, on the runner
    path and in `WorkerSession#analyze_body` alike.
  - Which phases open it is a stage decision (WD6).
  - It stays shut while a tracer is attached, and while ADR-46 recording runs. Once the dependency reads are a
    journaled Table, `--incremental` can open it too.
  - The language server's per-buffer publishes build a plain `Runner`, so they open it once it is live.
- **WD5 — Gates that can fail.**
  - **G1 Shadow.** The reference is production as it would run without the `type_of` memo: every other memo stays
    live.
    - **Stage 3 (shadow only).** On a would-be hit the memo serves nothing, and production computes as usual, so
      output is production's by construction. Afterwards G1 checks four things:
      - the type equals the entry's;
      - the live tables equal a copy of their pre-computation state with the entry's write slice replayed;
      - the live computation touched no Resource.

      An entry whose read slice does not validate is a miss, not a mismatch; stage 3 counts such misses, because a
      high count would mean the journal costs hits.
    - **Stage 4 and later (CI audit job).** On a hit, before anything is served:
      1. Recompute on the same scope objects with only the `type_of` memo suspended, logging into an isolated journal
         whose refusals do not reach the real captures. The recompute's Table writes go to an undo log keyed on table
         identity, and every Resource slot's contents are snapshotted, in-place mutations included (the transient log,
         the summaries' `:consulted` and `:assumption`, `guard_ends`).
      2. Record the final state of every key either side touches, then undo the recompute's writes and restore the
         Resources.
      3. Serve the entry: validate, replay, and compare the same keys against the recorded state.

      Recomputing on the same objects keeps scope identity, so the one-slot caches hit exactly as they would in
      production. A Resource touch during the recompute is itself a mismatch.
    - **What is compared.** Final table state, not write slices. Stage 0 saw 416–1,104 write-list differences under
      `any`, all differing only in the target scope's identity.
    - **Reporting.** Mismatches are collected per thread and asserted when the run ends. A raise would be swallowed:
      the typing path rescues `StandardError` in many places (#2785).
    - **Where it runs.** CI runs it beside `RIGOR_MEMO_AUDIT` over `lib`, the integration fixtures and the plugin
      fixtures, and on a sample of Mastodon.
  - **G1′ Fault injection, the gate's own gate.**
    - Spec-only switches each disable one mechanism:
      - ignore a Frame slot;
      - skip read validation;
      - skip ABSENT logging;
      - skip the upward merge of a nested hit's reads;
      - skip journaling the replay;
      - refuse only the innermost capture;
      - store a raised computation;
      - skip a restore;
      - skip the Memo-miss-writes-a-Table rule, or its read-through-cache form.

      For each switch, a spec asserts that G1's stage-4 form reports a mismatch on a fixture. The hit-path switches
      (the upward merge, journaling the replay) need a served hit, so G1′ runs the stage-4 form even while the
      corpora run the stage-3 form.
    - Each Frame slot declares one of four things:
      - a witness fixture, on which G1 must fail with that slot ignored. The threaded-flag fixture from Context is a
        witness;
      - `typing_unreachable: true`, which audit mode asserts by failing on any `type_of` while that slot is installed;
      - `typing_never_reads: true`, which audit mode asserts by tracking reads of the slot during typing. This option
        is for slots such as the writer scope, which wrap typing but are read only elsewhere. The effects switch is
        read by `Effects::Collector.record_call`, so it needs a witness, which a synthetic fixture supplies;
      - `memo_shut_while_installed: true`, for the tracer switches, under which the memo never runs. Audit mode
        asserts that no lookup or store happens while the slot is installed.
  - **G2 Perturbation specs per kind**, generic over the registry:
    - Frame: distinct installs give distinct ids, `ensure` restores the id exactly, and an installed value is frozen.
    - Table: an overwrite, or a new key that was read ABSENT, between store and hit makes the hit recompute; for a
      declared read-through cache, the computation's own value does not. An out-of-band clear is restored by the
      replay, in recompute order.
    - Resource: a write, and a read the slot does not exempt, refuse the capture and every enclosing one; an exempt
      read does not, and the guard stack's push and pop each take a fresh id.
    - Nested hit: its read slice reaches the enclosing entry.
    - Memo: each slot is wired to `MemoAudit.check`, and every Memo and computed Table to the key audit (WD1).
  - **G3 Deny-by-default static spec**, Prism over `lib/rigor/{inference,scope*,reflection,analysis,effects,environment,plugin,type,cache}`.
    - It flags:
      - `Thread.current[]`, `thread_variable_get` / `thread_variable_set`, and Fiber storage;
      - `WeakMap` / `WeakKeyMap`;
      - module-level `@x =` / `@x ||=` in singleton methods;
      - a module-level ivar mutated through an index (`@x[k] ||=`);
      - unfrozen constant collections;
      - any direct table access outside `Scope`.
    - Its allow-list names `TypingState` and the process counters (`BudgetTrace`, `MemoAudit`), each with a reason.
      Growing the allow-list needs an ADR line.
    - During stage 1, G3 covers the files converted so far, and each conversion PR adds its own. Until stage 2 puts
      the advisory tables behind slots, the allow-list also names each table read in a covered file.
    - Plugin code is outside G3. It is covered by G1 and the contract sentence below.
    - The precedent is `spec/rigor/run_scoped_slots_spec.rb`.
  - **G4 Reachability audit.**
    - Sampling `type_of` entries over the fixtures, every object reachable from a scope field must be frozen, a Prism
      node, a slot, or a declared Memo. This includes objects reached through `scope.environment`, and it would have
      flagged `MatchRebinding::Frame`.
    - Slot values are walked the same way, which enforces WD1's frozen-Frame rule.
  - **G5 Output gates.** Kept from the second design. They are detectors, not the soundness argument: the first
    design passed them.
    - `--format json --no-cache`, byte-identical with the memo on and off, over `lib`, `plugins/*/lib`,
      `examples/*/lib`, the fixtures, and Mastodon, Redmine and GitLab `app/models` (strict profile, no baseline).
    - The four tables dumped per file.
    - `--workers=2` parity.
    - Warm output equals cold.

    `--verify-incremental` compares memo-on against memo-off only for its cache-served half, so it is not a memo gate.
  - **G6 Hit-rate floor.** CI fails if root-id rule-walk hits fall below a fraction of their baseline. That catches a
    frame that stopped restoring.
  - **Plugins.** The plugin contract gains one sentence: `dynamic_return` and `narrowing_facts` answers are a function
    of their arguments and the environment. Extensional memos inside a plugin stay allowed. G1 over the plugin
    fixtures and the Mastodon sample (ten Rails plugins) is the gate.
- **WD6 — Stages, each with an exit that can stop the work.**

  | Stage | What lands | Exit |
  | --- | --- | --- |
  | 0 (done) | harness ceiling | ≥ 5% of Mastodon CPU beyond the rule walk. Met on the gross count projection (7.1%) and on allocations (11.2 points) under WD3's rule; not confirmed live |
  | 1 | `TypingState` with the four kinds, the id and the journal; behaviour-identical, memo off. Typer and evaluator first (90 of about 240 `Thread.current[]` sites), then the rest; G3 | `engine-wall` 0 ± noise; allocations within the CI band (1%; the harness's frame instrumentation alone measured +0.5% on Mastodon and +0.8% on `lib`); G3 green |
  | 2 | Tables and the one-slot caches behind slots; Memos wired to `MemoAudit` and the key audit; `MemoAudit` collects mismatches per thread (#2785); G4 | the audit job green; settles #2767 |
  | 3 | Shadow only (G1, stage-3 form, on the corpora), with G1′ (stage-4 form, on fixtures) and G2; measure ELIDE under `any` | zero mismatches over `lib`, the fixtures, the plugin fixtures, Mastodon and Redmine; every injected fault detected |
  | 4 | Live in the rule walk | G5, G6; the `engine-warm` `default`-mode leaf and hub rows separate on Mastodon, and `engine-wall` on `lib` does not regress |
  | 5 | Live in the main pass and callee bodies; the recording evaluator's configuration becomes a Frame | as stage 4, plus at least half of stage 0's Mastodon allocation gain beyond the rule walk; RSS within +10% of stage 4 |

  - Stages 1 and 2 pay for themselves without the memo. They make every new piece of typing state reviewable by kind,
    and they settle #2767.
  - Stage 3 is the smallest step that proves the key complete before any output depends on it.
- **WD7 — The contract text.** This PR corrects [`inference-engine.md`](../internal-spec/inference-engine.md) where it
  is wrong today. It does not describe the memo, which does not exist yet.
  - Purity holds per `(scope, node)` under the same ambient inputs, and those inputs are listed. The list includes
    the contents of `optimistic_origins`. The tracer is an output, not an input.
  - The advisory-table paragraph names the reads of `dynamic_origins` that do not decide a type, and the census
    pre-pass bodies that share all four tables.
  - § "Determinism and Caching" allows identity-keyed caches only on those terms, and forbids `==`-keyed ones.
  - `LoopValueRecord` and the inject record are named as caches that may not meet the rule (#2767).

## Alternatives

| Alternative | Verdict |
| --- | --- |
| Memoise everywhere, gating stores on frames being unchanged (first design) | Rejected. Frames are restored by `ensure`, so the comparison detects nothing. It lost a real diagnostic that byte identity missed |
| A rule-walk window with a shut list, stamps and a replay (second design) | Rejected. The lists were built by reading code. Three review rounds each found an input missing, and the gate passed with a mechanism removed |
| A token of interned frame values | Rejected. Installed values are mostly fresh (yield types, sink objects), so only flags would share, and the intern table pins every value. A frame-value vector's ceiling is 112.5K hits against the exact id's 101.3K, and most of that gap is the identical-value case ELIDE covers |
| The `escape` refusal rule, which scopes a Resource touch to its owner | Rejected. 0.05–0.24 points more allocation gain, but it let stale `dynamic_origins` replays through (1 against 0) |
| Storing leaf nodes | Rejected for now. Better allocations on the Rails corpora, but worse on `lib` with +10.8% RSS, for 0.7–1.1% projected CPU |
| An explicit typing-context object passed by hand | Rejected. Not byte-identical by default: about 125 `.type_of(` calls in `lib` and 35 in `plugins/` and `examples/` inherit frames today, and one that forgot the context would type at the default state silently. It replaces only the id, the cheap part; Tables and Resources remain. Its useful half, `State` cached on the typer, is in stage 1 |
| Share call facts across the rules ("option 2") | **Complementary, not part of this ADR.** It needs no memo machinery, only the invariant #2789 states in `CheckRules::CallFacts` (nothing between the first and last rule changes the receiver's ambient inputs), and it takes much of the rule walk's gain (stage 0 measured −19% allocations for a rule-walk memo) without waiting for stages 1–4. It stays valid once the memo exists: it only makes stage 4's rule-walk hits redundant. It can land independently at any time. If it lands before stage 4, stage 4's exit is measured against it, and the case for stages 4 and 5 rests on the main pass and callee bodies |
| Key on `Scope#==` | Rejected. Unsound: `==` ignores the discovery index, lexical nesting, block-self marks, declared refinements and fold-safe locals, all of which typing reads |
| A generic read barrier over every object | Rejected. Ruby has no ivar-read hook, and proxying `Hash` and `Array` on the hot path would cost more than the memo saves |
| Abstract the return memo's key, or seed it from the main pass (#2710) | Rejected. The first changes diagnostics. The second measured under 1% of callee CPU |

## Consequences

- **Gains,** projected from stage 0. Stage 4 must reproduce them on CI.

  | Corpus | Allocations | CPU beyond the rule walk (gross count-mode projection) |
  | --- | ---: | ---: |
  | Mastodon | −30% | 7.1% |
  | Redmine | −18% | 4.2% |
  | `lib` | −5% | 3.0% |

  The rule walk's own share is not in the CPU column: its projection overstated the live figure. The gain grows with
  the number of rules and plugins that re-type a receiver.
- **Costs:**
  - Every change that adds typing state must declare its kind, and G3 enforces it. That is a standing tax on engine
    PRs, paid on purpose: together with the key audit, it turns the class of defect behind #2773 and #2782
    from "found in review" into "fails a gate".
  - Instrumenting the frames cost +0.5% to +0.8% allocations in the harness.
  - RSS rises by +1.6% (Mastodon) to +9.6% (`lib`) with every phase open, close to stage 5's +10% bound on `lib`.
  - Plugin `dynamic_return` and `narrowing_facts` blocks run fewer times.
- **Unchanged:**
  - `lib`-shaped code gains little. #1228 (one shared block entry scope) and #2711 stay the levers there.
  - #2782 is not fixed by this ADR. Stage 2's key audit makes it a named exception instead of a hidden one.
- **Settled on the way:**
  - #2767: the one-slot caches become Tables;
  - #2785: `MemoAudit` mismatches are no longer swallowed;
  - the purity contract's text (WD7).

## Re-evaluation triggers

- **Stage 3 finds mismatches that classification cannot close:** stop at stage 2, which still pays for itself.
- **Stage 4's live rule-walk gain on CI is below half of its projection:** re-evaluate before stage 5, because stage
  5's case rests on the same projection.
- **Stage 4's `engine-warm` does not separate on Mastodon:** stop.
- **ELIDE:** enable it only once G1 shows zero table mismatches with it on, under `any`.
- **Leaves:** revisit if a Rails corpus is the deciding target and `lib`'s RSS is not.
- **A plugin found impure by G1:** fix the plugin, or declare its answers a Resource.

## Relationship to other ADRs

- [ADR-84](84-cross-file-return-memo-scoping.md):
  - its WD3 transient-event bracket is the precedent for the Resource rule;
  - its ADR-46 read-set capture and replay is the precedent for the journal;
  - its memo is a Table here, because WD3 and WD6 make it non-extensional;
  - its key gaps (#2773, #2782) are this ADR's motivating defect class.
- [ADR-127](127-callee-floor-graph-budget.md): `MemoAudit` audits the Memo kind. #2785 is a prerequisite.
- [ADR-55](55-recursive-return-precision.md): its summaries and fuel are Resources, so a computation inside a fixpoint
  is never stored.
- [ADR-56](56-block-captured-local-mutation.md): `BodyFixpoint` rebuilds each pass's entry scope, so no entry crosses
  passes.
- [ADR-46](46-incremental-dependency-graph.md): dependency reads become a journaled Table, after which recording runs
  can open the memo.
- [ADR-52](52-compiled-plugin-contribution-dispatch.md) WD5: answered by the identity key. Its conclusion for plugin
  contribution caches stands.
