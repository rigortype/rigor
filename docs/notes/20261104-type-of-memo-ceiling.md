# The `type_of` memo's ceiling under a state-id key, and what two design reviews agreed on

Status: measurement note, no design commitments. The grounding for [ADR-129](../adr/129-type-of-result-memo.md). Taken
on 2026-11-04 with the harness at `726e61af0` on branch `work-census-harness` (based on master `7d0b051e8`;
`tool/work_census/memo3.rb` and `memo3_shadow.rb`). It answers one question: once a memo is keyed so that it cannot serve a result computed under
other ambient state, how much repeated typing is left to remove outside the rule walk?

## Why the question

[The census](20261104-work-multiplier-census.md) found that 74% of Mastodon's `type_of` calls repeat an identical
`(scope object, node)` pair. A memo keyed on that pair alone is wrong. A nested block enters with the enclosing scope
object (`Scope#entering_opaque_block` returns `self`), so one pair is typed under different frames and a real
`call.undefined-method` was lost. The second draft of ADR-129 limited the memo to the rule walk. Three review rounds
each found another input its lists had missed, and a landing gate that could not fail. Two independent design
reviews followed:

- Fable 5.1, at xhigh effort;
- Opus 5.5, at xhigh effort, without reading Fable's report.

Neither review is checked in. This note keeps what they agreed on and what the measurement decided.

## What both reviews found independently

A token that snapshots the installed frames does not cover typing's hidden state. Three more kinds exist, and both
reviews named each one with the same code sites:

- **State mutated in place:**
  - the unroll fuel, decremented with no restore (`ExpressionTyper#unroll_fuel_remaining`);
  - the ADR-55 summaries, down to their `:consulted` flag;
  - the recursion-guard stack, pushed and popped on one array.
- **Counters read as a before/after delta:**
  - `LoopValueRecord.loops_evaluated`;
  - the fixpoint's consult mark;
  - the ADR-84 transient-event mark.

  A memo hit skips the increment, so whatever reads the delta sees a different value.
- **One-slot caches keyed on scope identity:**
  - `LoopValueRecord`;
  - the inject-accumulator record;
  - `MatchRebinding::Frame#memo`, a mutable object reachable from a frozen scope.

Both also concluded:

- a fix has to classify state by kind where the state is declared, with a deny-by-default static spec, rather than
  enumerate keys;
- table reads must be logged and validated on a hit, and merged into the enclosing computation's log on a nested hit;
- interning tokens is not worth it.

Opus added several points:

- Typing state also lives outside `Thread.current[]`: in `thread_variable_set` (`Plugin::IoBoundary`,
  `RunDisclosureCredit`) and in module-level ivars.
- `FlowTracer.active?` changes `Combinator.union`'s fast path, so it is an input, not only a bypass.
- A gate needs fault injection, so that it is shown to fail when a mechanism is removed.

Fable added:

