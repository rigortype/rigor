# Module-singleton facade: the cross-file discovery seed

Design note for the GitLab improvement plan's **P2 item 6** ([`20260708-gitlab-type-coverage-improvement-plan.md`](20260708-gitlab-type-coverage-improvement-plan.md)),
written 2026-07-10 before implementation. The decision it settles is recorded as a WD on
[ADR-57](../adr/57-self-call-return-adoption.md), whose tier-4 already names module-singleton
resolution as "an independent slice — same adjudication protocol".

## What was believed, and what is actually true

The resume bookmark and the `ScopeIndexer` source comment both framed this as a **P1-scale engine
slice** blocked on an unsound dispatch fall-through. Direct measurement (2026-07-10) overturns most
of that framing. The four facts below are each reproduced by a probe, not inferred from reading.

**F1 — modules are already `Singleton[M]` per-file.** `ScopeIndexer#record_declarations`
(`scope_indexer.rb:2220`) registers `Prism::ModuleNode` and `Prism::ClassNode` identically. Only the
project-wide seed `collect_class_decls` (`:2141`) excludes modules. So the *typing semantics* of a
module constant have shipped in every release and run over every corpus; what is missing is purely
the cross-file reach.

```
$ ScopeIndexer.discovered_classes_for_paths(["a.rb", "b.rb"])
#=> {"Widget" => singleton(Widget)}          # module Feature is absent
$ ScopeIndexer.discovered_def_index_for_paths(...)[:singleton_def_nodes]
#=> {"Feature" => [:enabled?], "Widget" => [:build]}   # both present
```

**F2 — the exclusion comment's stated blocker no longer reproduces.** The comment (`:1992`) warns
that surfacing `singleton(M)` lets an undiscovered `M.x` fall through to `Kernel#x`, "leading to
surprising types like `Kernel.select → Array[String]`". It does not. Kernel's private instance
methods (`select`, `puts`, `raise`, `open`, `load`, `p`, `exit`, …) resolve to nothing on a
`Singleton[M]` receiver. Enumerating the ~60-name Object/Kernel/Module/Class surface against a bare
`module Empty; end` yields 28 resolving methods, and **26 of them are correct for a module object**
(`name → String`, `ancestors → Array[Module]`, `instance_methods → Array[Symbol]`,
`freeze → singleton(Empty)`, `frozen? → bool`, `hash → Integer`, …).

The two wrong ones are `Class`-only methods leaking through the `Singleton[Object]` fallback
receiver: `Empty.new → Nominal[Empty]` and `Empty.superclass → Class?`. Both are calls that raise
`NoMethodError` at runtime, so neither can mistype **working code** — they are outside the
false-positive envelope that governs this project. They also pre-date this change (F1), so seeding
does not introduce them; it only widens their reach from one file to the project.

**F3 — a project-side singleton body already beats the lenient fallback.** The worry that
`try_user_class_fallback` (the last tier inside `MethodDispatcher.dispatch`) would hijack a call
before `ExpressionTyper#try_singleton_method_inference` runs is unfounded: `try_discovered_method`
declines when `singleton_def_for` holds a re-typable body, and the Object fallback then misses.
Probed in-file, `module Conf; def self.load = 42; end; Conf.load` types `42`, not `Kernel#load`'s
answer. `extend self` bodies resolve too, through the instance-def consult in
`try_user_method_inference`.

**F4 — no `call.undefined-method` surface opens.** The rule gates on
`Reflection.rbs_class_known?` (`check_rules.rb:564`), which is RBS-only and deliberately ignores
`discovered_classes`. A project module carries no RBS, so seeding it cannot make the rule fire. The
`extend self` / `delegate` / `class_methods do` contributors Rigor does not discover therefore
degrade to `Dynamic`, never to a diagnostic.

**F5 — an RBS-known name cannot be shadowed.** `resolve_constant_name`
(`expression_typer.rb:403`) consults `env.singleton_for_name(candidate)` *before*
`discovered_classes`, so a project `module Math` / `module Comparable` reopen keeps the RBS answer.

## The decision

Register module declarations in the project-wide discovery seed, on the same terms as classes —
i.e. delete the asymmetry, do not build a new mechanism.

The seed range is **every module declaration**, matching `record_declarations` exactly. A
namespace-only `module Gitlab` registering as `singleton(Gitlab)` is already the per-file behaviour,
and the alternative (seed only modules carrying a singleton or instance `def`) buys nothing: it
would still register `Feature` and `Gitlab::Utils`, while introducing a second, divergent
registration rule that a reader must hold in their head alongside the per-file one. Symmetry with
the per-file pass is the property that makes this change reviewable.

### The criterion this must satisfy

ADR-57 WD2 binds: **the gate opens per adjudicated firing class, not wholesale.** Every diagnostic
in the delta is classified *genuine* (the newly-resolved type is right and the firing is earned) or
*artifact* (the type is wrong — an engine bug), artifacts are fixed at their root, and no firing
class is suppressed to force the change through.

### The firing class to expect

