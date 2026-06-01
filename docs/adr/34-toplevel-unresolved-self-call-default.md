# ADR-34 — Toplevel unresolved implicit-self calls warn by default

Status: **Accepted, 2026-05-29; implemented in v0.1.13.**

Records the
decision to flip the current silent-`Dynamic[top]` behaviour on
toplevel implicit-self call sites that fail to resolve against any
visible method contributor, emitting a dedicated
`call.unresolved-toplevel` diagnostic instead. The escape hatch — for
projects that introduce toplevel methods via monkey-patching or
metaprogramming — is [ADR-17](17-monkey-patch-pre-evaluation.md)'s
`pre_eval:` config axis, which landed in the same release. The
`call.unresolved-toplevel` rule and the `Scope#toplevel?` predicate
ship, with severity mapped through `severity_profile:` and the
cross-file toplevel-`def` index in place; the ADR-29 Playground
default-severity wiring is the remaining slice.

This ADR is intentionally narrow: only the **toplevel** slice flips
default. Implicit-self calls inside `class` / `module` bodies stay
lenient under [ADR-24 WD3](24-self-method-call-resolution.md);
upgrading *those* to a diagnostic remains [ADR-24
WD4](24-self-method-call-resolution.md)'s separately gated decision
and is **not** opened by this ADR.

## Context

`foo 1` written at the top of a `.rb` file referring to a method
that does not exist anywhere in the analysed environment today
produces no diagnostic. Confirmed empirically:

```
$ echo 'foo 1' > main.rb
$ rigor check main.rb
No diagnostics

$ rigor type-of main.rb:1:1
type:    Dynamic[top]
```

The behaviour follows directly from ADR-24 WD3 — "unresolved
self-calls stay `Dynamic[top]`" — applied uniformly across
contexts. The reason WD3 made that call was false-positive
discipline against Rails-model class bodies: every `attr_accessor`
/ `has_many` / `scope` / `validates` is a `self`-context call that
the static walker cannot resolve, and turning the unresolved cases
into errors would drown that domain in noise.

But the same default is actively wrong for two other contexts:

1. **Standalone scripts.** A user writes `bin/process`,
   `lib/scripts/import.rb`, or a one-off `.rb` file driving a quick
   analysis. A typo in a method name (`procss` for `process`) is
   exactly the kind of bug a type-checker should catch — there is
   no DSL, no metaprogramming, no class-body context. Silence on
   the typo is a UX failure proportional to the script's
   straightforwardness.

2. **The [ADR-29](29-browser-playground.md) Playground.** A pasted
   snippet has no project configuration, no Gemfile, no
   `pre_eval:`. The whole point of the Playground is to surface
   what Rigor sees. Silently typing `foo 1` as `Dynamic[top]`
   while the user is *trying to learn what diagnostics fire* is
   the precise opposite of the playground's value proposition.

The asymmetry is the issue: class-body context has high FP risk
from metaprogramming-dense Rails patterns; toplevel context does
not. Conflating them under one default loses information.

## Decision

For an implicit-self call at **toplevel scope** (no enclosing
`def`, no enclosing `class` / `module` body), if the call name
does not resolve against any of:

1. A toplevel `def` in the same file or in any other analysed
   `paths:` file,
2. An entry in the
   [ADR-17](17-monkey-patch-pre-evaluation.md)
   `Inference::ProjectPatchedMethods` registry under
   `(Object, name, instance)`,
3. The standard `Kernel` / `Object` private-method surface
   (`puts`, `p`, `require`, `loop`, `raise`, …) drawn from the
   loaded RBS environment,

then the engine emits a new `call.unresolved-toplevel` diagnostic.
On a hit, the resolved method's return type and parameter
contract propagate exactly as ADR-24 slices 1–3 already do.

The new rule's default severity is tied to `severity_profile:`:

| Profile     | `call.unresolved-toplevel` default |
| ---         | ---                                |
| `strict`    | `:error`                           |
| `balanced`  | `:warning`                         |
| `lenient`   | suppressed                         |

Projects can override the per-rule mapping via the existing
`severity_overrides:` config key, and silence individual call
sites via `# rigor:disable call.unresolved-toplevel`.

The class-body / `def`-body case (ADR-24 WD4) stays closed. This
ADR does NOT generalise to `def` interiors or class bodies —
those carry the Rails-DSL FP cost that WD4 already weighed and
deferred.

## Working decisions

### WD1 — Default for toplevel: warn, not silent

The silent-`Dynamic[top]` default is correct for class-body
context (Rails-DSL leniency per ADR-24 WD3) but wrong for
toplevel context (script / Playground UX).

**Why:** the FP profile differs. Class-body unresolved-self calls
are dominated by metaprogramming the static walker cannot follow;
toplevel unresolved-self calls are dominated by typos / forgotten
`require`s — exactly what a type-checker is for.

**How to apply:** the diagnostic emission point is the same
implicit-self dispatcher path ADR-24 slices 1–2 already use; what
changes is what happens on a miss when the enclosing context is
toplevel. WD4 records the boundary precisely.

### WD2 — Escape hatch is ADR-17 `pre_eval:`

Projects that legitimately introduce toplevel methods via
monkey-patching (`String`-on-`Object`-shaped patches loaded at
boot, `lib/core_ext/*.rb` helpers, framework toplevel helpers)
declare those files in `.rigor.yml`'s `pre_eval:` array (per
ADR-17). The pre-eval pass populates `ProjectPatchedMethods`; the
WD1 dispatcher consults the registry; the diagnostic does not
fire for resolved entries.

**Why:** the user proposed exactly this shape — "基本的には警告
するようにして、monkeypatch やメタプログラミングの供給源は設定
で明示的に先行評価させる" — and it matches ADR-17's existing
contract without modification. The mechanism already exists; this
ADR just elevates it from "opportunistic precision uplift" to
"the canonical opt-out for the WD1 default flip".

**How to apply:** no new config key is introduced by this ADR.
`pre_eval:` is the only knob. The ADR-17 fail-soft contract
(WD3) means a malformed `pre_eval:` file does not prevent
analysis from continuing — the WD1 diagnostic just fires for the
methods that file would have registered.

### WD3 — New rule `call.unresolved-toplevel`, not folded into `call.undefined-method`

Three reasons to keep the rule identity separate:

1. **Surgical disability.** `# rigor:disable
   call.unresolved-toplevel` silences only this diagnostic
   without affecting the much-more-load-bearing
   `call.undefined-method` on explicit-receiver calls.
2. **Independent severity-profile mapping.** The table in
   "Decision" treats `call.unresolved-toplevel` as a
   profile-modulated rule; folding it into `call.undefined-method`
   would force one severity across both call shapes.
3. **Diagnostic message specificity.** `call.unresolved-toplevel`
   can carry a hint pointing users at ADR-17 (`"consider adding
   the file that defines this method to pre_eval:"`); the generic
   `call.undefined-method` message stays generic.

