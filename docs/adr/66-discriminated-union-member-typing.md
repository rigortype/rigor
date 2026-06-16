# ADR-66 — Discriminated-union member typing (tag-keyed narrowing)

Status: **Proposed — not implemented; demand-gated.** Narrow a polymorphic
member field (e.g. `kramdown::Element#value`) by its sibling **discriminant tag**
field (`Element#type`), so AST/visitor/converter code — where the payload type is
a function of a tag — types its payload reads instead of falling to `Dynamic`. A
staged, FP-safe design; the cheap tier is bounded, the tier that pays on real code
is the hardest.

Grounding: the 2026-06-16 protection-uplift pilot
([`docs/design/20260616-act-on-coverage-skill.md`](../design/20260616-act-on-coverage-skill.md)
§ "Multi-repo pilot"), where this was the **largest intractable remaining
protection hole** (kramdown's #2 cluster, 121–165 sites; recurs in every
parser/template/linter).

## Context

A pervasive Ruby shape is the **tagged union**: one class carries a discriminant
tag and a payload whose type depends on the tag's value.

```ruby
class Element                    # kramdown's AST node
  attr_accessor :type            # :text | :a | :ul | :smart_quote | :entity | …
  attr_accessor :value           # String if :text, Symbol if :smart_quote, nil if :ul, …
end
```

`value : String | Symbol | EntityObj | nil`. Neither flat form helps a payload
read like `el.value.upcase`:

