# ADR-35 — Override signature compatibility (Liskov signature rule)

Status: **proposed, 2026-05-29.** Records the decision to add a new
family of diagnostics that check a method override against the
contract it inherits — the **Liskov Substitution Principle (LSP)
signature rule** applied across a class/module hierarchy:
parameters must be **contravariant** (an override may not strengthen
its preconditions by narrowing a parameter), returns must be
**covariant** (an override may not weaken its postconditions by
widening a return), and visibility must not be reduced.

This is a [Steep-inspired](8-steep-inspired-improvements.md)
follow-on: ADR-8 shipped `def.return-type-mismatch` (a method body
vs its *own* declared return); ADR-35 closes the *inherited*-contract
half (an override's declared signature vs its *parent's* declared
signature). The two are complementary — body-vs-own-contract and
contract-vs-inherited-contract — and together they cover the cases
Steep checks under `Ruby::MethodBodyTypeMismatch` and its
override-compatibility diagnostics.

The handbook appendix
[`docs/handbook/appendix-liskov.md`](../handbook/appendix-liskov.md)
§ "What Rigor does NOT check" names cross-hierarchy override
compatibility as the first unshipped LSP obligation. This ADR is the
decision to ship the **statically provable** part of it under
strict false-positive gating.

## Context

Ruby imposes no static override discipline. A subclass may override
a method with a narrower parameter, a wider return, reduced
visibility, or a different arity, and the interpreter does not
complain until a runtime path hits the incompatibility. Each is a
potential LSP violation that breaks callers written against the
supertype:

```ruby
class Repository
  # RBS:  def find: (Integer | String) -> Record
  def find(id) = @store[id]
end

class CachedRepository < Repository
  # RBS:  def find: (Integer) -> (Record | nil)
  def find(id) = @cache[id]
  # Two violations against the inherited contract:
  #   - parameter narrowed Integer|String -> Integer (precondition
  #     strengthened): a caller holding a Repository and passing a
  #     String breaks when handed a CachedRepository.
  #   - return widened Record -> Record|nil (postcondition
  #     weakened): a caller expecting a non-nil Record gets nil.
end
```

Today Rigor is silent on both. `def.return-type-mismatch`
([ADR-8](8-steep-inspired-improvements.md)) does **not** catch the
return widening, because it compares the body against
`CachedRepository#find`'s *own* declared `-> (Record | nil)` — which
the body satisfies. The violation is only visible *relative to the
parent's* `-> Record`, and nothing in the engine performs that
comparison.

The robustness principle ([ADR-5](5-robustness-principle.md))
already biases *inferred* signatures toward the LSP-correct shape
(lenient parameters = contravariant, strict returns = covariant) —
see the appendix's central thesis. But ADR-5 explicitly never
rewrites or checks **authored** signatures; it only governs what
Rigor authors. When a user hand-writes *both* the parent and the
override signatures, they have declared a contract Rigor can and
should verify for substitutability. That is the gap ADR-35 fills.

### Why this is feasible now

The machinery exists:

- **Ancestor resolution.** [ADR-24
  WD1](24-self-method-call-resolution.md) established cross-file
  resolution against "the enclosing class + ancestors" via the
  project class registry + RBS ancestors. The same ancestor walk
  finds the parent method an override shadows.
- **Subtyping / `accepts`.** The trinary `<:` machinery
  ([`relations-and-certainty.md`](../type-specification/relations-and-certainty.md))
  decides parameter contravariance and return covariance directly.
- **Per-method signatures via Reflection.** `def.return-type-mismatch`
  already reaches both instance and singleton method signatures
  through `Rigor::Reflection`; ADR-35 needs the same surface for two
  methods (override + parent) rather than one.

## Decision

When a method definition **overrides** a method reachable through
the receiver class's ancestor chain (superclass or included module),
and **both** the override and the shadowed method carry an
explicitly-authored signature (hand-written `.rbs`, rbs-inline, or
bundled RBS), the engine compares the two and emits a diagnostic on
a **provable** incompatibility:

