# Type-specification docs audit — fidelity + internal consistency (2026-07-11)

Lens: normative type-spec corpus (`docs/type-specification/`, 17 files) checked for (a)
internal consistency across the documents and (b) fidelity to the `lib/rigor/`
implementation on the load-bearing claims. The spec binds; where the implementation
diverges the divergence is surfaced (doc-vs-code direction noted, not adjudicated).

Method: full read of all 17 files; targeted `lib/rigor/type/` reads (`combinator.rb`,
`dynamic.rb`, `top.rb`, `union.rb`); CLI-level Combinator probes inside the Flake for the
lattice/algebra/display claims; `grep` over `lib/rigor` for the budgets config surface and
the suppression family-wildcard set.

## Findings

| # | Location (file:line + quote) | Problem | Severity | Proposed fix |
|---|---|---|---|---|
| 1 | `value-lattice.md:41-53` (`Dynamic[A] \| Dynamic[B] = Dynamic[A \| B]`, `T \| Dynamic[U] = Dynamic[T \| U]`, `Dynamic[T] & U = Dynamic[T & U]`, `Dynamic[T] - U = Dynamic[T - U]`) + worked example `:57` "`untyped & String` becomes `Dynamic[String]`, not plain `String` and not raw `untyped`"; `normalization.md:22` "Normalize dynamic-origin unions, intersections, and differences by transforming the static facet and keeping the wrapper"; `special-types.md:41` references "The full algebra … is in value-lattice.md" | **impl-divergence** (a normative normalization rule the engine does not apply). `Type::Combinator` is the normalization layer (its header cites `normalization.md`), but `union`/`intersection`/`difference` perform **no** dynamic-facet transform. Flake probe: `union(Dynamic[Integer], Dynamic[String])` → `Dynamic[Integer] \| Dynamic[String]` (a `Union` of two `Dynamic`s, not `Dynamic[Integer \| String]`); `union(String, Dynamic[Integer])` → `Dynamic[Integer] \| String`; `intersection(Dynamic[String], Integer)` → `Dynamic[String] & Integer` (a raw `Intersection`); `intersection(untyped, String)` → `Dynamic[top] & String` — directly contradicting the worked example's `Dynamic[String]`. `scope.rb#join` widens via the same `union`, so the algebra is absent at the flow-join layer too. | High | Either implement the facet transform in `Combinator.union`/`intersection`/`difference` (reconstruct `Dynamic[·]` around the joined/met/differenced static facets), OR — following the honesty precedent `inference-budgets.md` already sets — add an "Implementation status" note to `value-lattice.md` / `normalization.md` marking these identities normative-but-not-yet-wired and rewrite the `untyped & String` worked example so it doesn't read as shipped behaviour. (Behaviour is partly masked because a `Union`/`Intersection` carrying a `Dynamic` still erases to `untyped` and stays gradually-consistent, so downstream soundness is likely intact — this is a precision/spec-fidelity defect, not a soundness one.) |
| 2 | `type-operators.md:76` "The specific budget is `budgets.negative_fact_display`" and `:104` "The display budget is `budgets.negative_fact_display` and is configurable in `.rigor.yml`"; `rbs-erasure.md:98-101` "`budgets.hash_erasure_keys` (default 16 …) … Both are configurable in `.rigor.yml`." | **aspirational-unmarked / internal-inconsistency**. `inference-budgets.md:73-84` honestly and prominently states the `budgets:` surface "is not yet wired — no `budgets:` key is parsed and the table's rows are not enforced" (confirmed: no `budgets`/`negative_fact_display`/`hash_erasure_keys` parser anywhere in `lib/rigor/configuration*`). But these two sibling docs describe the same keys as configurable in `.rigor.yml` in the present tense with no caveat, so a reader of `type-operators.md`/`rbs-erasure.md` alone would believe the knobs are live today. | Medium | Add a caveat at each "configurable in `.rigor.yml`" mention, e.g. "(planned; see `inference-budgets.md` § Implementation status — the `budgets:` surface is not yet wired)". |
| 3 | `diagnostic-policy.md:93` (Token resolution) family wildcards = "`call` / `flow` / `assert` / `dump` / `def`" vs. `:30-43` identifier-taxonomy table (families `dynamic` / `static` / `flow` / `compat` / `call` / `def` / `rbs_extended` / `rbs.coverage` / `plugin` / `generated` / `hint` / `sig`) — `assert` and `dump` are **not** in the taxonomy, and most taxonomy families are not disable-token-expandable; and `:60` (severity resolution) describes a family wildcard generically as "the rule id's first segment", which would match `dynamic`/`static`/etc. | **internal-inconsistency**. Two suppression mechanisms in the same doc disagree on what a "family" is: the `disable`-token expander is a fixed 5-name set (`RULE_FAMILIES = %w[call flow assert dump def]`, confirmed in `analysis/check_rules.rb:128`), while `severity_overrides` family wildcards use generic first-segment matching. `assert`/`dump` families are referenced but never defined in the taxonomy. | Low–Medium | Document `assert`/`dump` in the taxonomy (or label them legacy), and state explicitly that `severity_overrides:` wildcards match any first dotted segment whereas `# rigor:disable` tokens expand only the fixed `call/flow/assert/dump/def` set. |
| 4 | `special-types.md:70` "RBS treats `void`, `boolish`, and `top` equivalently" and `:108` "RBS `boolish` is an alias of `top`" vs. `rbs-compatible-types.md:9-32` form table (rows for `bool`/`nil`/`untyped`/`top`/`bot`/`void` but **no `boolish`**) | **internal-inconsistency** (minor gap). The "authoritative table mapping RBS forms to Rigor's interpretation" omits `boolish`, a form the corpus elsewhere treats as first-class. | Low | Add a `boolish \| Alias for top \| boolish` row to the form table (or a one-line note that `boolish` erases through `top`). |

