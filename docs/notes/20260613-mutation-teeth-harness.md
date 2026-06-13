# Mutation-testing the analyzer — a teeth / false-negative harness

Status: working note + living backlog. Authored against Rigor v0.1.19 (post-release,
`[Unreleased]`). Records the `tool/mutation/` harness, its corpus sweep of `lib/rigor`,
the ranked false-negative backlog it produced, and the fixes landing from it. This note
is non-normative; it is intended to feed an ADR once the backlog is worked down.

## Why

Rigor's whole development discipline is **anti-false-positive** — "the program works"
outranks a worst-case static reading, and the corpus byte-identical gates measure *did we
change behaviour*. Nothing systematically measured the **dual**: *do we have teeth at
all* — where does breaking the code fail to make Rigor complain (false negatives /
blind spots)?

The harness answers that with a mutation-testing technique: take a file Rigor reports
clean, inject a **type-visible** mutation, re-run the analysis on the mutated bytes, and
read a *surviving* mutant (no new diagnostic) as a false-negative candidate. It is the
false-negative sibling of the `rigor-regression-sweep` skill (which tracks
false-positive / surfaced-diagnostic drift).

## Mechanism (`tool/mutation/mutate.rb`, dev-only, off the ADR-50 frozen surface)

- **Mutator** — Prism-native, byte-range *source splices* (no unparser needed; the
  analyzer re-parses the spliced source). Operators, each aimed at a rule family:
  `nil_inject` / `type_swap` (a call-argument literal → `nil` / opposite-typed literal →
  `call.argument-type-mismatch`), `undefined_method` (rename a call site →
  `call.undefined-method`), `arity_extra` (append an arg inside `(...)` →
  `call.wrong-arity`). Only call sites and bodies are mutated, never `def` signatures, so
  a reused project scan stays valid.
- **Warm loop ("editor mode + cache")** — `LanguageServer::ProjectContext` builds the RBS
  environment and the whole-project `ProjectScan` **once**; each mutant reuses them via
  `Runner.new(environment:, prebuilt:)` + `#run_source` (in-memory overlay, no disk
  write). Passing `prebuilt:` makes `run_result_cacheable?` false, so the run-result cache
  — which digests the *disk* file — is bypassed and a mutant is never served a stale clean
  hit. Measured: ~400 ms cold, then ~6–12 ms/mutant (~70× cheaper than a cold run).
- **Type-aware filter (Phase 1.5, default on)** — the metric is meaningless without it.
  A type checker only sees a subset of bugs; most mutations are type-invariant (equivalent
  mutants) and survival is *correct* (FP discipline). Each mutation carries an *anchor* —
  the call receiver whose contract it could violate — probed once via
  `ScopeIndexer.index` + `Scope#type_of`; a mutation is kept only if its anchor types to a
  concrete, non-`Dynamic`/`Top` type. FP-safe: an unresolved type *keeps* the mutation.
  This is why the harness is in-process Prism-native, not `mbj/mutant`: only an in-process
  tool can ask the engine for its own types. A/B (`--no-type-filter`): `trinary.rb`
  43% kill / 33 survivors → **100% / 0**; `ci_detector.rb` 0% / 44 → **83% / 1**.
- **Sweep** — `mutate.rb sweep <paths…>` runs every `.rb` over one warm session and
  groups survivors by `(operator, receiver type)` into count-ranked clusters (top methods
  + example sites). `--json` emits the same as structured data (ADR-61 flavour) so an
  agent can act on it. The build/decision: **build-our-own confirmed, `mutant` rejected**
  (type-aware site selection needs the engine in-process; Prism vs whitequark mismatch is
  harmless only at the source-text boundary).

## Corpus sweep — `lib/rigor`, 285 files, `--per-file 12`

2,237 mutants analysed; **teeth 61.7%**; 856 survivors → 304 clusters. (The headline %
is *not* the story: it is inflated by arity noise and deflated by the argument channel.
The ranked clusters are the signal.) Per-mutant median 9.4 ms, p90 41.6, max 463
(`statement_evaluator.rb` — confirms this is CI-time, not interactive).

The top clusters split cleanly into **harness noise** (→ tool refinements) and **real
engine gaps** (→ the backlog).

### Harness noise (equivalent mutants — fix in the tool, not the engine)