**Why:** matches the project's existing rule-family taxonomy
([`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md))
where rule identity tracks call-site shape, not severity.

**How to apply:** add the rule to the diagnostic policy
catalogue; register a `Rigor::Analysis::CheckRules`-side check
that fires only when the enclosing scope test reports toplevel.

### WD4 — Boundary: implicit-self at toplevel, full stop

Three precise boundary conditions, all conjunctive:

- The call has no explicit receiver (`foo 1`, not `obj.foo 1`).
- The call is not inside any `def` (toplevel script context).
- The call is not inside any `class` / `module` body (i.e. the
  enclosing static scope is `Object`'s singleton — what Ruby
  itself calls "main").

Calls failing any condition fall back to their existing
dispatcher path:

- Explicit-receiver calls → the standard `call.undefined-method`
  pipeline (already exists, behaviour unchanged).
- Implicit-self inside `def` → ADR-24 slices 1–3 resolution; on
  miss, stays `Dynamic[top]` per ADR-24 WD3 (behaviour
  unchanged).
- Implicit-self inside `class` / `module` body → ADR-24 WD4
  territory; stays closed (behaviour unchanged).

**Why:** this ADR's whole point is the asymmetry between toplevel
and class-body FP profiles. Generalising further would re-open
ADR-24 WD4 and inherit its FP risk on Rails-model bodies. Keep
the slice narrow.

**How to apply:** the enclosing-scope test belongs in
`Inference::Scope`; the implicit-self dispatcher branch checks
`scope.toplevel?` (a new predicate) before deciding emission vs
fallback.

### WD5 — ADR-17 implementation is a hard precondition

The WD1 default flip MUST NOT land before ADR-17's slices 1–2
land. Without the registry, projects with toplevel monkey-patches
have no opt-out and the new default becomes a hostile regression.

**Why:** false-positive discipline is a top-tier project value
(promoted to memory under `feedback_false_positive_discipline`).
Shipping the diagnostic without the escape hatch would frighten
working code and erode trust faster than the diagnostic adds
value.

**How to apply:** the implementation order is fixed —

1. ADR-17 slice 1 (configuration plumbing).
2. ADR-17 slice 2 (pre-eval walker + registry + dispatcher tier).
3. ADR-34 slice 1 (this ADR's diagnostic emission, consulting
   the now-existing registry).

ADR-17 slice 3 (cache descriptor) is independent and can land
before or after ADR-34 slice 1.

### WD6 — Severity-profile mapping, not a hardcoded severity

The "Decision" table maps the rule's severity through
`severity_profile:` rather than hardcoding a single severity.

**Why:** the three contexts that motivate this ADR have different
risk tolerances. A Playground demo wants `:error` (loud); a
freshly-onboarded Rails app on `lenient` wants the rule out of
the way while the team migrates; a mature script-heavy `lib/`
on `balanced` wants `:warning` so the noise stays
auditable.

**How to apply:** wire the rule into the
[`docs/adr/8-steep-inspired-improvements.md`](8-steep-inspired-improvements.md)
severity-profile table; no new mechanism needed.

### WD7 — Playground (ADR-29) defaults strict for this rule

The ADR-29 browser playground per-request sandbox should set
`severity_profile: strict` (or per-rule override the new rule to
`:error`) so a pasted snippet of `foo 1` produces the expected
diagnostic the first time.

**Why:** the Playground's value proposition is "show me what
Rigor sees". Inheriting a `balanced` default that maps this rule
to `:warning` would hide exactly the example most likely to be
the user's first interaction with the tool.

**How to apply:** ADR-29 slice 1 was already amended to load
`rigor-rbs-inline` with `require_magic_comment: false` per
ADR-32 WD10 for a similar reason. This ADR adds a parallel
amendment: set the severity profile (or rule override) in the
per-request sandbox config so the new rule fires.

### WD8 — Files in `paths:` are the resolution scope, not the whole filesystem

The WD1 step-1 lookup ("a toplevel `def` in the same file or in
any other analysed `paths:` file") explicitly draws on the
configured `paths:` set, not arbitrary `require`d files.

**Why:** users can opt files in by listing them in `paths:` (the
ordinary surface). Files outside `paths:` are by definition
out-of-scope for analysis; resolving against them would introduce
non-determinism (results depend on the runtime load order rather
than on declared config).

**How to apply:** the cross-file toplevel-`def` index lives
alongside the existing project class-discovery pre-pass; it's
populated once at analyzer startup and consulted by the
dispatcher.

## Implementation slicing

Recommended order; each slice independently shippable. Slices 1–2
deliver the MVP feature behind the WD5 precondition; slice 3 is
the Playground integration.

1. **Rule + emission.** Register `call.unresolved-toplevel` in
   the diagnostic policy catalogue. Add `Inference::Scope#toplevel?`
   (new predicate). Wire the implicit-self dispatcher's miss path
   to consult `ProjectPatchedMethods` and emit on a miss when
   `scope.toplevel?` holds. Map severity through
   `severity_profile:`.
2. **Cross-file toplevel-`def` index.** Extend the existing class-
   discovery pre-pass to also index toplevel `def` declarations
   across all `paths:` files; consult it as the first probe
   before `ProjectPatchedMethods`.
3. **Playground default.** Per WD7, set the playground sandbox's
   severity profile (or per-rule override) so the new rule fires
   on pasted snippets. Gated on ADR-29 itself being implemented.

## Alternatives considered

- **Just enable ADR-24 slice 4 for everything.** Rejected per
  WD4: slice 4's FP risk on Rails-model class bodies is exactly
  what WD4 weighed and deferred. Toplevel can ship first; the
  class-body case stays gated.
- **Fold into `call.undefined-method`.** Rejected per WD3:
  unifies what should be surgical.
- **Default to silent and require opt-in.** Rejected: the user's
  framing ("基本的には警告するように") was unambiguous, and the
  Playground use case (WD7) demands the opposite default.
- **No new rule; just emit a `:warning` per
  `call.undefined-method` on toplevel misses.** Rejected per WD3
  point 2 — severity-profile mapping needs rule identity to vary
  independently.
- **Use a more discoverable mechanism than `pre_eval:` (e.g. a
  dedicated `toplevel_methods:` array).** Rejected: ADR-17
  already exists and covers the broader monkey-patch case. A
  dedicated array would duplicate the discovery pipeline without
  adding capability.

## Open questions

- **Rake task files (`Rakefile`, `lib/tasks/*.rake`).** These are
  toplevel-but-DSL: `task :foo => :bar do ... end` reads as
  unresolved-toplevel calls (`task`, `desc`, `namespace`, …)
  unless the project pre-evals a Rake stub. Two paths: (a)
  document a recommended `pre_eval:` snippet for projects with
  Rake tasks in `paths:`, (b) ship a `rigor-rake` plugin that
  registers the toplevel Rake DSL in `ProjectPatchedMethods` via
  ADR-9's `flow_contribution_for`. Decision deferred to slice 1
  dogfood.
- **`bin/*` shebang scripts.** Usually short, often
  `require_relative` heavy, often executable rather than
  `paths:`-listed. Whether to treat them as toplevel for this
  rule may need a `bin/` heuristic or per-file scoping. Decision
  deferred to slice 1 dogfood.
- **Should the diagnostic message hint at `pre_eval:`?** Probably
  yes for `balanced` / `strict`; arguably no for `:info`. The
  hint costs nothing to write but might rot if ADR-17's interface
  evolves. Decision deferred to slice 1 implementation.
- **Block-body and `class << self` interaction.** A toplevel
  `class << self; foo; end` is not toplevel scope in WD4's sense
  (the singleton class body is a class body), but `class << self`
  appearing at toplevel might intuitively read as "still
  toplevel" to users. Stick with the strict WD4 reading for v1;
  revisit if reports surface.

## Background research notes

Empirical confirmation that today's behaviour is silent on
toplevel unresolved calls — `rigor type-of main.rb:1:1` returns
`Dynamic[top]` and `rigor check` returns "No diagnostics" — was
captured during the 2026-05-29 conversation that prompted this
ADR. ADR-24's class-body lenient default is the right call for
its target domain; this ADR records the per-context split the
original WD3 framing left implicit.

## Revision history

- 2026-05-29 — initial proposal. Triggered by a user-question
  about the silent toplevel behaviour and the realisation that
  the Playground / standalone-script use cases want the opposite
  default. ADR-17's pre-eval mechanism is the natural escape
  hatch — no new config surface is introduced beyond the new
  rule identity itself.
