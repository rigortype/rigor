# How other type checkers bound inference — prior art for Rigor's budgets

*2026-06-03. Survey note — informational, not normative. Companion to
[`20260603-inference-budget-reality-survey.md`](20260603-inference-budget-reality-survey.md);
foundation for a planned ADR on Rigor's ideal budget design.*

## Why this survey

Rigor's [`inference-budgets.md`](../type-specification/inference-budgets.md)
posits a configurable `budgets:` table but the survey companion showed it
is mostly unwired, and that the categories that actually drive cost on
large apps (`union_size`, `structural_growth`) are exactly the unwired
ones. Before designing what to wire and at what defaults, this note maps
how six established checkers solve the same problem: **what keeps type
inference from running unboundedly or producing unusable types, and what
happens when the limit is hit.**

## The two camps

Every tool falls into one of two architectural strategies, and the choice
determines whether it needs inference budgets at all.

**Camp (a) — require signatures at boundaries, infer only locally.**
Inference is confined to a single method body (plus flow-sensitive
narrowing); across method boundaries, types flow only through *declared*
signatures. There is no whole-program fixed point to terminate, so no
widening / iteration machinery is needed — the "budget" is paid by the
human writing the signature. **Sorbet** and **Steep** are pure camp (a);
**mypy** is camp (a) for cross-function return types (it never infers
them).

**Camp (b) — whole-program / deep inference without required
signatures.** The analyzer must impose explicit termination machinery
because it chases types across the call graph. **TypeProf**, **Pyright**,
**TypeScript** (at the type level), and **PHPStan / Psalm** (value
tracking) are camp (b).

**Rigor is camp (b) for return inference** (it infers user-method returns
with no required signature — the recursion guard exists precisely because
of this) **with a camp-(a) escape hatch**: an RBS / inline-RBS / generated
signature at the boundary stops the deep inference. That hybrid is the
design space; the rest of this note is about how the camp-(b) tools tune
their budgets, because that is where Rigor's open questions live.

## Two budget *styles*: counting vs. widening

Within camp (b) there are two ways to enforce a budget, and most tools mix
them:

- **Counting budgets** — a numeric ceiling on work (recursion depth,
  instantiation count, comparison count, array-key count). On hit, either
  **error** or degrade to a sentinel. Sharp, predictable, but the number
  is arbitrary and version-drifts.
- **Widening budgets** — when a type grows past a threshold, *generalize*
  it to a supertype (union → common ancestor; deep type → `untyped`/`any`;
  shaped array → general array). On hit, **silently lose precision** but
  never error. Monotone, so it doubles as the fixed-point convergence
  guarantee.

## Tool-by-tool

