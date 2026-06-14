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
   - **Slice 2 (nilable unions, `String?`): ADJUDICATED — DEFERRED (conflicts with the
     deliberate N3 silence).** Investigation found that
     `spec/rigor/analysis/check_rules/safe_navigation_undefined_method_spec.rb` (lines
     65–94, the N3 decision from `20260613-app-network-corpora-survey.md`) *deliberately*
     asserts that a `T | nil` receiver stays silent for `call.undefined-method` even when
     the method is absent on `T` — for both `y&.m` and plain `y.m` — explicitly to avoid a
     working-code false positive on a **cross-file project def**. That FP class is real and
     is *not* fully eliminated by `method_present_anywhere?`: a project class that is
     RBS-known but whose method is defined cross-file (a reopened class / an
     association/scope the dispatcher does not apply per-file) would resolve as "absent"
     and fire. So firing on nilable unions is not a quiet teeth fix — it overrides a
     deliberate, FP-motivated design decision. **Recorded as an open ADR question**: can
     the N3 silence be *narrowed* to fire only when every non-nil arm is a fully-known
     core/stdlib class (where the cross-file-def FP cannot arise)? That needs a corpus FP
     study before any change. This is the adjudication discipline working — not every
     survivor is a bug; some are intentional silence.

     **Corpus FP study (2026-06-14) — DONE; verdict: the narrowing is REJECTED, N3 silence
     KEPT.** A bundled-arm-narrowed candidate (`Class`/`Module` excluded, plain calls only)
     was run across 13 projects (ActiveSupport-heavy liquid/mail/herb/slim/strap +
     plain kramdown/net-ssh/parser/oj/faraday/haml/hamlit/tdiary-core). Result: **zero
     genuine nilable-union firings** — ~0 real-world teeth gain. The self-check meanwhile
     surfaced a real **loss-of-specificity FP** (`plugin_class : Class` holds a `Plugin`
     subclass with `.manifest`), exactly N3's concern. ~0 benefit + demonstrated
     FP-proneness + the cost of overriding a deliberate decision ⇒ not worth it. **Two
     guards harvested and KEPT on the shipped slice-1**, however: (a) a generic-metaclass
     guard (`Class`/`Module` arms can't have singleton methods enumerated), and (b) a
     **distinct-class guard** — slice-1 fires only on a genuinely multi-class union, not a
     same-class shape join (`Hash[K1,V1] | Hash[K2,V2]`), which **fixed a real external
     slice-1 FP** the study found on mail (`compose_codepoints` mistyped `Hash | Hash` for
     an `Array`, flagging `.pack`). So the rejected feature still produced two FP
     hardenings of shipped code. `make verify` clean; union spec now 5 examples.
3. **Mutex / Thread core-class coverage — LANDED (RBS class-alias resolution).**
   Root cause was *not* a missing import: `Mutex` is an RBS **class alias**
   (`class Mutex = Thread::Mutex`, `references/rbs/core/thread.rbs:1822`). It lives only
   in `env.class_alias_decls`, so `RbsLoader#class_known?` reported it but
   `build_instance_definition` / `build_singleton_definition` (guarding on `class_decls`)
   could not enumerate its methods — leaving every alias class with no resolvable method
   surface (dispatch widened to `Dynamic`, undefined-method never fired). Fix:
   `canonical_module_name` normalises an alias to its target via
   `env.normalize_module_name?` before the guard, so dispatch *and* the existence check
   work on `Mutex` and any `X = Y`. `make verify` clean (lib uses `Mutex` in several
   places — no FP); 5-example loader spec; the Mutex survivor cluster now kills. A general
   win beyond the cluster.
4. **Broad-fuzz mode — LANDED (the `両方を段階的に` robustness half).** `mutate.rb fuzz
   <paths…>` runs the warm loop with aggressive un-filtered mutation (every operator, every
   site) and reports mutants that crash the analyzer (`internal analyzer error:` — its own
   rescue), hang (per-mutant timeout), or — with `--repeat` — return non-deterministic
   diagnostics (which would break the cache's byte-identical contract). First run: **2,706
   mutants over all of `lib/rigor`, zero crashes / hangs** — the analyzer is robust against
   arbitrary type-visible mutation of its own tree. A clean result is itself the
   deliverable (robustness evidence).
5. **`argument-type-mismatch` cluster — ADJUDICATED + partly LANDED (refined-receiver
   dispatch).** The cluster was mixed. Its real part was not an `argument-type-mismatch`
   weakness at all but a *receiver-resolution* gap: a refinement receiver
   (`non-negative-int` = `Type::IntegerRange`; `non-empty-string` = `Type::Refined`) had no
   `concrete_class_name`, so **all three** call rules (undefined-method / wrong-arity /
   argument-type-mismatch) bailed. Fix: `concrete_class_name` resolves `Type::IntegerRange`
   → `"Integer"` and `Type::Refined` → its base, so e.g. `n >= nil` on an `arr.select{}.size`
   now fires. `make verify` clean (refined receivers are everywhere in lib); 3-example spec.
   The *residual* `non-negative-int` survivors are **correct silence**: they are arguments to
   `==` (`lines.size == 1`), exempt via `UNIVERSAL_EQUALITY_METHODS` (Ruby's `==` returns
   false on type mismatch, never raises). A harness de-noise (skip literal mutations whose
   enclosing call is a universal-equality method — `UNIVERSAL_EQUALITY` in `mutate.rb`)
   **LANDED**, mirroring the arity guard; those residual survivors are gone.
   The `Type::*` self-dogfood sub-item remains the ADR-24 deferred area (the
   `call.self-undefined-method` rule ships `:off`). *(argument-channel core: resolved)*
6. **ADR — LANDED: [ADR-62](../adr/62-mutation-testing-teeth-measurement.md).** Folds the
   methodology + decisions (build-our-own, type-aware filter as the meaning-maker,
   sweep-as-backlog, adjudicate-don't-assume) and the landed/deferred items into a
   decision record. This note remains the living tracker; the ADR is the rationale.

## Cumulative result (`lib/rigor`, `--per-file 12`)

After the three engine fixes (union teeth, class-alias resolution, refined-receiver
dispatch) and the three harness de-noise refinements (union-Dynamic/bot, arity-off-default,
universal-equality):

| | first sweep | after |
| --- | --- | --- |
| teeth (kill %) | 61.7 % | **71.4 %** |
| survivors | 856 | **611** (−29 %) |
| `undefined_method` killed | 1095 | **1508** |

More importantly, the **top residual clusters are no longer easily-fixable misses** — they
are (a) the deliberate ADR-24 self-dogfood deferral (`Type::Constant#value` 44,
`Type::Tuple#elements` 15, the project-class `MethodCatalog` singleton — the
`call.self-undefined-method` rule ships `:off` pending its external FP gate) and (b)
*correct silence*: `OptionParser#on` (many overloads → the arg rule needs a single one to
refute), `File.join` (rest-positional args are deliberately not arg-checked), `Hash#[]` /
`fetch` (any key is valid Ruby). The easily-actionable engine backlog is worked down; what
remains is design-level (nilable-union N3 narrowing — needs a corpus FP study) or a feature
(user-facing type-protection coverage).

## Productized into a user command — ADR-63 (2026-06-14)

The "user-facing type-protection coverage" feature shipped as
[ADR-63](../adr/63-type-protection-coverage.md): `rigor coverage --protection` (Tier 1, a
static dispatch-site receiver-concreteness proxy) and `rigor coverage --protection
--mutation` (Tier 2, the per-file *actual* mutation kill rate). Tier 2 lifts a **narrow,
curated subset** of this dev harness into `lib/rigor/protection/` — the type-visible
`Mutator`, the type-aware filter, the warm loop, and the kill criterion — as the supported
`Protection::MutationScanner`; this harness's `mutate.rb` now **reuses the lib `Mutator`**
(one source of truth) and keeps only the dev-only sweep / fuzz / survivor-clustering
tooling (ADR-62 WD4 holds). Framing is load-bearing: effectiveness / where-to-add-a-type,
never raw survival.

## CRuby `lib/` sweep + the multi-overload-nil argument fix (2026-06-14)

A second, larger corpus: a `--per-file 40` sweep over all of CRuby's `lib/` (626 files —
stdlib + vendored bundler/rubygems). **8,611 type-relevant mutants, teeth 53.1%, 800
survivor clusters.** Filtering the already-adjudicated buckets (vendored `Bundler` /
`Gem::*` needs-RBS, the deliberate nilable `String?` N3 silence, `Hash#[]` / `fetch`
any-key, `File.join` rest-args) left the **`call.argument-type-mismatch` channel** as the
dominant real candidate (String / Integer / File / MatchData / Array receiving a `nil` /
wrong-typed literal).

Root cause, mapped with a controlled `.rbs` experiment (a class with plain-nominal,
interface-alias, multi-overload, and nilable params each called with `nil`) — **two gates**:

- **Gap A — multi-overload bail.** `argument_type_diagnostic` did `return nil unless
  method_def.method_types.size == 1`, so `5 * nil` (`Integer#*` = 4 overloads) never
  reached argument checking even though it raises `TypeError`.
- **Gap B — interface-alias params.** A `string` (`String | _ToStr`) / `int`
  (`Integer | _ToInt`) param does not *definitively* reject `nil` (the interface arm
  translates to a gradual type), so `"a" + nil` stays silent even at a single overload.

**Gap A LANDED (FP-safe, nil-only).** `argument_mismatch` now extends to multi-overload
methods via `nil_argument_mismatch_across_overloads`, firing only when a **pure-`nil`
argument is rejected by every overload's matching positional param**. Restricting to `nil`
is the FP-safe core: `nil` never participates in the `coerce` protocol, so a `nil` no
overload accepts is a guaranteed error — unlike a non-nil argument a numeric overload
"rejects", which can be valid via `coerce` (`5 + Money.new`). Conservative envelope: any
overload with rest / keyword params, a gradual (interface-alias) param, or one that admits
nil suppresses it, and a declaration-sourced ivar nil is excused (ADR-58 parity). Mirrors
the union-undefined-method "rejected on every arm" shape.

**Gap B LANDED too (FP-safe, nil-only).** The nil channel is unified onto a
`param_admits_nil?` predicate evaluated on the **RBS parameter type** (not the translated
Rigor type, which is exactly what loses the interface info). It resolves a type alias
(`RbsLoader#expand_type_alias`: `string` → `String | _ToStr`) and decides an interface by
whether NilClass implements every required method (`interface_method_names` ∩
`nil_class_has_method?` — NilClass has no `to_str` / `to_int`, so `string` / `int` reject
nil; a hypothetical `_ToS` would admit, since `NilClass#to_s` exists). Conservative
throughout: only a concrete non-nil-ancestor class instance and an interface NilClass fails
to satisfy return "rejects"; every other RBS form (optional, bases, tuple, proc, …) admits.
This makes single-overload interface params (`"a" + nil`, `"a".include?(nil)`) and
multi-overload interface params (`[1, 2, 3].fetch(nil)`) fire. Still nil-only (the coerce
concern), still ADR-58-excused.

- **Gate:** `make verify` clean (6331 + 8 examples, self-check `lib` (0 arg-mismatch) +
  check-plugins, all precision snapshots); **corpus FP gate — zero new firings** across the
  same 12 `rigor-survey` projects; regression spec broadened to
  `nil_argument_mismatch_spec.rb` (both gaps).
- **Re-measure (loop closed, byte-stable 8,611 mutants):** teeth **53.1% → 53.8% (Gap A) →
  57.7% (Gap A+B)** — Gap A **+66 killed**, Gap B **+334 killed**, total **+400 killed /
  −400 survivors, +4.6 pts**. Gap B's drops are exactly the targeted clusters: `nil_inject`
  on `String` −103, `singleton(File)` −51, `Array`/`Array[T]` variants (−34 / −22 / −19 /
  …), the `"…"` String literal −30. No survivor count rose.

**Refinement-receiver (Difference) follow-up LANDED.** The next sweep's top clean cluster
was `undefined_method` on `non-empty-array` / `non-empty-string`: these refinements are a
`Type::Difference` (`Array - []`, `String - ""`, `Integer - 0`, `Hash - {}`), a carrier
`concrete_class_name` did not handle (the earlier refined-receiver fix covered only
`Type::Refined` / `Type::IntegerRange`), so all three call rules bailed. One case —
`when Type::Refined, Type::Difference then concrete_class_name(type.base)` — resolves a
difference to its base (minuend) class, since subtracting *values* never changes the method
surface. Gate: `make verify` (6333 + 8), self-check / check-plugins 0, snapshots, **zero
new firings** across the 12 corpus projects (all three call rules); spec added to
`refined_receiver_dispatch_spec.rb`. Re-measure: **+57 killed, 57.7% → 58.4%**, drops in
`non-empty-array` / `non-empty-string` undefined_method *and* their nil_inject
(argument-type-mismatch now reaches them too).

**Session total (three slices over CRuby `lib/`):** teeth **53.1% → 58.4% (+5.3 pts),
+457 killed**, every slice FP-gated to zero new corpus firings.

**Still deferred:** the non-nil (`type_swap`) channel — a non-nil arg a numeric overload
"rejects" can be valid via `coerce`, so widening past nil needs a coerce-aware model.

## Loop demonstrated

`String | Symbol` was the first sweep's top real cluster → diagnosed as an intentional
union bail → FP-safe fix → `make verify` green → harness re-measures the cluster as
**killed**. The CRuby-`lib/` argument-channel work repeated the loop on a fresh corpus and
scaled it: the multi-overload numeric-nil and interface-alias-nil clusters (`Integer#*`,
`String#+`, `File.*`) went from survivors to **+400 kills, teeth +4.6 pts**, FP-gated to
zero new corpus firings. Find → fix-at-root → corpus-gate → re-measure-kill: the harness is
a self-improving loop, not just a report.