| Check | Rule | Fires when |
| --- | --- | --- |
| Parameter contravariance | `def.override-param-narrowed` | the override's parameter type does NOT accept every value the parent's parameter type accepts (`parent_param.accepts(override_param)` is `:no`) — precondition strengthened |
| Return covariance | `def.override-return-widened` | the override's return type is NOT accepted by the parent's return type (`parent_return.accepts(override_return)` is `:no`) — postcondition weakened |
| Visibility | `def.override-visibility-reduced` | the override reduces visibility (`public` → `protected` / `private`, or `protected` → `private`) |

All three are **`def`-family** rules
([`diagnostic-policy.md`](../type-specification/diagnostic-policy.md)
taxonomy), and each maps severity through `severity_profile:`
exactly as ADR-8 / ADR-34 do:

| Profile     | default for the three `def.override-*` rules |
| ---         | ---                                          |
| `strict`    | `:error`                                     |
| `balanced`  | `:warning`                                   |
| `lenient`   | suppressed                                   |

Projects override per-rule via `severity_overrides:` and silence a
site via `# rigor:disable def.override-return-widened` (etc.).

The comparison uses the trinary certainty: only `:no` fires; `:maybe`
stays **silent** in the v1 cut (matching `def.return-type-mismatch`'s
first-cut discipline). This is the load-bearing FP control —
combined with the both-sides-explicit-signature gate, the rule only
ever fires on a provable contract violation the user opted into by
declaring both contracts.

## Working decisions

### WD1 — Gate on both-sides-explicit-signature

The rule fires only when the override **and** the shadowed parent
method each carry an explicitly-authored signature. If either side
is inference-only, the rule is silent.

**Why:** false-positive discipline is a top-tier project value
(cf. `feedback_false_positive_discipline`). Ruby
override-shape changes are routinely intentional (template-method
refinement, `method_missing`, DSL redefinition, `define_method`).
Treating every shape change as an error would frighten enormous
amounts of working code. Requiring *both* contracts to be authored
is the signal that the user has opted into a checkable contract —
the same scoping `def.return-type-mismatch` uses (explicit RBS only).
It also keeps the rule clear of ADR-5 territory: ADR-5 governs
*authored* shapes only by never touching inferred ones; ADR-35
checks *authored-vs-authored* and never touches inferred ones. The
two never overlap.

**How to apply:** the override-detection pass runs only over methods
with a Reflection-visible signature; the ancestor probe accepts a
parent only if it too has a Reflection-visible signature. A miss on
either side short-circuits to silence.

### WD2 — Three rules, not one `def.override-incompatible`

Split by violation kind rather than collapsing into one rule.

**Why:** mirrors WD3 of [ADR-34](34-toplevel-unresolved-self-call-default.md)
and the project's rule-family taxonomy where rule identity tracks
the *shape* of the problem, not its severity. Surgical disability
(`# rigor:disable def.override-visibility-reduced` without silencing
return checks), independent severity-profile mapping, and
violation-specific messages (the param rule can name the offending
parameter and the widening; the visibility rule can name the
inherited visibility) all want distinct identities. Visibility in
particular is a near-zero-FP, high-signal check that some projects
will want at `:error` even on `balanced` (see Open Questions).

**How to apply:** register all three in the `def` family in the
diagnostic policy catalogue; ADR-8's family table gains the three
new IDs.

### WD3 — Contravariant parameters, covariant returns — the directions are not symmetric

The two type-direction checks point opposite ways, and getting the
direction right is the whole correctness of the rule:

- **Parameter:** fire when `parent_param.accepts(override_param)` is
  `:no`. The override may *widen* a parameter freely (accepting more
  is contravariant-safe); it may not *narrow* it.
- **Return:** fire when `parent_return.accepts(override_return)` is
  `:no`. The override may *narrow* a return freely (returning
  something more specific is covariant-safe); it may not *widen* it.

**Why:** this is the LSP signature rule, and it is the same
asymmetry the robustness principle ([ADR-5](5-robustness-principle.md))
biases inferred signatures toward — lenient (widenable) parameters,
strict (narrowable) returns. The appendix records the convergence;
ADR-35 is the check that the convergence holds for hand-authored
signatures too.