### Sorbet — camp (a), no budget needed
Never infers method signatures ("a key part of what allows Sorbet to type
check a codebase quickly"). Inference is local to a method body; an
un-`sig`'d boundary yields `T.untyped` for params and return. Because
"typechecking one method cannot affect another," every method is checked
independently and in parallel — there is no fixpoint, hence no union-size
or iteration limits. The budget is the mandatory `sig`.

### Steep — camp (a), structural termination
Consumes RBS at boundaries, infers locally + narrows within bodies.
Undeclared / `untyped` RBS is the absorbing fallback. `# @type var x: T`
is a manual local cutoff. RBS itself **prohibits non-regular recursive
types**, removing a class of non-terminating expansions at the signature
layer. No global timeout/iteration budget in the checker core — termination
is structural (finite declared types, per-method local analysis).

### mypy — camp (a) for returns; **widening** via join
"Never infers return types and assumes that functions without a return
type annotation have a return type of `Any`." That is the hard boundary
that bounds cross-function work. Within its reach, mypy merges branch
types with a **join** to a common supertype — so `str` and `int` in two
branches infer `object`, *discarding the union*. This is a widening budget
(monotone → fast fixpoint) at the cost of precision; the maintainers track
a long list of join-caused false positives (#12056). No numeric union /
overload cap surfaced; recursive type aliases became default in mypy 0.990
with graceful-reject on divergence rather than a depth constant.

### Pyright — camp (b), **counting** budgets (the dense end)
Infers return types from `return`/`yield` (aggressive), and pays for it
with ~a dozen hard-coded numeric caps in `typeEvaluator.ts`:
`maxInferFunctionReturnRecursionCount = 12`, `maxReturnTypeInferenceStackSize
= 2`, `maxRecursiveTypeAliasRecursionCount = 10`, overload expansion
`64 / 256`, inference sampling `16 / 64`, flow convergence
`maxConvergenceAttemptLimit = 256` (silently "pins" the last type), and a
whole-function `maxCodeComplexity` (~768, version-drifts; was 1024) that —
uniquely — **emits a user-facing error** "Code is too complex to analyze…"
and abandons flow analysis for that scope. Everything else silently
degrades to a cached / `Unknown` type. Uses **union** (precise), never
join — the opposite of mypy.

### TypeScript — camp (b), **counting** budgets (type level)
Termination is guaranteed by hard constants regardless of annotations
(verified against `checker.ts` v5.4.5): instantiation `depth = 100` /
`count = 5,000,000` (→ **TS2589** `errorType`); conditional-type
`tailCount = 1000` (→ TS2589); relationship recursion `depth = 100` (→
**TS2321**); a per-invocation comparison budget `(16,000,000 −
relation.size) >> 3`; subtype-reduction work checkpoint at `100,000`
(abort if projected > `1,000,000` → **TS2590**); cross-product union
`size ≥ 100,000` (→ TS2590). A separate co-inductive guard
(`isDeeplyNestedType`, `maxDepth = 3`) **assumes-related** to let genuine
recursive types (lists, trees) terminate without erroring. Explicit return
annotations are the recommended escape hatch (check body *against* the
annotation instead of inferring + propagating). Most over-budget cases
**error** rather than degrade — the strictest on-hit posture of the six.

### PHPStan / Psalm — camp (b), **widening** of value-tracked types
PHPStan tracks literal values, so its budgets cap *value* precision, all
silently widening (never error): constant-array `ARRAY_COUNT_LIMIT = 256`
(→ general `array<K,V>`), array-literal items > 256 (→ degrade), offset
constraints > 32 (→ `OversizedArrayType`, stops per-key tracking), union
de-dup switch > 16. **Cautionary tale:** PHPStan once had a
`CONSTANT_SCALAR_UNION_THRESHOLD` (community-reported ~8) that widened
large constant-scalar unions to the base type; **removing it caused
out-of-memory regressions** (issue #5527 — base64 lookup tables exploding
into unbounded unions). Recursive aliases / templates that escape
circular-reference detection are treated as *bugs*, not bounded by a
depth budget; an undeclared recursive return bottoms out at `mixed`.
**Psalm** exposes the same array/string budgets as **user-tunable config**
(`maxShapedArraySize = 100`, `maxStringLength = 1000` bytes) — the only
tool in the survey that makes these first-class settings, with an explicit
"changing these may cause unwanted side effects, not bugs" warning.

### TypeProf — camp (b), **widening**; the closest analogue to Rigor
The only Ruby tool that infers without required signatures — whole-program
abstract interpretation, "abstractly executes Ruby at the type level."
`untyped` is "an abstract value generated when TypeProf fails to trace
values due to analysis limits." Its termination primitives (from
`type.rb` / `config.rb`, v0.21.x):
- **`union_width_limit = 10`** — once a union accumulates ≥10 class
  instances, `Union.create` collapses them to a single *degenerate*
  instance.
- **`type_depth_limit = 5`** — `limit_size`/`globalize`/`substitute`
  return `Type.any` once depth reaches 0, so deeply nested / recursive
  types **widen to `Type.any` (≈ untyped)** at depth 5.
- **`max_iter` / `max_sec`** — global fixed-point iteration and wall-clock
  bounds (knobs confirmed; default values not).

Over-budget **widens to untyped, never errors**. TypeProf v1 was ~3 s and
non-incremental; **TypeProf 2** is an AST + dataflow-graph rewrite
(modeled on Tern / SpiderMonkey type inference) making the fixpoint
**incremental** — an edit recomputes only the changed method's subgraph
(~1.0 s full / ~0.029 s incremental on its own ~7k LOC). The widening
primitives stay; the win is re-spending the budget per-edit, not per-run.

## Comparison against Rigor's spec defaults

| concern | Rigor (spec / wired) | nearest analogues |
|---|---|---|
| recursion / type depth | `recursion_depth` 5 / **wired 1** | TypeProf `type_depth_limit` **5**; Pyright return-recursion **12**; TS instantiation **100** |
| union breadth | `union_size` **24** (unwired) | TypeProf `union_width_limit` **10**; PHPStan union-dedup **16**, removed scalar cap ~**8**; TS cross-product **100,000** |
| structural growth | `structural_growth` **16** (unwired) | PHPStan array keys **256** / offsets **32**; Psalm `maxShapedArraySize` **100** |
| on-hit behavior | widen → `Dynamic[top]`, **silent** | widen-silent (mypy, TypeProf, PHPStan, Pyright-mostly); **error** (TS, Pyright `maxCodeComplexity`) |
| boundary escape hatch | RBS / inline-RBS / `sig-gen` | TS explicit return type; Sorbet/Steep mandatory sig/RBS |

## Takeaways for the ADR

1. **Rigor's architecture (deep return inference + boundary escape hatch)
   matches TypeProf most closely**, so TypeProf's `union_width_limit`
   (10) and `type_depth_limit` (5) are the most directly comparable prior
   art — and notably *tighter* than Rigor's spec `union_size = 24`. That
   argues for measuring before trusting 24.
2. **Widening, not erroring, is the mainstream on-hit behavior.** Five of
   six tools silently widen at the budget; only TS errors routinely. This
   validates Rigor's `Dynamic[top]` degrade — but every tool that widens
   silently is criticized for the resulting opacity (mypy's join, Pyright
   "pin"). Rigor's spec answer — emit a `static.*` incomplete-inference
   diagnostic at the cutoff — is the differentiator: *widen like TypeProf,
   but tell the user where, like nobody else does.*
3. **Caps are load-bearing; don't remove them, but set them by
   measurement.** PHPStan's removed scalar-union cap → OOM is the direct
   warning for Rigor's Layer 2: a union/structural cap is what would
   prevent the Redmine 1.5 GB profile, and the right value comes from the
   observed distribution, not a guess.
4. **Psalm is the model for *configurability*** — it exposes the two
   value-precision budgets as documented settings with a "side effects,
   not bugs" caveat. If Rigor makes `budgets:` user-tunable (as the spec
   says), Psalm's framing (and PHPStan's hard-coded-constant counter-model)
   bound the design choice.
5. **The recursion guard is fine as a termination floor at depth 1**;
   TypeProf runs `type_depth_limit` at 5 but it widens to `any` (no
   precision claim), exactly as Rigor's depth-1 widens to `Dynamic[top]`.
   Raising Rigor's effective depth only matters if paired with
   precision-gaining unrolling, which none of the camp-(b) tools attempt
   for general recursion.

## Source confidence

Numeric constants for TypeScript (checker.ts v5.4.5), PHPStan (TypeCombinator
/ ConstantArrayTypeBuilder), Pyright (typeEvaluator.ts / codeFlowEngine.ts),
and TypeProf (type.rb / config.rb v0.21.x) are source-backed. Items flagged
in the source agents as inference: mypy's *absence* of numeric caps (argued
from its join-widening + Any-boundary design, not an explicit statement);
PHPStan's exact removed-threshold value 8 (community-reported); TypeProf
`max_iter`/`max_sec` default values (knobs confirmed, defaults not);
TypeProf 2 retaining the v1 widening constants (architecturally consistent,
not re-confirmed against v2 source). Internal compiler constants
(TS / Pyright) drift between versions — pin to a commit before quoting
normatively.
