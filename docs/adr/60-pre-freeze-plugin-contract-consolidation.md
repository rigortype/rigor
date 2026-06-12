# ADR-60: Pre-freeze plugin contract consolidation

- Status: Accepted (2026-06-13)
- Archetype: mechanical-policy (WD1, WD2, WD4, WD5) + deliberative (WD3)
- Stakes: moderate — three deliberate pre-1.0 BC breaks, but every affected
  consumer is bundled in this repository and the ADR-52 slice-5b migration
  protocol is established precedent. The cache-semantics change (WD3) is the
  high-stakes member: a wrong design ships silent stale caches.

## Context

[ADR-50](50-release-engineering-and-stability-strategy.md) freezes the
enumerated public plugin surface at v1.0.0. The
[2026-06-13 plugin-interface review](../notes/20260613-plugin-interface-bc-review.md)
audited the post-ADR-37/52/53 contract against all 31 production plugins +
6 examples and found no remaining performance-shaped interface problem, but
three defects that must be fixed **before** the freeze because they cannot be
fixed after it:

1. `external_files:` is a manifest field with zero engine consumers (the
   ADR-16 Tier D substrate was queued for slice 5b and never demand-gated in).
   Freezing it ships a permanently empty promise.
2. The macro value objects spell the same two concepts three ways:
   `BlockAsMethod` takes `verbs:` where `HeredocTemplate` / `TraitRegistry`
   take `method_name:`, and `NestedClassTemplate` takes `name_arg_position:`
   where the others take `symbol_arg_position:`.
3. `Plugin::Base#cache_for` snapshots its auto-built descriptor (the
   `IoBoundary` read history) at *call* time, but the producer block runs
   *later* — so reads performed inside the block are invisible to the cache
   descriptor. A producer that is written the obvious way caches stale.
   rigor-actionpack and rigor-rails-routes carry hand-written "prime the
   boundary **before** `cache_for`" comments because nothing in the contract
   enforces the ordering; 6 plugins additionally hand-compose
   `glob_descriptor` rows to cover file addition/removal.

The same review measured the authoring boilerplate this ADR's additive tier
(WD4) absorbs: 12 plugins hand-roll `*_index_or_nil` lazy memos (4 with an
explicit `_resolved` flag to distinguish "unqueried" from "queried, nil"),
and ~23 `node_rule` plugins repeat the same violation→`diagnostic` mapping.

## Decision criterion

**A surface may enter the v1.0 freeze only if it is (a) wired to an engine
consumer, (b) named consistently with its siblings, and (c) incapable of
producing silently-wrong results when used the way its own documentation
shows.** Surfaces failing (a) are removed (re-introduction is demand-gated
and must land with its engine consumer in the same change); failures of (b)
are renamed now while every consumer is bundled; failures of (c) are
redesigned so the correct usage is the only expressible usage.

## WD1 — Remove `external_files:` (and `Macro::ExternalFile`)

Delete the manifest field, its validation, its `to_h` row, the
`Macro::ExternalFile` value object, and the CLI capability-count plumbing.
A plugin passing `external_files:` fails at class-definition time with the
standard unknown-keyword `ArgumentError` — loud, not silent. ADR-16 Tier D
remains a recorded design; when a concrete target (Redmine webhook payloads,
tDiary plugin loader) demands it, the field returns **with** its scanner in
one change.

## WD2 — Normalize macro value-object naming

| Object | Old keyword | New keyword |
| --- | --- | --- |
| `Macro::BlockAsMethod` | `verbs:` | `method_names:` |
| `Macro::NestedClassTemplate` | `name_arg_position:` | `symbol_arg_position:` |

Readers (`#verbs` → `#method_names`, `#name_arg_position` →
`#symbol_arg_position`) and `to_h` keys follow. No alias, no deprecation
shim — the pre-1.0 window exists precisely so the frozen surface has one
spelling. Engine-internal index naming (`block_entries_by_verb` etc.) is
free to follow for coherence but is not contract. Migrated in the same
change: rigor-sinatra, rigor-devise (block_as_methods), rigor-mangrove
(nested_class_templates), and their specs.

## WD3 — Producer `watch:` + record-and-validate `cache_for`

The ordering hazard is structural: `fetch_or_compute` requires the full
descriptor *before* the value is computed, but a producer's inputs are
exactly what its block reads. ADR-45 already built the sound alternative
for the run-result cache — `Cache::Store#fetch_or_validate`, which keys an
entry on the *stable* inputs and stores, beside the value, a dependency
descriptor recorded **after** the computation, re-validated by re-digest on
the next run (`Descriptor#fresh?`). WD3 moves plugin producers onto it.

New surface:

- `Cache::Descriptor::GlobEntry.new(root:, pattern:, value:)` — `value` is
  the SHA-256 over the sorted `[relative_path, content_digest]` pairs of
  every file matching `File.join(root, pattern)`. One entry covers content
  change, addition, and removal. `Descriptor#fresh?` re-globs and
  re-digests; `#cache_key_for` serialization includes the new collection.