- `arity_extra` on **variadic / optional-arg** methods: `Data.define` (45),
  `Type::Combinator.union`/`public_send` (21), `File.join` (15), `JSON.pretty_generate`
  (10), `Marshal.dump` (6), `Array#push` / `Hash#fetch`. Appending an arg is valid Ruby →
  correct non-fire. *Biggest single noise source.* Fix: only mutate when the resolved
  signature is fixed-arity (or retire the operator).
- `undefined_method` on a **union with a `Dynamic` arm** (`Array | Dynamic[top]`.inspect
  20+13, `Dynamic[top] | []`) and on **`bot`** (8): gradually valid / unreachable →
  correct. Fix: the type filter should treat a union-with-Dynamic-arm and `bot` as
  non-concrete.

### Real engine backlog (ranked by confidence)

| confidence | cluster (count) | reading |
| --- | --- | --- |
| **high** | `undefined_method` `Mutex#synchronize` (13) + `Mutex.new` (7) | core **Thread/Mutex** methods don't resolve → likely a missing builtin import. |
| **high** | `undefined_method` `String \| Symbol`.to_s/to_sym (12), `String?`.downcase/hex (6) | **union / nilable receiver** doesn't fire undefined-method even when no concrete arm has the method. |
| medium | `undefined_method` on Rigor's own `Type::Constant#value` (22), `Type::Tuple#elements` (13), `Type::Singleton#class_name` (8), `Type::Nominal#class_name` (6) | self-dogfood: Rigor's **own `Type::*` carriers lack method RBS** → no teeth on them. |
| mixed | `argument-type-mismatch` into `Hash#[]` (18), `Set[]` (19), `Integer#>=` (19), `String#sub` (8) | lowest-teeth channel — but needs per-site adjudication (`h[nil]` is *correct*, any key; `Integer#>=(nil)` is a *real* miss). |

## Plan (easiest-first), and landings

1. **Harness de-noise — LANDED `599a7922`+1.** The type filter now treats a union with
   any `Dynamic`/`Top`/`Bot` arm (and bare `bot`) as non-concrete (`non_concrete_type?`),
   and `arity_extra` is dropped from the default operator set (most Ruby methods accept an
   extra arg → equivalent mutant; still selectable via `--operators` for arity-teeth
   measurement). `type_node` sweep: 16 survivors (incl. `Data.define` arity + `Array |
   Dynamic[top]`.inspect noise) → **3, all real candidates** (`ResolverChain#freeze`,
   `non-negative-int#>=` ×2). The backlog is now trustworthy. A signature-arity guard that
   would make `arity_extra` default-worthy is a follow-up.
2. **Union / nilable receiver teeth** —
   - **Slice 1 (non-nil unions): LANDED `a07195bd`.** `call.undefined-method` now fires on
     a union receiver when the method is absent on *every* non-nil arm
     (`union_undefined_method_diagnostic` in `check_rules.rb`), reusing the FP-safe
     `method_present_anywhere?` per-arm primitive + an arm guard that bails on any open
     (ADR-26) / synthesized / singleton / module-mixin arm. The scalar path's union bail
     was *intentional*; this adds teeth only where soundness is total (`A | B` responds to
     `m` iff both do). `make verify` clean (no new firing across lib 286 + plugins 141);
     4-example regression spec; the `String | Symbol` survivor cluster now kills.
   - **Slice 2 (nilable unions, `String?`): pending** — deferred because the nil arm
     interacts with `possible-nil-receiver`, safe-navigation, and ADR-58
     declaration-sourced nil.
3. **Mutex / Thread core-class coverage** — investigate why `Mutex#synchronize` /
   `Mutex.new` don't resolve; import via the builtin pipeline. *(pending)*
4. Self-dogfood `Type::*` method RBS; `argument-type-mismatch` adjudication. *(pending)*
5. **ADR** — fold the methodology + decisions (build-our-own, type-aware filter as the
   meaning-maker, sweep-as-backlog, the FP-safe union teeth rule) into an ADR once the
   backlog is worked down.

## Loop demonstrated

`String | Symbol` was the sweep's top real cluster → diagnosed as an intentional union
bail → FP-safe fix → `make verify` green → harness re-measures the cluster as **killed**.
Find → fix-at-root → re-measure-kill: the harness is a self-improving loop, not just a
report.
