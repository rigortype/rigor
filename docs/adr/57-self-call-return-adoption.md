# ADR-57 — Opening the implicit-self call return-adoption gate (ADR-24 WD3 revisit)

Status: **Accepted — gate opened 2026-06-12 (slices 1–3).** The
adjudication arc completed: every gate-open firing class was classified
and the artifacts fixed at their root (slices 1–3), the residual reduced
to genuine-or-win, and the gate opened permanently per WD2.
`ExpressionTyper#adoptable_self_call_result?` is removed — a resolved
user-method call unconditionally adopts the callee's inferred return.
Archetype: evaluation-proposal. Stakes: high (the gate existed because of
a measured FP regression; the FP-discipline value binds).

Grounding: the gate-open experiment below (2026-06-12) and the
[2026-06-12 Dynamic-fall survey](../notes/20260612-dynamic-fall-pattern-survey.md)
(bucket B2, re-diagnosed: the survey's "non-constant param" framing was
wrong — toplevel calls with non-constant args already type precisely;
the actual residual is this gate).

## Context

ADR-24 WD3 gates the adoption of a resolved implicit-self call's return
type inside method bodies: only `Bot` (and, since ADR-55, value-pinned
results during an unroll) are adopted; everything else stays
`Dynamic[top]` (`ExpressionTyper#adoptable_self_call_result?`). The
gate was installed because unconditional adoption regressed
`rigor check lib` by 16 diagnostics (measured pre-ADR-55/56).

This is now the **single largest remaining Dynamic source** for plain
procedural Ruby:

```ruby
def helper(x) = x * 2
def outer = helper(3)        # outer → Dynamic[top] (helper resolves; adoption gated)
class S; def run = helper(3); end   # same
def fib(n) = n < 2 ? n : fib(n-1) + fib(n-2)
fib(x)                       # 1 | Dynamic[top] — the gate also blocks ADR-55's
                             # fixpoint summary from reaching in-body call sites
```

Adjacent, measured separately: module-singleton calls
(`Util.triple(x)` for `def self.triple`) type `Dynamic[top]` through a
different resolution path (singleton dispatch on a module constant) —
slice-able independently of the gate.

## WD1 — Gate-open measurement (2026-06-12)

Unconditionally opening the gate (return `true`) on the post-ADR-55/56
engine yields **+25 firings on `rigor check lib`** (baseline: zero).
Distribution:

- ~17 `always-truthy/falsey-condition` warnings — adopted returns
  (often constants or non-nil nominals) folding conditions. Mixed
  population: some will be genuine dead branches, some artifact
  (helper-return imprecision the `Dynamic` had masked — the exact
  failure mode ADR-55's clamp and ADR-56's write-back kept finding).
- 4 `argument-type mismatch` errors on `Configuration.load`-style
  paths — adopted returns now carrying `String? | false`-shaped
  optionality into call sites (genuine-or-artifact per site).
- 1 `possible nil receiver` error, 1 `return-type mismatch` warning,
  2 misc.

The historical "16" is now "25" — the population shifts as engine
precision moves, which is itself the argument for re-measuring per
engine generation rather than treating the gate as permanent.

## Slice 1 results — adjudication + first artifact fix (2026-06-12)

The 25 gate-open self-check firings and the three-corpus delta were
adjudicated; the full itemized table lives in
[`docs/notes/20260612-adr57-adjudication.md`](../notes/20260612-adr57-adjudication.md).
Eight distinct mechanisms were found, grouped genuine vs artifact:

- **Mechanism 1 (15 self-check firings) — FIXED.** The tail-only body
  evaluator dropped explicit `return value` nodes (`type_of_jump → Bot`),
  so a predicate helper `return false unless c; …; true` inferred
  `Constant[true]` and folded `if helper` to always-truthy. The fix
  (`StatementEvaluator#eval_return` + a thread-local return sink, joined
  in `ExpressionTyper#infer_user_method_return`) makes every reachable
  explicit return — including block-internal returns, which in Ruby exit
  the enclosing method — contribute to the inferred return; nested
  `def`/lambda are barriers; flow-pruned dead branches do not contribute.
  Precision-additive gate-closed (zero diagnostic change on `lib`, the
  plugin self-check, and Mastodon/haml/kramdown — all byte-identical).
  Opening the gate after the fix yields **10** self-check firings, down
  from 25.
- **Residual artifacts NOT yet fixed (own slices):** block-captured
  Hash-element / String mutation invisible (mechanism 2 / 8 — the ADR-56
  captured-mutation family extended to `h[k]=v` and `s << x` inside
  escaping blocks; triage:35, diff:48, kramdown html.rb ×3); multi-value
  `return a, b, c` not contributing a Tuple (mechanism 7; haml parser.rb
  ×2 — a direct extension of mechanism 1, the slice-1 collector handles
  single/bare returns only).