**How to apply:** reuse the existing `accepts` query in both
directions; no new subtyping machinery. `self` / `instance` return
types resolve per dispatch site (a parent `-> self` and an override
`-> self` are both covariant-safe and must NOT fire — the
substitution happens before the `accepts` comparison).

### WD4 — Optional parameters and the widening cases are safe

Adding an *optional* parameter, widening a required parameter to a
supertype or a capability role, or accepting an additional union
member are all contravariant-safe and MUST NOT fire.

**Why:** these are the LSP-correct ways to override, and they are
common, good Ruby. Firing on them would invert the rule's intent and
punish exactly the overrides the robustness principle encourages.

**How to apply:** the `accepts` direction in WD3 already yields the
correct answer for type widening. **Arity** changes (adding/removing
*required* positional parameters, keyword requiredness) are a
distinct axis and are **out of scope for v1** — Ruby override-arity
patterns (especially with `super`, `*args`, and optional-tail
growth) carry high FP risk and deserve their own slice. v1 compares
*types at matching parameter positions* only; structural arity
divergence falls through to the existing `call.wrong-arity` path at
call sites.

### WD5 — Boundary with `def.return-type-mismatch` (ADR-8)

The two rules are complementary and non-overlapping:

- `def.return-type-mismatch`: method **body** inferred return vs the
  method's **own** declared return.
- `def.override-return-widened`: method's **declared** return vs the
  **parent's declared** return.

**Why:** a method can satisfy its own declared return while that
declared return violates the inherited contract (the
`CachedRepository` example). Neither rule subsumes the other; both
are needed for full return-side coverage.

**How to apply:** they run in the same `CheckRules` pass over a
`def` node but consult different comparison targets. A method whose
*body* fails its own return (`def.return-type-mismatch`) is reported
by that rule; ADR-35 additionally reports if the *declared* return
also widens the parent's. Both may fire on a pathological method;
that is correct, not a double-report bug (they describe different
faults).

### WD6 — Ancestor scope: superclass chain + included modules, cross-file

The shadowed-method probe walks the full ancestor chain — superclass
links and included/prepended modules — across files, reusing the
ADR-24 WD1 registry + RBS-ancestor resolution.

**Why:** LSP substitutability applies to module-supplied methods
just as to inherited ones (a class that includes `Comparable` and
overrides `<=>` is substitutable for `Comparable`'s contract).
Restricting to the superclass would miss the mixin case, which is
the more common Ruby shape.

**How to apply:** the probe stops at the first ancestor that defines
a same-name method *with a signature*; that ancestor's signature is
the comparison target. If the nearest defining ancestor has no
signature, WD1's both-sides gate makes the check silent (do not skip
past it to a more distant signed ancestor — the nearest definition
is the one being overridden).

### WD7 — `:maybe` is silent in v1

Only a `:no` certainty fires. `:maybe` (e.g. one side carries a
`Dynamic[T]` or an unresolved generic) stays silent.

**Why:** identical to `def.return-type-mismatch`'s first-cut
discipline (ADR-8 § 3). A `:maybe` is exactly the case where firing
risks a false positive on a contract that may well hold at runtime.

**How to apply:** the `accepts` call already returns the trinary;
branch on `:no` only.

### WD8 — Additive to the existing diagnostic surface; default-off escape via profile

The three rules are new diagnostic identities. On `lenient` they are
suppressed; existing projects on `lenient` see no change. On
`balanced` / `strict` they surface — but only on both-sides-authored
overrides, which is a small surface in most codebases.

**Why:** mirrors ADR-34 WD6/WD8 — severity-profile mapping is the
project-wide knob for "how loud should a newly-added rule be." A
freshly-onboarded project on `lenient` is unaffected; a project that
has opted into `strict` (or authored RBS deliberately) gets the
check.

**How to apply:** wire into the ADR-8 severity-profile table; no new
mechanism.

### WD9 — Escape hatches: generics first, body-narrowing second, suppression last

A diagnostic that flags an override needs a way out for the cases
the author knows are fine. The lesson of PHPStan's generics design
(Mirtes, *Generics in PHP using PHPDocs* — see Background research
notes) is that the *best* escape hatch is not a suppression comment
but a **richer type construct that makes the code genuinely
LSP-safe**. ADR-35 offers three tiers, in strict order of
preference.

