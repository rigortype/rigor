# The stage-3 shadow opens in every phase, its table is a Memo checked by G1, and it reports through two switches

- **PR:** [#PRNUM](https://github.com/rigortype/rigor/pull/PRNUM)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2830](https://github.com/rigortype/rigor/pull/2830)
- **Decided:** 2026-11-06

## Background

ADR-129 stage 3 runs the `type_of` memo in shadow form (WD5's G1, stage-3 form) over the corpora. WD4 says the memo
sits on `ExpressionTyper#type_of` in a per-file, run-scoped table, and that which phases open it is a stage decision.
WD6's stage-3 row does not name the phases, the table's kind, the switch, or how the corpus runs report.

## Options and trade-offs

- **Phases:** the rule walk alone (stage 4's scope), or every phase (the main pass and callee bodies too, stage 5's
  scope). Opening every phase changes no output, matches stage 0's measured configuration, and proves the key stages
  4 and 5 both rely on before any output depends on it; each would-be hit is counted per phase, so stage 4 can be
  judged on the rule walk's numbers alone. A callee body is any typing under a non-empty ADR-84 guard stack.
- **The table's kind:** a Memo (an extensional cache, keyed on the state id that carries every Frame) whose hits G1
  checks instead of `MemoAudit.check`, since every would-be hit already recomputes in production; a Resource would
  refuse every enclosing capture on each lookup; a new kind would change WD1.
- **Switch and report:** `RIGOR_TYPE_OF_SHADOW=1`, a process switch read once at load like `RIGOR_MEMO_AUDIT`, and
  `RIGOR_TYPE_OF_SHADOW_REPORT=path`, to which each process appends one JSON line of counters per phase, stale-miss
  slots and up to 50 mismatch samples at exit, so `--workers` runs aggregate by concatenation.
- **Comparing table values:** identity, or `==` element-wise, with a `Scope` compared by identity alone, since
  `Scope#==` ignores fields typing reads.

## Decision

Every phase, reported per phase; a Memo slot (`type_of_memo`) listed beside the stage-2 ratchet as checked by G1; the
two environment switches; identity-or-`==` comparison with scopes by identity. Mismatches are counted and sampled,
not raised: a raise would be swallowed by the typing path's rescues (#2785), and a corpus run reports rather than
stops. The CI step that turns a mismatch into a failure lands separately.

G3's allow-list gains two rows for `lib/rigor/type_of_memo.rb`, the switch (`@enabled`) and the counters (`@stats`),
and ADR-129's G3 bullet names them, as it names `MemoAudit`'s: G3 says growing the allow-list needs an ADR line. The
line records the stage-3 switch the stage-3 row of WD6 already calls for; it changes no decision.

## To undo

Restrict `TypeOfMemo.shadow` to the rule phase, rename the switches, or move the table out of the Memo kind; each is
local to `lib/rigor/type_of_memo.rb`, the two runner hooks and `spec/rigor/typing_state_memo_audit_spec.rb`.