- **Residual genuine (not artifacts):** `Configuration.load`'s RBS is
  `?String` but its body is `path || discover` and nil-checks, so the 5
  `argument-type` firings are earned against a too-strict *self-authored*
  RBS (`?String?` is correct); likewise `MethodCatalog#reset!`'s
  `() -> nil` RBS is wrong (the `@catalog = …` assignment returns the
  Hash). Both are genuine sig corrections, not engine bugs. One stub
  (`string_unary_blow_up?` always `false`) is a genuine benign dead
  guard. `loader.rb:76` is sound `Array#find` conservatism the Kahn
  `in_degree.zero?` invariant rules out — FP-risky to ship, needs flow
  narrowing.

Per WD2 the residual is not all-genuine, so the gate stays closed after
slice 1. Next slices: fix mechanisms 2/7/8, then re-adjudicate; the
genuine-via-RBS firings are independently addressable by widening the two
self-authored signatures.

## Slices 2–3 + gate open (2026-06-12)

Slice 2 fixed the two corpus/self-check artifact families the slice-1
adjudication deferred: multi-value `return a, b, c` now contributes a
Tuple (mechanism 7), and an escaping block that content-mutates a
captured outer local floors that local to its bare collection (mechanisms
2 / 8), so an `OptionParser#on { options[:k] = v }` callback no longer
leaves `options` an unsoundly-precise empty seed. The two genuine-via-RBS
firings were resolved by correcting the over-strict `Configuration.load`
parameter and `MethodCatalog#reset!` return signatures.

Slice 3 closed the residual:

- **Escaping content floor — receiver-chain + cross-boundary variants.**
  The slice-2 floor fired only for a block attached directly to the
  statement-level call. The real CLI shape hides the mutating block one
  hop up — `OptionParser.new do |opts| opts.on { o[:k] = v } end
  .parse!(argv)` (block in the receiver chain) and `build_option_parser(
  options).parse!(argv)` (block retained inside a *callee* that received
  `options` as a parameter). The escape handler now walks the receiver
  chain, and a self-call resolving to a user def whose parameter is
  escape-mutated (a memoised per-def body scan) floors the matching
  caller argument. Both are sound (precision-loss only) and gate-closed
  byte-identical.