- `MemoAudit::Mismatch` is a `StandardError`, so a `rescue StandardError` on the typing path swallows it inside
  shadow mode (filed as #2785 for the existing audit).
- A leaf node is not worth storing.

The same inventory found that the ADR-84 return memo's own key omits two of these inputs:

- the reflective-ivar repeat depth (#2773);
- the block-body threading suppression, filed as #2782.

That is the same failure class, inside a memo four review cycles old.

## Method

`MEMO=3` installs a live memo keyed on `(scope identity, node identity, state id)`:

- **State id:** a module-level integer. Every frame install takes a fresh id, and the frame restores the old id on
  exit. Every in-place resource write also takes a fresh id; the guard-stack owner restores its saved id at drain.
- **Frames covered:**
  - the yield and forwarded-argument frames, the threaded flag and the repeat depth;
  - the six jump sinks and the retry frames;
  - the key-presence walk, the Acceptance refusal key, the writer-scope key and the unentered-evaluator key;
  - the tracer switches.
- **Refusal rules:**
  - `escape`: refuse a computation when a sink push or a resource write targets a slot installed outside it;
  - `any`: refuse a computation that touched any resource or sink.
- **Replay:** advisory-table writes are replayed on a hit, as in prototype v2.
- **Scope of the memo:** it is cleared per file, and `MEMO_PHASES` selects the rule walk, the main pass and callee
  bodies.
- **Shadow mode:** `SHADOW=1` recomputes every hit with the memo suspended. It compares the type and the four tables'
  state after a replay with their state after a recompute.

Corpora: Mastodon `app lib` (10 Rails plugins), Redmine `app lib`, and Rigor's `lib`.

- The private copies are from the census.
- The output is `--format json --no-cache --workers=0`, with no baseline and a strict profile.
- Base runs alternated with memo runs.
- The host's load average was about 70 on 12 cores, so live CPU is noise. The decision rests on allocations, which
  are deterministic, and on a count-mode CPU projection. The projection is the CPU of the outermost would-be hits,
  minus the counter's own bookkeeping. It is gross: lookup and store are not subtracted.

## Results

Δ is against base. `r` is the rule walk, `m` the main pass and `c` callee bodies. `_e` and `_a` are the refusal rules.

| Configuration | Mastodon alloc | Mastodon CPU (noisy) | Redmine alloc | `lib` alloc | `lib` RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| frames instrumented, memo closed | +0.5% | +4.9% | — | +0.8% | — |
| `r_e` | −18.95% | −6.5% | −10.87% | −2.00% | — |
| `rm_e` | −23.37% | −4.6% | −14.48% | −2.63% | — |
| `rmc_e` | −30.15% | −15.5% | −18.22% | −5.36% | +4.3% |
| `rmc_a` | −30.10% | −13.3% | −18.14% | −5.12% | +9.6% |
| `rmc_e`, leaves stored | −30.97% | −9.9% | −19.57% | −4.87% | +10.8% |
| `rmc_e`, identical installs keep the id | −31.48% | −16.0% | −20.12% | −6.43% | +5.3% |

Base figures:

- Mastodon: 43.4 s CPU, 98.3M allocations, 2,783 diagnostics.
- Redmine: 37.5 s.
- `lib`: 53.8 s, 75.75M allocations.

**The residual beyond the rule walk** (main pass plus callee bodies):

| Corpus | Allocations | Count-mode CPU projection |
| --- | ---: | ---: |
| Mastodon | 11.2% | 2.85 + 4.40 = 7.25% |
| Redmine | 7.4% | 1.87 + 2.38 = 4.25% |
| `lib` | 3.4% | 0.75 + 2.34 = 3.09% |

**Correctness:**

- Diagnostics: −0 / +0 in every configuration and every rep, on all three corpora.
- Shadow mode suspended only the `type_of` memo; the ADR-84 return memo and every other memo stayed live.
  - Hits checked under `rmc_a` (the `any` rule): 101K on Mastodon, 158K on `lib` and 119K on Redmine. All
    configurations together: 101K–236K, 158K–652K and 119K–394K.
  - Types mismatched **0** times. No recompute was refused, and none moved the id.
  - The harness neither logged nor validated Table reads, so these hit counts are an upper bound. In particular, an
    entry whose computation read a key ABSENT and then wrote it would invalidate itself under plain read
    validation; ADR-129's read-through-cache rule exists for that case.
  - The harness refused on resource writes only. A rule that also refuses every resource read measured −24.2%
    allocations on Mastodon instead of −30.1% (the round-2 review of ADR-129). ADR-129 states the two read
    exemptions that make the writes-only count its rule.
- A recompute's write list differed from the stored one 416, 846 and 1,104 times under `rmc_a` (Mastodon, `lib`,
  Redmine). In the 60 samples per run, the lists differed only in the identity of the target scope. The final table
  state is what the comparison below uses.
- Table state after a replay mismatched a recompute 1 time under `rmc_e` (`lib`), 0 times under `rmc_a`, and 167,
  198 and 43 times when identical installs kept the id.
  - Each mismatch is a `dynamic_origins` cause written inside a callee body during a nested inference. On a later
    recompute the ADR-84 return memo answers without walking the body, so the replayed cause is stale.
  - This is the read-back class both reviews predicted.
  - No `check` output changes, and `coverage --protection` on the repro file (`lib/rigor/inference/
    alias_mutation_floor/reach.rb`) is byte-identical.

**Refusal rules:**

- `any` loses 301 main-pass hits on Mastodon (20,528 against 20,829) and refuses 6,808 computations against 72.
- Its allocation gain is 0.05, 0.24 and 0.07 points smaller (Mastodon, `lib`, Redmine).
- The rule walk starts only about 5 callee bodies per corpus.
- Under escape, refusals over Mastodon's 1.45M calls were 9,294 for resource writes, 750 for escaping events, 68 for
  internal events and 105 for sink pushes.

**Leaves:**

- Storing them adds 135K hits on Mastodon and 494K on `lib`, projected at 0.8% and 0.66% of CPU.
- `lib`'s allocations get worse (+0.5 points), and its RSS rises to +10.8%.

**Key granularity** (outermost non-leaf hits on Mastodon):

| Key | Hits |
| --- | ---: |
| `(scope, node)` alone | 115,807 |
| the exact id | 101,316 |
| the id, keeping it across an identical install | 111,966 |
| a vector of frame values (the interning ceiling) | 112,512 |

- Most of the gap is rule-walk lookups missing main-pass entries, because `eval_def` installs a nil return sink over a
  nil one.
- One-way per-node slots lose under 0.3% of hits.
- 94% of the census's `(scope, node)` repeats survive the exact id.

## Limitations

- The id lives in module variables, not in a per-thread slot. `--workers=0` only.
- Under escape, events refuse every open computation, as in prototype v2. `any` counts writes, not reads.
- The frame-value vector omits the summaries' contents, so the interning ceiling may be unsound.
- The KeyPresenceGuard re-walk is counted as main pass.
- One Redmine run died in a YJIT panic ("YJIT should only see live objects"). The rerun was clean.
- The corpora are the census's private copies, not a fresh sync of the survey checkouts.