**Tier 1 — Generics (the principled, non-suppressing hatch).** The
article's worked case is a `Consumer::consume(Message)` whose
implementation wants `consume(SendMailMessage)` — a parameter
narrowing that *looks* like an LSP violation. PHPStan's resolution
is not `@phpstan-ignore`; it is to make the interface generic
(`@template T of Message`, method `@param T`) and have the
implementation bind it (`@implements Consumer<SendMailMessage>`).
The native parameter stays the wide `Message` (contravariance
satisfied at the language level); the analyzer understands the
specialization through the generic binding. "Even Barbara Liskov is
happy with it."

The RBS analogue already exists:

```rbs
interface _Consumer[T < Message]
  def consume: (T) -> void
end

class SendMailConsumer
  include _Consumer[SendMailMessage]
  # def consume: (SendMailMessage) -> void  — consistent with the
  # interface instantiated at T = SendMailMessage; NOT a violation.
end
```

For this to *not* fire, the ADR-35 comparison MUST be
generic-instantiation-aware: when the override's defining class
binds the ancestor's type parameters (`class Sub < Parent[Concrete]`
or `include _Iface[Concrete]`), substitute those type arguments into
the parent signature **before** the `accepts` comparison (WD3),
reusing the [ADR-4](4-type-inference-engine.md) Phase 2d `type_vars`
threading. The "narrowing" then matches the *instantiated* parent
contract and no diagnostic is produced — because there was never a
violation. Bounded generics (`[T < Bound]`) are already in the RBS
surface (handbook appendix § "F-bounded polymorphism and self
types"). This is the recommended fix and the direct analogue of the
article's resolution.

**Tier 2 — The body-narrowing dual layer (the everyday case).** Most
"I want a narrower type here" situations need no escape hatch at all.
Keep the *declared* parameter at the parent's wide type (LSP-safe)
and recover the specific type *inside the body* via occurrence
typing. This is the robustness principle's clause-2 + narrowing
pairing ([ADR-5](5-robustness-principle.md)): the wide declared
parameter is the LSP-correct contract, the narrow body type is
recovered for free. It is Rigor's analogue of PHPStan's
native-wide-plus-annotation-narrow dual layer — except Rigor's
"narrow layer" is the *inferred body type*, not a second annotation,
so the user writes nothing extra. A method that genuinely only
handles `SendMailMessage` but declares `(Message)` and guards with
`return unless message.is_a?(SendMailMessage)` is both LSP-correct
and fully precise inside the body.

**Tier 3 — Suppression (last resort).** For the residue — genuine
Ruby patterns the analyzer cannot prove safe and the author asserts
(metaprogramming, deliberate divergence) — `# rigor:disable
def.override-param-narrowed` at the site, or a family-level
`severity_overrides:` entry. Carries no structure; use only when
tiers 1–2 do not apply.

**Why:** the ordering keeps ADR-35 from degrading into
"annotate-away the warnings." Generics make the specialization case
*safe* rather than *silenced*; body-narrowing makes the wide-contract
case both safe and precise; suppression is the explicitly-blunt
fallback. This is also why the WD1 both-sides-authored gate is
synergistic: a user who has authored both signatures is already in
"I am declaring contracts" territory, so rewriting the parent as a
bounded generic (tier 1) is a natural, in-language move rather than
a foreign imposition.

**How to apply:** tier 1 requires the WD3 / WD6 comparison to
substitute ancestor `type_args` into the parent signature before
`accepts`; unbound / unresolved type parameters degrade to `:maybe`
(silent per WD7), never a false `:no`. Tiers 2–3 need no new
mechanism. A structured RBS::Extended opt-out annotation
(`%a{rigor:v1:override-exempt}`-shape) as a middle ground between
tier 1 and tier 3 is deferred — see Open Questions.

## Implementation slicing

Recommended order; each slice independently shippable.

1. **Visibility rule.** `def.override-visibility-reduced` — the
   lowest-FP, no-subtyping-required check. Needs only the
   ancestor-method probe (WD6) and a visibility comparison. Ships
   the override-detection pass and the new family registration.
2. **Return covariance.** `def.override-return-widened` — reuses the
   slice-1 probe + the `accepts` query in the return direction (WD3)
   + the `:maybe`-silent discipline (WD7). Honours `self`/`instance`
   substitution before comparison, and ancestor `type_args`
   substitution (WD9 tier 1) so a generic-instantiated covariant
   return never fires.
3. **Parameter contravariance.** `def.override-param-narrowed` —
   per-position type comparison in the parameter direction (WD3,
   WD4). Type-only; arity divergence stays out of scope. This is the
   slice where WD9 tier 1 (generic-instantiation-aware comparison)
   is load-bearing — the `Consumer[T < Message]` specialization
   pattern depends on substituting the bound `type_args` before the
   `accepts` check, otherwise the legitimate narrowing false-fires.
4. **Mastodon-corpus FP verification.** Run all three against
   Mastodon's `app/models` + `app/controllers` (the corpus ADR-26 /
   ADR-24 used) with authored RBS where available; tabulate fires,
   confirm each is a real LSP violation or a calibration miss. Gate
   promotion of any rule's `balanced` default to `:error` on this
   data.