Cross-file adoption of a module-singleton return means the callee's body is folded, and a trivial
body folds to a `Type::Constant`. A `Constant[true]` flowing into `if Feature.enabled?(:x)` fires
`flow.always-truthy-condition` on working code — the same over-fold shape ADR-78 fixed at its root
and the ADR-57 addendum's `degrade_if_overridable` gate covers for overridden template methods. A
module-singleton method with no overrider escapes that gate by construction.

This is the one class where the FP risk is real, and it is the reason this note exists before the
patch. It is bounded: the fold only reaches a constant when the whole body folds, which a real
`Feature.enabled?` (arguments, delegation, dynamic dispatch) does not. The adjudication pass
measures it rather than assuming it.

## Slices

1. **Seed modules** — one branch in `collect_class_decls`, plus replacing the now-false exclusion
   comment with the measured facts above. Gate: `make verify`, then a diagnostic diff over the
   standing corpora (Mastodon `app/models`, haml `lib`, kramdown `lib`, Redmine, GitLab `app`).
2. **Adjudicate the delta** per ADR-57 WD2. Fix artifact classes at their root; the
   `flow.always-truthy-condition` shape above is the predicted suspect.
3. **Re-measure protection** on GitLab (`Feature.enabled?` alone = 695 unprotected sites) and
   cross-check Mastodon / Redmine for a ratio move without a diagnostic move.

Deliberately **out of scope**, recorded so they are not re-triaged:

- **The `Singleton[Object]` fallback receiver for modules** (F2's `Empty.new` / `Empty.superclass`).
  Correcting it needs a class-vs-module kind in `Scope::DiscoveryIndex` and a Module-shaped fallback
  receiver. It only mistypes code that raises at runtime, so it is precision hygiene, not FP work.
  Demand-gated.
- **Singleton-ancestry resolution** (`extend SomeModule`, inherited class methods) — already named a
  future slice by ADR-57 tier 4, and unchanged by this one.
- **`extend self` registration into `singleton_def_nodes`.** F3 shows the instance-def consult
  already resolves these bodies; an explicit registration is precision polish.

## Results (2026-07-10)

**Protection.** GitLab `lib` (4,748 files, the scope that contains both `lib/feature.rb` and the
`Gitlab::Utils` family), `coverage --protection --format json`, master vs. branch:

| | protected | unprotected | total | ratio |
|---|---:|---:|---:|---:|
| before | 23,044 | 70,752 | 93,796 | 0.2457 |
| after | 25,856 | 67,940 | 93,796 | **0.2757** |

**+3.00 pp, +2,812 protected sites**, with an identical denominator (the denominator's equality is
itself the check that the two runs scanned the same sites). For scale: the entire ADR-67 call-site
parameter-inference lever measured +0.75 pp on Mastodon.

The scope is `lib` rather than the survey's `app lib` because the P0/P1 slices that landed the same
week (`structure.sql`, strong-params, AS core-ext) moved protection too, so the recorded 0.2836
app+lib figure is no longer a valid "before". Both sides here were re-measured.

**Diagnostics.** haml, kramdown, liquid, rgl, Mastodon `app/models`, and GitLab `app` are all
byte-identical (`check --no-cache --no-baseline`). Two firings needed adjudication:

- rigor's own `lib` (2 errors) — `CLI::DiagnosticFormats.render` is a `case/when` with no `else`, so
  its now-inferred return is `String | nil` while both call sites gate on `.supports?` and call
  `output.empty?`. The adopted type was right; the invariant was real but unencoded. Fixed at root by
  raising on an unrecognised format. Self-check clean.
- Redmine (+1 `possible nil receiver` warning, 72 → 73) — `Redmine::CodesetUtil.replace_invalid_utf8`
  now resolves cross-file to its honest `String | nil`. The call site excludes the nil arm only
  through an ActiveSupport `login.present?` guard.

The Redmine firing's root cause is **independent of this change**:
`Narrowing#resolve_rbs_extended_method` reads a method's `rigor:v1:predicate-if-true` facts only for
a `Nominal` / `Singleton` receiver (`rbs_extended_class_name` returns nil for a `Union`), so a union
receiver never receives predicate facts at all — and `Object#present?` carries no such annotation to
begin with. Reproduced in six lines, and confirmed unfixed by adding the annotation. Any precision
work that turns a `Dynamic` into `T | nil` under a `present?` guard surfaces it.

Its own slice, with its own corpus gate, because a new narrowing rule carries a new false-positive
envelope. The general form needs no annotation at all: on the truthy edge of a zero-arg, block-less
predicate call over a union receiver, drop every arm whose RBS return type is literally `false`
(`NilClass#present?: () -> false` already says so), and the mirror on the falsey edge
(`NilClass#blank?: () -> true`). That also covers `blank?`, `presence`, and every future
`-> false`-on-nil predicate for free.

## Cost

`ADR-57`'s own gate-open cost was ~+12 % cold wall on `rigor check --no-cache lib`, from the
intrinsic re-typing of newly-resolved callees. Seeding modules opens the same door for cross-file
module-singleton calls, so `make bench-perf` is a gate, not a formality. It passes: 28.52 M
allocations against a 29.17 M ceiling (baseline 27.78 M), `lib` wall 8.3 s. Rigor's own `lib` is
class-dominated, so the newly-resolved-callee population is small here; GitLab `lib`'s check wall was
unchanged within noise.