- `producer :id, watch: …` — declares the glob coverage of a
  discovery-style producer. `watch:` is either a static Array of
  `[roots, pattern, …]` tuples or a Proc (run through `instance_exec` at
  `cache_for` invocation, so `init`-derived roots work). Evaluated per
  `cache_for` call, never at class-definition time.
- `cache_for(id, params:, descriptor: nil)` switches to
  `fetch_or_validate`: the **key** descriptor is the `PluginEntry` template
  (id, version, config digest) composed with the optional `descriptor:`
  extras (gem pins, `ConfigEntry` rows — *identity* inputs); the
  **dependency** descriptor is recorded after the block runs — the
  `IoBoundary`'s post-compute read history plus the evaluated `watch:`
  `GlobEntry` rows. In-block reads are therefore always captured; the
  "prime before `cache_for`" idiom and hand-composed `glob_descriptor`
  call-sites are deleted. `Plugin::Base#glob_descriptor` goes private
  (it remains the `watch:` machinery's implementation).

Costs accepted: one glob + content re-digest per watched producer per
process on the validate path (the old `glob_descriptor` paid the same digest
at every `cache_for` call, so this is not a regression); the post-compute
boundary snapshot over-approximates (it includes reads from earlier
producers on the same plugin instance), which can only cause a spurious
recompute, never a stale hit.

Rejected within WD3:
- *Keeping `fetch_or_compute` + making `watch:` mandatory* — leaves the
  boundary-history half of the hazard in place for non-glob producers
  (e.g. single-file `db/schema.rb` reads) and keeps two descriptor
  disciplines alive.
- *A lint that detects `io_boundary` reads after `cache_for`* — detection
  instead of correction; the contract would still be order-sensitive.

## WD4 — Additive authoring helpers (not BC, lands in the same arc)

- `Plugin::Base#read_fact(plugin_id:, name:)` — `services.fact_store.read`
  with a nil-inclusive per-instance memo. Kills the `_resolved`-flag idiom.
- `Plugin::Base#producer_value(id, params: {})` — `cache_for(id).call`
  with a nil-inclusive per-`(id, params)` memo and a `StandardError` rescue
  that records the failure (readable via `#producer_error(id)`) and returns
  nil — the dominant `*_index_or_nil` shape, named. Plugins that want to
  surface the failure emit a diagnostic from `producer_error` in
  `diagnostics_for_file` exactly as they do today.
- `Plugin::Base#diagnostics_for(violations, path:)` — maps duck-typed
  violation objects (`#location`, `#message`, optional `#severity`,
  `#rule`) through `#diagnostic`, absorbing the repeated `.map` block.

These define the *final* authoring idiom the v1.0 freeze enumerates; the 12
`*_or_nil` / 7 `fact_store.read` / ~23 mapping sites migrate so the bundled
corpus demonstrates one way to write a plugin.

## WD5 — Documentation alignment

The review's Tier 3 keep-verdicts (the `dynamic_return` / `type_specifier`
split, `diagnostics_for_file` as the file-rule surface, the `config_schema`
dual grammar) are design decisions, not gaps — they are documented as such.
The contributor SKILL (`.claude/skills/rigor-plugin-author`) and the
external-author SKILL (`skills/rigor-plugin-author`) gain: the
`type_specifier` and `TypeNodeResolver` surfaces, the two fact-publishing
styles (`prepare`+`publish` for light scans vs `producer` for cached
discovery) with the selection rule, the error-handling guidance
(`producer_value` + `producer_error` as the standard), and the WD2/WD3
renames.

## Alternatives rejected (recorded so they are not relitigated at freeze)

- **Unify `dynamic_return` / `type_specifier` into one DSL** — the split is
  principled: return-type vs post-return facts, dispatcher vs statement
  evaluator, different compiled-gate shapes. A merged DSL would fork
  internally on an `on:` discriminator and buy only a rename.
- **Delete `diagnostics_for_file`** — 15 plugins use it for file-level
  diagnostics a node walk cannot express (discovery load errors,
  cross-file aggregation). It is gated by the ContributionIndex and costs
  nothing; it is the file-rule surface, not a legacy node-rule.
- **Ban the bare `config_schema` kind form** — ADR-40 adopted the
  `{kind:, default:}` Hash as a deliberate superset of the bare kind; the
  migration cost buys nothing.

## Verification

Per the ADR-52 slice-5b precedent, each WD lands with: loud load-time
failure for the removed/renamed spelling (no silent degradation), a
CHANGELOG migration table, every bundled consumer migrated in the same
changeset, and `make verify` (self-check + `check-plugins`) green. WD3
additionally gates on: the cross-process plugin-cache regression family
(ADR-45's `pundit_plugin_spec` pattern — edit a watched file between two
processes, assert the producer recomputes; delete/add a glob-matched file,
same), Mastodon / GitLab corpus runs byte-identical, and `make bench-perf`
neutral. WD4 migrations are behaviour-preserving and ride the same gates.