## Spot-checks that PASSED (fidelity confirmed)

- `untyped = Dynamic[top]`: `Combinator.untyped == Dynamic.new(Top.instance)`; `dynamic(top)`
  is idempotent back to `untyped` (`combinator.rb:44-57`, `:856`). Matches
  `special-types.md:33` / `value-lattice.md:28`.
- `bool` display collapse (`true | false → bool`, composing with `T? → bool?`): implemented
  in `union.rb#describe` (`:44-46`, `:120-125`), display-only with identity/erasure
  unchanged — matches `normalization.md:18,34` and `rbs-compatible-types.md:56-58`.
- `untyped`-bearing union erases to `untyped` (`union.rb#erase_to_rbs`) — matches the
  lossless-`untyped` round-trip claim in `rbs-compatible-types.md:60-62` /
  `overview.md:7`.
- Reserved refinement / type-function carriers named in `imported-built-in-types.md`
  (`non-empty-string`, `non-zero-int`, `positive-int`/`non-negative-int` via `IntegerRange`,
  `lowercase/uppercase/numeric-string` + paired complements, `int_mask`/`int_mask_of`,
  `key_of`/`value_of`/`pick_of`/`omit_of`/`partial_of`/`required_of`/`readonly_of`,
  indexed access `T[K]`) all exist as `Combinator` factories/functions with matching
  semantics.
- `inference-budgets.md` § "Implementation status (2026-06-03)" is **honest**: it presents
  the `budgets:` table as normative-intent-but-unwired and enumerates the four actually-wired
  hard guards. Confirmed no `budgets:` parser exists. (The dishonesty is only in the sibling
  docs — finding #2.)
- README reading-order table (16 topical rows + README) matches the 17 files on disk; no
  broken cross-reference among the docs.
- This cycle's engine changes — module-singleton resolution (ADR-57 WD3) and union-arm
  predicate polarity (`present?`/`blank?` narrowing) — do **not** contradict
  `control-flow-analysis.md` or `relations-and-certainty.md`: both are precision refinements
  to how zero-arg predicate / negative-fact narrowing already-generically-described in those
  docs behaves. No doc text was rendered inaccurate.

## Verdict

The type-specification corpus is internally coherent and, on its scalar/lattice/carrier/
display claims, faithful to the implementation: the reading order, cross-references, and the
`top`/`bot`/`void`/`bool`/`nil`/`untyped` identities all hold, and the reserved-refinement and
type-function vocabulary is fully backed by `Combinator`. The `inference-budgets.md`
honesty caveat is exemplary and should be the template for the corpus's two real defects.
The one High-severity item is the **dynamic-origin algebra**: `value-lattice.md`'s join/meet/
difference identities and its `untyped & String → Dynamic[String]` worked example are stated
as normative-and-shipped, but `Combinator` (the normalization layer) does not transform the
static facet — it leaves a `Union`/`Intersection` of `Dynamic` carriers instead. This is a
precision/fidelity gap rather than a soundness hole (the un-reduced forms still erase to
`untyped` and stay gradually consistent), but a reader relying on the worked example is
misled. The remaining items are a present-tense overstatement of the unwired budget knobs in
two docs (Medium), a family-definition mismatch inside `diagnostic-policy.md` (Low–Medium),
and a missing `boolish` row (Low). None are contradictions that would mislead an implementer
about soundness; all four are cleanly fixable by either wiring the behaviour or adding the
same "not-yet-wired" honesty marker the budgets doc already models.