5. **(Deferred) parent-authored + child-inferred covariance.** A
   covariance-only extension: when the parent return is authored but
   the child is inference-only, check the child's *inferred* return
   against the parent's *declared* return. Higher value, higher FP
   (inferred-body precision); gated on slice 4 data showing the
   inferred-return precision is good enough. No commitment.

## Alternatives considered

- **One `def.override-incompatible` rule.** Rejected per WD2 —
  unifies what should be surgical and forces one severity across
  three FP profiles (visibility is much safer than parameter
  narrowing).
- **Check inferred signatures too (drop the WD1 gate).** Rejected
  for v1 — inferred signatures are subject to robustness widening /
  narrowing and the FP surface on metaprogramming-dense Ruby is
  large. Slice 5 revisits the lowest-risk corner (parent-authored
  covariance) behind corpus data.
- **Fold return widening into `def.return-type-mismatch`.** Rejected
  per WD5 — different comparison target (inherited contract vs own
  contract); a method can pass one and fail the other.
- **Make it a plugin / opt-in config key rather than a core rule.**
  Rejected — substitutability of an authored class hierarchy is a
  core type-system property, not a framework-specific concern (cf.
  ADR-28, which *is* framework-scoped because it binds a *directory*
  to a protocol). The both-sides-authored gate + severity profile
  are sufficient scoping; a separate config axis would duplicate the
  profile mechanism.
- **Enforce the LSP exception rule (no new exceptions in an
  override).** Rejected — RBS has no widely-used `raises` clause to
  compare against, and Ruby rescue idioms make inferred raise-sets
  high-FP. Recorded as a non-goal in the appendix; not opened here.
- **Enforce arity compatibility in v1.** Rejected per WD4 — high FP
  on `super` / `*args` / optional-tail patterns; deferred to its own
  slice if demand appears.

## Open questions

- **Should `def.override-visibility-reduced` floor at `:warning`
  even on `lenient`?** It is near-zero-FP and a genuine
  substitutability break (a caller invoking a now-private method
  hits `NoMethodError`). Counter-argument: `private` in a subclass
  is sometimes a deliberate "this is internal here" signal. Decision
  deferred to slice-1 dogfood + slice-4 corpus data.
- **`protected` handling.** `protected` substitutability is subtler
  than `public`/`private` (it depends on the call's receiver
  relationship). v1 treats `public → protected` as a reduction;
  whether `protected → public` (a widening, safe) or same-level
  `protected` overrides need special handling is deferred.
- **Generic / parameterised overrides.** A parent `-> Array[Object]`
  and a child `-> Array[String]`: element covariance on an immutable
  read is safe, but `Array` is invariant (ADR-1 / the appendix's
  variance section). v1 leans on the existing `accepts` answer for
  generics (which honours declared variance); whether that yields
  too many `:maybe`s to be useful is a slice-4 measurement.
