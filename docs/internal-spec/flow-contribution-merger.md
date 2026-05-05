# Flow Contribution Merger (slice 3)

Status: **v0.1.0 slice 3 normative.** Pins the merge policy that
combines `FlowContribution` bundles from built-in narrowing rules,
`RBS::Extended` annotations, and plugins into a single
`MergeResult`. Binding design surface:
[ADR-2 § "Plugin Contribution Merging"](../adr/2-extension-api.md).

## Why this exists

Multiple flow contributions can target the same call: a built-in
narrowing rule and a plugin-provided fact may apply at the same
site, two plugins may both register for the same receiver family,
and `RBS::Extended` annotations may add their own facts. ADR-2
forbids first-wins / last-wins behaviour: contributions must
**merge deterministically**, and **contradictions** between
contributions must surface as **diagnostics**, not silent
overrides.

Slice 3 ships the standalone merger. Slice 4 routes built-in
narrowing through it; slice 5 wires plugin diagnostic provenance
through the result; slice 6 uses the merger's
`{provenances, conflicts}` to attribute plugin-side cache
entries.

## Public namespaces (drift-pinned)

Every namespace below is locked by
[`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb).

### `Rigor::FlowContribution#to_element_list`

Bundle → element list flattening. Walks every non-empty slot and
produces one or more {Element} value objects keyed by
`(target, edge, kind)`:

| slot                | edge          | kind                | target                  |
| ------------------- | ------------- | ------------------- | ----------------------- |
| `return_type`       | `normal`      | `return_type`       | `:return`               |
| `truthy_facts`      | `truthy`      | `truthy_fact`       | per-fact                |
| `falsey_facts`      | `falsey`      | `falsey_fact`       | per-fact                |
| `post_return_facts` | `post_return` | `post_return_fact`  | per-fact                |
| `mutations`         | `normal`      | `mutation`          | per-mutation            |
| `invalidations`     | `normal`      | `invalidation`      | per-fact                |
| `exceptional`       | `exceptional` | `exception`         | `:raise`                |
| `role_conformance`  | `normal`      | `role`              | per-role                |

Per-fact targets come from the payload's `#target` accessor when
present (typed-fact carriers, mutation effects); otherwise the
payload itself becomes the merge key. The flattening is
mechanical, deterministic, and round-trippable — feeding the
result back through `Merger.merge` produces an equivalent bundle.

### `Rigor::FlowContribution::Element`

Frozen `Data.define(:target, :edge, :kind, :payload, :provenance)`
value object. Constructor validates `edge` and `kind` against the
`ELEMENT_VALID_EDGES` / `ELEMENT_VALID_KINDS` enums. `#merge_key`
returns the `[target, edge, kind]` tuple the merger groups by.

### `Rigor::FlowContribution::Conflict`

Frozen `Data.define(:target, :edge, :kind, :reason, :provenances, :message)`.
`reason` is one of the slice-3 enum:

- `:return_type_collapse` — same-tier return types whose
  intersection is empty.
- `:exceptional_disagreement` — same-tier non-`nil` exceptional
  effects that disagree.
- `:lower_tier_contradiction` — a lower-tier contribution would
  weaken or contradict a higher-tier proof.

`provenances` carries every contributing
{FlowContribution::Provenance} (typically two — the higher-tier
and the contradicting one). `#to_h` renders the conflict for
diagnostic / formatter output.

### `Rigor::FlowContribution::MergeResult`

Frozen value object with the eight content slots from
`FlowContribution` (`return_type`, `truthy_facts`,
`falsey_facts`, `post_return_facts`, `mutations`,
`invalidations`, `exceptional`, `role_conformance`), plus
`provenances` (ordered list of every contributing provenance)
and `conflicts` (collected `Conflict` rows). `#conflict?` and
`#empty?` are predicates; `#to_h` renders the result for
diagnostics.

### `Rigor::FlowContribution::Merger`

Stateless module-level entry. Two surface methods:

- `Merger.merge(contributions)` — folds an array of bundles
  through the merge policy and returns a `MergeResult`.
- `Merger.tier_for(provenance)` — exposes the tier mapping the
  merger uses internally (useful for diagnostic formatters).

## Authority tiers

| Tier | Source family            | Notes |
| ---- | ------------------------ | ----- |
| 0    | `:builtin`               | Core Ruby semantics + accepted RBS contracts. Authoritative. |
| 1    | `:rbs_extended`          | `RBS::Extended` directive bundles (v0.0.9 group D reference impl). |
| 1    | `:generated`             | Generated signatures / metadata. |
| 2    | `:plugin`, `plugin.<id>` | Plugin contributions. |
| 3    | anything else            | Unknown — reported but treated as the lowest tier. |

Within a tier, contributions merge in deterministic order:
provenance-supplied `plugin_id` alphabetical (nil plugin ids sort
first to keep `:rbs_extended` / `:generated` pre-plugin
contributions stable), then by their original input position as
the final tie-break.

## Composition rules (per ADR-2)

- **`:return_type`.** Intersect via
  `Rigor::Type::Combinator.intersection`. The merger detects
  collapse via mutual `accepts` trinaries: when neither side
  accepts the other (`a.accepts(b).no? && b.accepts(a).no?`),
  the value domains are disjoint and the intersection is empty.
  Collapse at the same tier raises `:return_type_collapse`;
  collapse triggered by a lower tier raises
  `:lower_tier_contradiction`. The result keeps the higher-tier
  value for the slot.
- **`:truthy_fact` / `:falsey_fact` / `:post_return_fact`.**
  Edge-local. Plugin true-edge facts do NOT imply the false-edge
  complement. Same-tier and cross-tier facts accumulate while
  deduping by payload equality.
- **`:mutation` / `:invalidation` / `:role`.** Union; dedupe by
  equality.
- **`:exception`.** Single-valued. Equal exceptional effects
  collapse silently; non-equal effects raise either
  `:exceptional_disagreement` (same tier) or
  `:lower_tier_contradiction` (lower tier challenges higher).

## What slice 3 deliberately does NOT do

- **Wire built-in narrowing through the merger.** Slice 4's job.
- **Diagnose conflicts as `:contribution_merge` `Diagnostic`
  rows.** Slice 5 routes plugin diagnostic provenance through
  the formatter; slice 4 surfaces conflicts during analysis.
- **Compose `Cache::Descriptor` rows from the merge result.**
  Slice 6 picks that up alongside plugin-side cache producers.
- **Detect richer return-type-collapse cases.** The slice-3
  heuristic uses the `accepts` trinary; non-nominal carriers
  (Tuple intersection that collapses, structural intersection
  with a refined predicate that excludes every constant) fall
  through as non-collapsing for now. Slice 4 will exercise the
  full carrier matrix and fold any missed cases back into the
  merger.

## Round-trip property

The flattening is implemented to be invertible:

```ruby
contribution = Rigor::FlowContribution.new(...)
elements     = contribution.to_element_list
merged       = Rigor::FlowContribution::Merger.merge([contribution])
# merged carries the same slots as `contribution`, plus the
# provenance and an empty conflict list.
```

Slice 4 will exercise this round-trip alongside the analyzer's
existing narrowing call sites.
