# Docs audit — `docs/internal-spec/` fidelity + internal-consistency lens (2026-07-11)

Lens: verify each analyzer-internal contract claim against the actual engine code
(`lib/rigor/type/*`, `lib/rigor/inference/*`, `lib/rigor/scope*`), and check the
internal-spec corpus for self-consistency. Focus per the cycle: ADR-53 discovery
index, ADR-82/ADR-75 provenance side-tables, ADR-80 `type_specifier`→`narrowing_facts`.

## Findings

| Location (file:line + quote) | Problem | Severity | Proposed fix |
| --- | --- | --- | --- |
| `internal-type-api.md` §"Method Surface" (63–143) — "Every concrete type implementation MUST expose the method surface listed below" (capability predicates `string`/`integer`/…, projections `constant_strings`/…, relational `subtype_of`/`accepts`/`consistent_with`, structural `has_method`/`members`, meta `normalize`/`traverse`) | stale-api / aspirational-vs-implemented. The implemented carriers do **not** expose this surface: `Type::Nominal` (and peers) define only `describe` / `erase_to_rbs` / structural equality. Acceptance & subtyping live in `Inference::Acceptance` + `Type::AcceptanceRouter` (free functions, not carrier methods); capability checks live as `Type::Combinator` compatibility predicates (`literal_string_compatible?`, `non_zero_int_compatible?`, …). `def string`/`def integer`, `def subtype_of`, `def normalize`, `def traverse`, `def has_method` do not exist on any `lib/rigor/type/*` carrier. | Medium (softened by the doc's own §Scope disclaimer: names are placeholder, the concrete class catalogue is ADR-3 open-question-1, "MAY be renamed during implementation") | Add a status banner to §"Method Surface" noting it is the *as-designed* carrier contract; the realized architecture routes relational/capability operations through `Inference::Acceptance` / `Type::AcceptanceRouter` / `Type::Combinator` rather than as instance methods on the carriers. Keep the value-object sections (Trinary, AcceptsResult, identity) as-is — they are exact. |
| `internal-type-api.md` §"Operations and combinators" (114) — "`union(*types)`, `intersect(*types)`, `difference(left, right)`, `complement_within(domain, type)`" and (115) "`refine(base, predicate)`" | stale-api (naming/absence drift). Code (`type/combinator.rb`): `union` ✓, but `intersection` (not `intersect`), `refined(base, predicate_id)` (not `refine`), and **no `complement_within`** exists (only `difference`). | Low / informational (explicitly permitted by "working name … MAY be renamed") | Optional: update to the concrete spellings `intersection` / `refined`, and either drop `complement_within` or note it is unimplemented (complements are realized via `difference`). |
| `inference-engine.md:65` — DiscoveryIndex table list ends "…`data_member_layouts`, and `struct_member_layouts`." | stale-api / incomplete enumeration. `Scope::DiscoveryIndex` (`scope/discovery_index.rb`) has a 17th `Data.define` member: `param_inferred_types` (ADR-67 parameter inference / ADR-82 WD7 param enrichment), exposed via `Scope#param_inferred_types`. The doc presents the list as complete. | Low-Medium | Append `param_inferred_types` to the enumerated list; it satisfies the ADR-53 membership criterion (seed-time, flow-invariant). |
| `inference-engine.md` §Scope surface / §Discovery Index (40–71) — enumerates FactStore buckets and the discovery index but is silent on the ADR-75/ADR-82 provenance side-tables | coverage gap for a this-cycle surface change. `Scope` now carries three advisory side-tables — `dynamic_origins` (ADR-75, identity-keyed, `record_dynamic_origin`), `local_origins`, `ivar_origins` (ADR-82 WD1) — that are ignored by `Scope#==`/`#hash` and threaded through `rebuild`/`join`. The doc's Scope surface never mentions them. | Low | Add a short subsection ("Provenance side-tables (ADR-75 / ADR-82)") noting they are advisory metadata excluded from equality/flow decisions, mirroring how §Discovery Index handles the immutable ambient-context tables. |
| `inference-engine.md:95–100` — "`event` MUST be a `Rigor::Inference::Fallback` value object with the following structurally-equal fields: `node_class`, `location`, `family`, `inner_type`." | stale-api (minor). Code (`inference/fallback.rb`): `Fallback < Data.define(:node_class, :location, :family, :inner_type, :origin)` — a 5th `origin:` field (default `nil`, ADR-75 provenance) is omitted from the list presented as exhaustive. | Low | Add `origin` (optional, dynamic-provenance cause) to the field list, or reword "the following fields" → "at least the following fields". |

## What tracks the code correctly (verified, no defect)

- **`Type::AcceptsResult`** (`internal-type-api.md` §"Result Value Objects", 50–57) matches `type/accepts_result.rb` exactly: `trinary`/`mode`/`reasons`, `:gradual` ships / `:strict` reserved (raises), `with_reason` returns `self` on `nil`/empty and never mutates, `include ValueSemantics` + `value_fields :trinary,:mode,:reasons`, `yes?`/`no?`/`maybe?` delegate to the carried Trinary.
- **`Trinary`** (§"Trinary Result Value") matches `trinary.rb`: `yes`/`no`/`maybe` flyweights, `yes?`/`no?`/`maybe?`, and combinators `and`/`or`/`negate`.
- **FactStore buckets** (`inference-engine.md:56`) match `analysis/fact_store.rb` `BUCKETS` exactly (`local_binding`, `captured_local`, `object_content`, `global_storage`, `dynamic_origin`, `relational`); `Fact` carries `bucket/target/predicate/payload/polarity/stability`.
- **Discovery Index** (§ADR-53) is accurate on shape: immutable frozen `Data`, `Scope#with_discovery` is the sole seeder, the per-table `with_discovered_*` writers are gone, per-table readers (`user_def_for`, `data_member_layout`, …) survive as delegates. Only the member list is stale (see finding above).
- **Named Scope methods** all exist: `with_discovery`, `with_fact`, `local_facts`, `facts_for`, `type_of(node, tracer:)`, `join`, `user_def_for`, `data_member_layout`.
- **`diagnostic-shape.md`** matches `analysis/diagnostic.rb` exactly: the `path/line/column/message/severity/rule/source_family/receiver_type/method_name/project_definition_site` surface, `to_h` omit-when-nil for the three structured fields, and the correct note that `evidence_tier`/`documentation_url` are per-rule `RuleCatalog` enrichment (not `Diagnostic` fields). It correctly does **not** claim a `dynamic_origin` field (that is coverage-only).
- **ADR-80 rename is current**: `plugin.md` (229–316) and `flow-contribution.md` (14) document the author-facing verb as `narrowing_facts` with `type_specifier` marked deprecated (matching `plugin/base.rb`), while correctly leaving the engine reader / `rigor plugins` JSON key `type_specifier_methods` unchanged — exactly ADR-80's stated scope.

## Verdict

The internal-spec corpus tracks the current engine faithfully at its two load-bearing
layers: the concrete value-object contracts (Trinary, AcceptsResult, FactStore, Diagnostic)
and the cycle's structural changes (ADR-53 DiscoveryIndex, ADR-80's `narrowing_facts` rename)
are accurate down to method names and field lists, with only three small
enumeration-staleness slips (the omitted `param_inferred_types` discovery member, the omitted
`Fallback#origin` field, and no mention of the ADR-75/ADR-82 provenance side-tables). The one
substantive divergence is `internal-type-api.md`'s §"Method Surface", which still reads as the
founding-era as-designed carrier contract — describing capability/relational/structural
operations as instance methods "every concrete type MUST expose" — whereas the realized
architecture moved those operations off the carriers into `Inference::Acceptance` /
`Type::AcceptanceRouter` / `Type::Combinator`. That section is honest about being abstract
(explicit placeholder-names and open-question disclaimers), so it is not *wrong* so much as
*aspirational*, but a reader auditing "does carrier X expose `subtype_of`/`normalize`/`string`"
against the code would find it does not. A one-line status banner on that section would close
the last real gap; everything else is either exact or a trivial additive enumeration fix.