- **Interaction with `Data.define` / `Struct` generated methods.**
  Generated accessors carry inferred (not authored) signatures, so
  WD1 makes them silent. If a future slice infers their signatures
  precisely, revisit whether overriding a generated accessor should
  be in scope.
- **Should the message hint at the robustness principle?** A
  `def.override-param-narrowed` message could point at "widen the
  parameter or accept the parent's type" with an ADR-5 reference.
  Costs nothing; might rot. Deferred to implementation. The message
  could equally hint at WD9 tier 1 ("make the parent generic and bind
  the type parameter") for the specialization case.
- **A structured `%a{rigor:v1:override-exempt}` annotation (WD9
  middle tier)?** Between tier-1 generics and tier-3 bare
  `# rigor:disable`, a dedicated RBS::Extended annotation would be
  greppable, intention-revealing, and auditable (it says "this
  override intentionally diverges and the author vouches for it",
  not "hide this line"). Cost: a new annotation token in the
  rbs-extended grammar plus its own maintenance and documentation
  surface. The provisional call is to *not* ship it — generics
  (tier 1) cover the principled cases and `# rigor:disable` (tier 3)
  covers the residue, so the middle tier earns its keep only if
  slice-4 corpus data shows a recurring pattern that is neither
  generic-expressible nor a one-off suppression. Decide on that
  data.

## Background research notes

This ADR was prompted by a 2026-05-29 conversation that produced the
handbook appendix
[`docs/handbook/appendix-liskov.md`](../handbook/appendix-liskov.md),
which maps the LSP obligations onto Rigor's surface and names
cross-hierarchy override compatibility as the highest-value
unshipped obligation. The appendix's central thesis — that the
robustness principle *is* the LSP signature rule reached from
Ruby-adoption ergonomics — is the reason this check is a natural fit
rather than a foreign imposition: it verifies, for hand-authored
signatures, the same property ADR-5 already biases inferred
signatures toward.

Ondřej Mirtes, *Generics in PHP using PHPDocs*
(<https://medium.com/@ondrejmirtes/generics-in-php-using-phpdocs-14e7301953>),
is the direct driver for WD9. Its key lesson — that a parameter
narrowing which *looks* like an LSP violation is best resolved by
making the parent generic (`@template T of Message` +
`@implements Consumer<SendMailMessage>`) rather than by suppressing
the warning ("even Barbara Liskov is happy with it") — is exactly
the tier-1 escape hatch ADR-35 adopts. The RBS bounded-generic
surface (`interface _Consumer[T < Message]`) already expresses the
same construct, so the work is making the ADR-35 comparison
generic-instantiation-aware (WD9 "How to apply") rather than
inventing a new annotation. The article also models the dual-layer
(native-wide parameter + annotation-narrow precision) that WD9
tier 2 reproduces via Rigor's wide-declared-parameter +
inferred-narrow-body pairing.

Steep performs the analogous override-compatibility check against
RBS; ADR-8 ("Steep-inspired improvements") is the lineage this ADR
continues. [ADR-28](28-path-scoped-protocol-contracts.md)
(path-scoped protocol contracts) is the sibling on the
substitutability axis — structural substitutability for a
directory-bound protocol, where ADR-35 is nominal substitutability
for an inherited contract.

## Revision history

- 2026-05-29 — initial proposal. Triggered by a user question
  ("RigorにLSP観点での機能追加の余地はありそう？") following the
  authoring of the Liskov handbook appendix. Scoped deliberately
  narrow: provable violations only, both-sides-authored signatures
  only, type-direction + visibility only (arity and exception rules
  out of scope), `:maybe` silent — so the rule honours the
  false-positive discipline that gates every diagnostic-adding
  change.
- 2026-05-29 — added WD9 (escape hatches) after a user question
  about providing a PHPDoc-style escape hatch, citing Mirtes'
  *Generics in PHP using PHPDocs*. Records the tiered design
  (generics first → body-narrowing → suppression) and the decision
  that tier-1 generic-instantiation-aware comparison is a
  correctness requirement of the param/return checks, not merely an
  opt-out — the legitimate `Consumer[T < Message]` specialization
  must never false-fire. A structured `%a{rigor:v1:override-exempt}`
  annotation is floated as an open question and provisionally
  declined.