- `value: untyped` → no protection (today's behaviour; the receiver stays `Dynamic`).
- `value: String | Symbol | nil` → Rigor fires `possible nil` / undefined-method on
  the arms that lack `upcase`, **even though the code guarded `case el.type; when :text`**
  — a false positive on working code.

So `untyped` is chosen as the *safe* floor, and the protection is the price. This
is the AST/visitor/interpreter genre — parsers (Prism, parser, Ripper wrappers),
templates (haml/slim/kramdown/erb), serializers, rubocop walking `AST::Node`,
state machines — all sharing `case node.type; when …; node.<payload>`. Rigor
already owns **both halves of the fix and has not connected them**: the consumer
side narrows `el.type` to `Constant[:text]` on `==` / `case`/`when` (control-flow
analysis; ADR-47's `eval_case_when_branches` / `falsey_scope`), and the producer
side carries per-instance member layouts (ADR-48 `Type::DataInstance` +
`Scope#data_member_layouts`). The missing connective is a **(tag ⇒ payload) map**
and a rule that narrows the payload when the discriminant narrows.

## Decision

Propose tag-keyed member narrowing under one load-bearing criterion, staged so the
FP-safe part can ship independently of the research-grade part.

**Criterion (FP envelope, non-negotiable):** a polymorphic member field is
narrowed by its sibling discriminant **only when the (tag ⇒ payload) map is a sound
over-approximation**. Absent a reliable map the field keeps its flat / `untyped`
type and the narrowing is a **no-op**. The feature only ever *adds* protection;
it never converts working code's silence into a diagnostic. This is ADR-58's
"declaration-sourced type is not diagnostic fuel" applied to a sibling field.

When implemented, the normative narrowing rule lands in
[`control-flow-analysis.md`](../type-specification/control-flow-analysis.md) (the
spec binds); the declared-map grammar in
[`rbs-extended.md`](../type-specification/rbs-extended.md). This ADR records the
rationale and the staging.

## Working decisions

- **WD1 — additive-only consumer hook (the floor).** The narrowing is a pure
  *refinement* layered onto the existing discriminant narrowing: at a payload read
  whose sibling discriminant is already pinned to a tag constant, substitute the
  mapped arm; with no map, do nothing. No map can ever *widen* a fire surface. This
  guardrail is the whole reason the lower tiers are safe to ship.
- **WD2 — Tier 1: declared variant map.** A both-sides-authored Rigor extension —
  `%a{rigor:v1:variant(tag: type){ text: {value: String}, smart_quote: {value: Symbol}, … }}`
  on the class — feeds a new **tag-indexed member-shape carrier** (ADR-48's flat
  `DataInstance` layout generalized to a per-tag table). The consumer hook reuses
  the existing `case`/`when` + equality narrowing (ADR-47) unchanged. Both-sides
  authored ⇒ FP-safe by construction (ADR-35 / `conforms-to` kinship). Helps the
  explicit-`case` idiom immediately.
- **WD3 — Tier 2: inferred map (research-grade, budget-gated).** Auto-detect the
  discriminant (a Symbol field that is the subject of `case`/`==` across the class)
  and infer the per-tag payload by correlating construction sites
  (`Element.new(:text, "x")` ⇒ `text ⇒ {value: String}`). Whole-program correlation
  is expensive and **unsound under dynamic construction** (`Element.new(t, v)`), so
  it is budget-gated and **adopts only a clean over-approximation**, else falls back
  to WD1's no-op (per the criterion).
- **WD4 — Tier 3: visitor-dispatch tag binding (hardest; where the value is).** The
  dominant real idiom is not a literal check but a dynamic dispatch whose method
  *name* is the tag: `send("convert_#{el.type}", el)` → inside `convert_text`,
  `el.value` is a `String` with no `==` in the body. Binding the tag from the
  dispatched method name needs the ADR-16 macro/dispatch substrate. This is why
  Tiers 1–2 under-deliver on the very repo that motivated the ADR (kramdown's
  converters are `send`-dispatched).
- **WD5 — mutation soundness.** `value`/`type` are `attr_accessor`. Any write to the
  discriminant or a narrowed payload field invalidates the narrowing (the
  control-flow mutation-effect model / ADR-56 write-back), so a `el.type = …` that
  does not update `value` cannot leave a stale narrowed payload.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| Emit the flat union `value: String \| Symbol \| nil` and let it fire at unnarrowed sites | **Rejected** — manufactures FPs on guarded code; `untyped` stays the safe floor (the criterion). |
| Unguarded whole-program map inference | **Deferred to WD3 behind a budget** — unsound under dynamic construction; only a clean over-approximation is adopted. |
| A general dependent-type / GADT system | **Out of scope** — this is the narrow tag-keyed special case (one discriminant → sibling payload), not full dependent typing. |
| Ship Tier 1 and call the pattern solved | **Rejected** — the common consumer idiom is dispatch (WD4); Tier 1 alone helps the explicit-`case` minority. State the asymmetry, don't hide it. |

## Re-evaluation triggers

Demand-gated. Revisit when **any** of: (a) [ADR-58](58-ivar-field-typing.md) lands —
most payload fields are ivars, so ivar field typing is the prerequisite for the
narrowing to mean anything; (b) a corpus shows the explicit-`case` idiom is common
enough that WD2 pays on its own; (c) [ADR-63](63-type-protection-coverage.md)
protection-coverage productization makes this hole a frequently-surfaced
`add_a_type_here` target across user projects.

## Consequences

- **Positive** — closes the dominant remaining protection hole for a whole genre of
  Ruby (AST/visitor/converter/interpreter); precision-additive by the criterion.
- **Negative** — Tier 1 needs author annotation **and** a spec extension; the common
  idiom needs the hardest tier (WD4). The cheap tier helps the minority idiom — the
  asymmetry that ranks this **below** ADR-58 (which auto-closes a big cluster with no
  annotation and no new spec surface) and the dynamic-class-builder fold.
- **Carry-over** — sequence after ADR-58 (ivar payloads) and lean on ADR-16 (dispatch)
  for WD4; the new carrier extends ADR-48's member-shape family.

## Relationship to other ADRs

- **ADR-48** — the producer substrate; the tag-indexed carrier generalizes its flat
  `DataInstance` layout + `data_member_layouts` side-table.
- **ADR-47** — the consumer narrowing (`case`/`when` reachability) the payload hook
  rides on, unchanged.
- **ADR-58** — prerequisite: ivar-backed payload fields must type before narrowing them
  has meaning.
- **ADR-16** — the dispatch substrate WD4 (visitor-name tag binding) needs.
- **ADR-20** — sum-type carrier kinship (a tag-parameterized value).
- **ADR-63** — the protection-coverage pilot that surfaced this as the top intractable hole.