- **FP-safe optional-tuple-slot destructure.** A destructured tuple slot
  flow-typed as `X | nil` softens to its non-`nil` part. A nil-able slot
  is almost always made optional across a correlated invariant flow
  cannot prove (haml's `parse_tag` 9-tuple; `node, @parent = @parent,
  @parent.parent`); manufacturing a `possible nil receiver` per slot
  frightens working code. This *removed two gate-closed false positives*
  on haml `parser.rb:546` — an adjudicated win.
- **Live String fold-guard.** `string_unary_blow_up?` was an always-false
  stub whose guard folded dead under adoption; it now performs a real
  byte-size check (behaviour-identical for every current fold).

With these, the gate-open delta is: **zero** self-check + plugin-contract
firings; haml / kramdown corpora identical to their (now-improved)
gate-closed baselines; Mastodon shows one firing — the same pre-existing
`compact_blank!` error with a *more precise* receiver type in its message
(a win, not a new firing). The residual is all genuine-or-win, so per WD2
the gate opened permanently: `adoptable_self_call_result?` is removed and
`try_local_def_dispatch` / `try_user_method_inference` adopt the inferred
return directly. The historical `self_type.nil?` / `Bot` /
fixpoint-summary / unroll special cases are all subsumed; the ADR-55 WD1
`clamp_unroll_result` backstop is retained independently.

Cost: the cold `rigor check --no-cache lib` wall rises ~12 % (≈26.7 s →
≈29.9 s) — the intrinsic cost of re-typing resolved callee bodies that
previously short-circuited to `Dynamic`. The obvious per-call-site
return-result memo is deferred: ADR-52 WD5 rejected a per-call-node
result cache on scope-sensitivity / FP grounds, and ADR-24 WD5 forbids
arg-type-keying the recursion guard. A sound result-memo is a queued
perf follow-up; the warm cached path (ADR-45 / ADR-46) is unaffected.

## WD2 — Decision criterion

> The gate opens **per adjudicated firing class, not wholesale**: every
> firing in the gate-open delta (self-check + corpora) is classified
> *genuine* (the adopted type is right and the diagnostic is earned) or
> *artifact* (the adopted type is wrong — an evaluator blind spot).
> Artifacts are fixed at their root (each one is an engine bug worth
> finding — the ADR-55/56 arc fixed five this way); when the residual
> delta is all-genuine, the gate opens, and the genuine firings land as
> wins. Until then the gate stays. No firing class is suppressed to
> force the timeline.

Tier order (each its own corpus-gated slice):

1. **Adjudicate the 25** (self-check) + the corpus delta (Mastodon /
   haml / kramdown gate-open runs): itemized genuine/artifact table.
2. **Fix the artifact classes.** Known suspects from the ADR-55/56 arc:
   block-internal `return` not contributing to a method's return type
   (the tail-only body evaluator), optionality over-joining on early
   returns, constants surviving paths they shouldn't.
3. **Open the gate** (possibly staged: Dynamic-free results first,
   then all), re-measure, land with the genuine firings itemized in
   the CHANGELOG.
4. **Module-singleton resolution** (`def self.x` via module constant
   receiver) as an independent slice — same adjudication protocol.
   **LANDED 2026-06-12.** A call on a module/class constant to a
   user-side singleton method (`def self.x` / `def Foo.x` / `class <<
   self` / `module_function`) now re-types the callee's body against the
   `Singleton[X]` receiver, mirroring the instance-side ancestor walk: a
   new `discovered_singleton_def_nodes` index (the singleton companion of
   `discovered_def_nodes`, populated by `ScopeIndexer` and seeded per-file
   + cross-file), a `Scope#singleton_def_for` accessor, a
   `MethodDispatcher#try_discovered_method` decline so the precise
   inference tier runs instead of the `untyped` short-circuit, and an
   `ExpressionTyper#try_singleton_method_inference` tier whose body scope
   carries the same `Singleton[X]` self-type (so an implicit-self call to
   another singleton helper resolves against the same table). The ADR-55
   recursion machinery and the return memo apply unchanged (both key on
   the receiver carrier, which a `Singleton` satisfies). Own-class only;
   the singleton-ancestry chain (`extend` / inherited class methods) is a
   future slice. Self-check + plugin self-check firing-free; Mastodon
   `app/models` / haml `lib` / kramdown `lib` byte-identical. The CRuby
   `references/ruby/lib` survey surfaced +16 firings, all the precision-
   reveals-latent-strictness class the gate-open protocol predicted (a
   now-resolved singleton return more precise than the consuming RBS sig
   — e.g. `Bundler.root → Pathname` hitting `Pathname#expand_path`'s
   String-only `dir` param, and now-nilable singleton returns surfacing
   genuine nil-safety gaps in rubygems' `setup_command`); these are
   read-only vendored corpus signal, not a `make verify` gate. One
   pre-existing engine defect surfaced through the new entry door (NOT
   introduced by it — reproducible on plain instance methods): the
   mutual-recursion fixpoint folds two-method recursion (`even?`/`odd?`)
   to an unsound one-sided constant; tracked separately. The
   `recursive_fixpoint_summary` fixture's `Parity.even?` assertion was
   updated from `Dynamic[top]` (the old non-resolution) to the now-
   resolved (imprecise but instance-parity) value, with a comment
   flagging the underlying fixpoint limitation.

If ADR-50's bleeding-edge overlay ships first, the opened gate is a
natural first `bleeding_edge:` feature; otherwise it lands as a normal
engine-precision change under the WD2 criterion.

## Rejected / deferred alternatives

- **Open wholesale now, absorb via baseline.** Rejected — 4 of the 25
  are *errors*; FP discipline forbids shipping unadjudicated errors on
  working code (rigor's own CLI works).
- **Keep the gate permanently.** Rejected as a standing position — the
  gate's cost grows as the rest of the engine gets more precise (it now
  blocks ADR-55's summaries); WD1 shows the blocker population is
  finite and enumerable.
- **Adopt only non-value-pinned nominals (skip constants).** Considered
  as tier staging; not a criterion by itself — constant adoption is
  where most of the value (and most of the artifact risk) lives.

## Relationship to other ADRs

- **ADR-24** — this revisits WD3 with its own method: the measurement
  that closed the gate is re-run per engine generation, and the gate
  opens by adjudication, not assertion.
- **ADR-55 / ADR-56** — supplied the blind-spot-fixing precedent (five
  artifact classes found and fixed) and the adjudicated-gate protocol
  (ADR-56 WD4) this ADR adopts; opening the gate is what lets their
  precision reach in-body call sites.
- **ADR-50** — the bleeding-edge overlay is the natural staging vehicle
  if it ships first.
