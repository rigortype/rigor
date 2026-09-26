# frozen_string_literal: true

# ADR-107 gate G3 (issue #825) — every declaration in `sig/` earns its place in one of four ways.
#
# ADR-107 § Decision gives `sig/` a provenance rule that follows ADR-5's asymmetry: a RETURN type is
# generated (clause 1 — `rigor sig-gen` proves it from the body), a PARAMETER type is authored intent
# (clause 2 keeps it lenient and inference never derives one), and anything else hand-written is a gap
# `sig-gen` could not close, which ADR-14's contradiction rule says must be RECORDED rather than
# assumed. A declared `void` return joins the authored-intent half (#836), and so does a declared type
# the body proves as a literal (#837): each says the return the author means is not the one the body
# happens to expose, and no synthesis produces either, since a type built from a body is always the type
# of the body's last expression. `spec/support/sig_provenance_auditor.rb` carries the classifier and the
# marker convention. There are two markers, per the 2026-09-19 ruling on #1011:
#
#     # sig-gen gap: #825 — sig-gen types the body `untyped`, so the return is hand-written.
#     def resolve: (String name) -> Type::t
#
# cites an allow-listed issue that tracks the ENGINE GAP (`spec/rigor/sig_gen/gap_issues.yml`); an
# intentionally hand-written row — no engine work would ever answer it — carries
#
#     # authored: hook-contract widening — the element type comes from a plugin gem sig-gen never sees.
#
# instead and cites nothing.
#
# == Three mechanisms, and why not one
#
# The seeding audit (`docs/notes/20260908-sig-provenance-audit.md`) found 358 of 1,052 in-scope
# declarations earned and 679 residue — 671 once the nine stale declarations the audit also turned up
# were deleted. A per-declaration marker on 671 rows is not a gate, it is a rewrite of `sig/`, and a
# check that fires 671 times on a correct tree is the false-positive failure mode AGENTS.md
# § Implementation Guidelines puts above worst-case static reading. So:
#
# 1. HARD RULE on `tighter_return`. `sig-gen` proposes a narrower return than the declaration; ADR-14
#    says apply it or record why not, and there are 0 — the seeding audit's 15 less the seven #836
#    stopped proposing, the six #837 did (its own five, plus the `Reflection.class_ordering` row #838
#    had filed as applicable), and the three #838 applied — so a marker on each is affordable. The first
#    fails on arrival.
# 2. RATCHET on the residue. Per-file unmarked-residue counts are an exact snapshot below. A new
#    hand-written declaration raises its file's count and goes red; marking it subtracts from the
#    count. Closing an engine gap lowers a count and the gate says so, so slack cannot accumulate.
# 3. HARD RULE on existence (#839). Every declaration must describe a method that EXISTS — proven by
#    `sig-gen`'s `def`, by Rigor's own cross-file recognition, or by reflection over the loaded tree.
#    Nothing else in the tree asks this direction: `make check` and `make steep-check` both ask
#    whether the implementation matches `sig/`. Zero on a correct tree, so a hard rule costs nothing;
#    it was nine before the seeding audit deleted them.
#
# == Why this file and not `spec/docs/`
#
# The classifier runs `SigGen::Generator` over all of `lib/` in-process — ~10 s on a 12-core M3 Max,
# paid once at file load (measured 2026-09-08: this file loads in 10.4 s and its examples run in
# 2.6 s). `make docs-check` is 1.2 s of load plus 5.4 s of examples today, so hanging this off it
# would nearly triple the cheap gate. It belongs with the other `sig-gen` specs, where CI's sharded
# `Tests` job already carries the cost.
require "spec_helper"
require "fileutils"
require "tmpdir"
require "yaml"

SIG_PROVENANCE_ROOT = File.expand_path("../../..", __dir__)

# The gap issues a `# sig-gen gap:` marker may cite (ADR-107 G3; ruling 2026-09-19 on #1011).
# Committed and checked OFFLINE — this file is the reviewed artefact, so `make verify` never
# touches the network. Closing a gap issue means removing it here, which fails the allow-list
# example below until the markers that cite it move.
GAP_ISSUE_ALLOW_LIST = YAML.safe_load_file(File.join(__dir__, "gap_issues.yml")).freeze

# Computed once (a ~14 s generator pass) and shared read-only across the corpus examples.
# `runtime: true` opts the #839 existence tiers in: the project index over `lib/`, then a require of
# `lib/` and reflection over it (`spec/support/sig_source_index.rb`). Safe here and nowhere else in
# this file — the fixture audits below write their own `lib/`, and requiring one would run it.
SIG_PROVENANCE_ROWS = SigProvenanceAuditor.audit(root: SIG_PROVENANCE_ROOT, runtime: true)

# A corpus failure must stay readable; the total is always stated even when the listing is truncated.
SIG_PROVENANCE_LISTING_CAP = 200

# Unmarked residue per file, exact. Raise a number only with the reason in the commit body; lower one
# whenever an engine fix or a marker earns it. Files absent from the map must carry zero residue.
# Seeded 2026-09-08 from the audit note's table at 671; 669 since #836 — `RbsLoader.reset_default!`
# and `CheckRules.shadow_verify_converged_collectors` are `-> void` declarations that used to land in
# `declared_divergent` and are now return intent; 677 once ADR-109 slice 2 added the `Type::FloatRange`
# carrier; 683 since #837. That fix retires five markers whose rows
# are `declared_divergent` rather than `tighter_return` now that no literal is proposed for them
# (`cache.rbs` +1, `trinary.rbs` +1, `type.rbs` +3), and a sixth — `Type::FloatRange#describe`, seeded by
# ADR-109 slice 2 against a proposal the fix prevents — came out with them (`type.rbs` +1). The ratchet
# counts them like every other declared lenience the generator protects; `Configuration.discover`'s
# `String?` has always sat in this bucket for the same reason.
#
# 666 since #995. `Generator#translate_method_type_return` translated a declared return with no
# `alias_expander:`, so ANY declared return spelled through a project alias (`Type::t`,
# `Environment::ordering`, `Inference::closure_classification`), not only a bare `untyped`, degraded
# to `Dynamic[Top]` — the same misreading whether the alias sat at the top level (making
# `declared_untyped?` true and landing a spurious `tighter_return`, e.g. the three `class_ordering`s
# and most of `inference.rbs`'s and `type.rbs`'s share of the 22 the "unmarked tighter-return" example
# used to list) or nested inside a compound declared type such as `[Type::t, Scope]` or
# `Hash[String, Type::t]` (making the OUTER type merely fail to text-match what sig-gen infers, which
# `declared_divergent` — already residue before #995 — absorbed without ever surfacing as a
# `tighter_return`). Passing the environment's `RbsLoader` as `alias_expander:` (the idiom
# `check_rules.rb` already uses) lets every one of these resolve to its real expansion instead. Most
# now compare exactly equal to what sig-gen infers and leave residue entirely (`environment.rbs`'s
# three `class_ordering`s, `inference.rbs`'s `statements_or_nil` / `classify_closure_escape` /
# `narrow_truthy` / `narrow_non_nil` / `ClosureEscapeAnalyzer#classify` / `evaluate` /
# `user_method_return`, `scope.rbs`'s `type_of`, `type.rbs`'s seven `Combinator` methods declared
# `-> Type::t` plus `int_mask` / `int_mask_of`, and `reflection.rbs`'s `constant_type_for` — a
# pre-existing, unrelated misclassification this fix incidentally corrects); `inference.rbs`'s
# `fallback_for` resolves to `declared_divergent` instead (still residue — its body is always
# `Type::Dynamic`, genuinely narrower than the now-correct `Type::t` union, but no longer needs a
# `tighter_return` marker). Resolving the same alias inside a nested generic argument also surfaced
# one previously-hidden, genuine tightening applied here — `ScopeIndexer.finalize_constant_writes`'s
# declared `Hash[String, Type::t]` narrows to `Hash[String, Type::Constant]`. Net per file, each
# verified against a real `bundle exec rspec spec/rigor/sig_gen/provenance_spec.rb` run:
# `environment.rbs` -3, `inference.rbs` -7, `scope.rbs` -3, `type.rbs` -9, `reflection.rbs` -1.
# `plugin/base.rbs` drops 4 for an unrelated reason: three bare-`untyped` members (`self.node_rule`,
# `diagnostic`, `cache_for`) are genuinely single-implementation, always-true facts and are applied;
# `dynamic_return_type`'s literal-`nil` proposal is wrong (its real `instance_exec`'d-block branch is
# unseen) and is marked `#1007`. `rigor.rbs` drops 1: `Runner#return_summaries`'s `{}` proposal is
# wrong for the same reason, applied to a Hash mutated by a sibling method, and marked `#1008`.
#
# 664 since #994. Element-wise union absorption collapses the inferred return of
# `StatementEvaluator#eval_branch_or_nil` and `#eval_class_body` — each a union of same-arity
# `[Type::t, Scope]` tuples whose narrower arms are contained in a wider one — down to the single
# tuple the declaration already names, so both leave `declared_divergent` for generated-equivalent
# (`inference.rbs` -2). It needs #995's alias expansion as well: without it the declared `Type::t`
# element read as `untyped` and no inferred form could ever compare equal.
#
# 663 since #1016. A value-position `&&` now narrows its right operand, so
# `Type::AnonymousClassName.match?`'s `class_name.is_a?(String) && class_name.start_with?(PREFIX)` over an
# untyped parameter calls `start_with?` on `String` rather than on `untyped`; sig-gen proves `bool`, the
# declared return, and the row leaves `unrenderable` for generated-equivalent (`type.rbs` -1).
#
# 662 since #1101. A composite receiver is now dispatched per projected member, so a union with a
# `Dynamic[top]` member reaches the receiver-independent `UniversalObjectDispatch` table it could not
# reach as a union: `Literals#symbol_named?`'s `node.is_a?(Prism::SymbolNode)` over a `Dynamic[top]?`
# parameter, and `Scope#published_constant?`'s `!locally_declared_constant?(name)` over a
# `false | true | Dynamic[top]` return, both fold `bool` instead of `untyped`. Each method's inferred
# return reaches the `bool` its declaration states, so both rows leave `unrenderable` for parameter
# intent (`scope.rbs` -1, `source.rbs` -1).
# 658 since the named-return sig pass. Naming `Prism::Node?` on the four `NodeLocator` readers matches
# what sig-gen already proved, so `source.rbs` -4 (unrenderable → parameter intent); `Scope#top_level_def_for`
# now declared `Prism::DefNode?` lets sig-gen prove `#bindable_top_level_def_for`, `scope.rbs` -1, and
# `#user_def_through_ancestors` / `#singleton_def_through_ancestors` are re-declared to the
# `[Prism::DefNode, String] | [nil, nil]` sig-gen now proves through them. `skip_reason_catalog.rbs` +1:
# `Entry#to_h` declared `Hash[String, String]` reads as divergent from the inferred
# `Hash[String, "sig_skip_reason" | String]` because a literal is not absorbed into its nominal in the
# rendered comparison — a normalization gap, not a wrong declaration.
#
# 661 since #1123, all three rows in `sig/rigor/scope.rbs` (108 -> 111). Two are the readers of the new
# instance-side prepend table, in exactly the shape every other discovery table carries them:
# `Scope#discovered_prepends` (`sig.skipped.untyped-return` — an endless-def reader over a
# `Data.define` member, like its `discovered_includes` sibling) and the `DiscoveryIndex#discovered_prepends`
# `Data` member itself (`synthetic_source`, like every member row of that class). The third is
# `Scope#user_def_through_ancestors`, which the change gives a second return path — the prepend wedge —
# reached through two private recursive helpers, so `sig-gen` no longer proves the
# `[Prism::DefNode, String] | [nil, nil]` the named-return pass declared and the row reads as
# `declared_divergent`, even though the walk still only ever answers a resolved def or `[nil, nil]`.
# Narrowing that back is engine work on a recursive private helper's array element type, not a
# contract change here; the declaration is left as the true one.
#
# 659 since #1172's fix. The declared `::RBS::Definition?` on `Environment#instance_definition` /
# `#singleton_definition` — deferred at the named-return pass because the fold gap made the honest
# declaration fire `flow.always-truthy-condition` on three live `lib/` guards — matches what sig-gen
# already proved, so both rows leave residue for generated-equivalent (`environment.rbs` -2). The
# `Reflection` pair were already non-residue as `untyped`.
# 711 since #1278. A closed, non-empty `HashShape` now reads a computed key as its values `| nil` instead of
# deferring to the nil-free projection, so `SkipReasonCatalog.resolve`'s `ENTRIES[token.to_s]` infers the
# `Entry?` its declaration states and the row leaves residue (`skip_reason_catalog.rbs` -1).
# 710 since #1390. sig-gen now credits a `return` inside an ordinary block to the method (#1382), so
# `RbsExtended.read_return_type_override`'s `annotations.each { … return type if type }; nil` infers the
# declared `Type::t?` instead of the trailing `nil`, and the row leaves `declared_divergent` for
# generated-equivalent (`rbs_extended.rbs` -1).
# 709 since #1424. `StatementEvaluator::ClassFrame` gains an optional `refinement:` member, and the keyword
# default is written as an explicit `def initialize`, so its declared `initialize` now has a source `def`
# sig-gen reproduces instead of the `Data`-synthesised one it could only find at runtime (`inference.rbs` -1).
# 710 since #1412. A loop body now enters with each local it mutates in place at its unknown-store widening,
# so `Scope#singleton_def_through_ancestors`'s `queue.shift` after `enqueue_ancestors(current, queue, …)` reads
# `untyped` where the seed read `String` — correct at runtime, so a precision loss — and the row joins
# `declared_divergent` (`scope.rbs` +1; the reason is at its pin).
SIG_PROVENANCE_RESIDUE = {
  "sig/prism_node_children.rbs" => 1,
  # +1 (#1181 bound-side slice): `effect_envelopes` is a newly-declared public reader that stays
  # unrenderable residue — its body memoises through `effect_envelope_index(@run_environment)`, a
  # private helper sig-gen cannot infer. The collection-side slice then typed `effect_table`,
  # `effect_collection`, `effect_plugin_facts`, `effect_ancestry`,
  # `effect_collections_by_path`, `adopt_effect_collections`, `adopt_effect_summary` and
  # `effects_served_from_cache?`: `effect_collection`, `effect_plugin_facts`,
  # `adopt_effect_summary` and `effects_served_from_cache?` classify as earned (generated or
  # return intent), and the rest stay unrenderable — net 0 residue rows over the `untyped`
  # declarations they replaced. `forced_file_effects` was typed and
  # then dropped on review: the method is `private` (runner.rb's `private :…` list) and private
  # API is not declared in this sig.
  "sig/rigor.rbs" => 51,
  # -4 (#1181 slice): Bucket/DriftRow member rows are marked under #1183 and `buckets` under #1154;
  # `audit`/`without`/`initialize` tightened to generated/intent, leaving `filter`'s honest
  # `[Array[untyped], Integer]` divergence as the sole unmarked row.
  "sig/rigor/analysis/baseline.rbs" => 1,
  "sig/rigor/analysis/check_rules/always_truthy_condition_collector.rbs" => 1,
  "sig/rigor/analysis/check_rules/dead_assignment_collector.rbs" => 1,
  "sig/rigor/analysis/dependency_source_inference/gem_resolver.rbs" => 1,
  # -2 (#1092): an RBS `-> self` return keeps the receiver's type arguments, so `FactStore#normalize`
  # and `CheckRules.filter_suppressed` stop inferring the raw `Array`; both now classify as parameter
  # intent (their declared `Array[Fact]` / `Array[Diagnostic]` follows from the declared parameters).
  "sig/rigor/analysis/fact_store.rbs" => 15,
  # New file (#1181 slice): the three members whose element classes are not sig-covered yet
  # (`synthetic_method_index`, `project_patched_methods`, `template_units`) stay `untyped` — they are
  # Data members sig-gen cannot infer, but the declared type is `untyped` anyway, so no gap marker
  # applies; they pin as unmarked residue. The typed members and both constructors are #1150-marked.
  "sig/rigor/analysis/project_scan.rbs" => 3,
  "sig/rigor/ast.rbs" => 1,
  "sig/rigor/cache.rbs" => 2,
  "sig/rigor/cli/diff_command.rbs" => 1,
  "sig/rigor/cli/explain_command.rbs" => 1,
  "sig/rigor/cli/sig_gen_command.rbs" => 2,
  "sig/rigor/cli/type_scan_command.rbs" => 1,
  # New files (#1181 slice): the bound side of `Effects::*`. Marked rows are #1150 Data members;
  # unmarked residue is the ordinary unrenderable/declared-divergent mix (`label_set.rbs` also pins
  # the `eql?` alias row, `origin.rbs`/`taint_cause.rbs` fully classify).
  "sig/rigor/effects/config_envelopes.rbs" => 3,
  # New file (#1181 collection-side slice): `Entry`'s members and constructors are #1150-marked;
  # the five unmarked rows are `[]`/`keys`/`each`/`size`/`empty?` — unrenderable
  # (`sig.skipped.untyped-return`, all single-expression readers sig-gen declines).
  "sig/rigor/effects/effect_table.rbs" => 5,
  # -1 (#1181 collection-side slice): `Envelope#tolerates?` reads `Summary::TRIVIAL_BOUND`, and
  # `Summary` being declared lets sig-gen resolve the reference it could not name before.
  "sig/rigor/effects/envelope.rbs" => 1,
  "sig/rigor/effects/envelope_index.rbs" => 2,
  # New file (#1181 collection-side slice): `Edge` members/constructors are #1150-marked and the
  # five attr_readers #1154-marked; the sole unmarked row is `empty?` (unrenderable).
  "sig/rigor/effects/file_collection.rbs" => 1,
  "sig/rigor/effects/label.rbs" => 5,
  "sig/rigor/effects/label_set.rbs" => 8,
  "sig/rigor/effects/method_key.rbs" => 3,
  "sig/rigor/effects/origin.rbs" => 0,
  # New file (#1181 collection-side slice): `Row`/`Edge` members and constructors are
  # #1150-marked. Eleven unmarked rows: five attr_readers (`unit_callee_rows`, `warnings`,
  # `labels_by_owner`, `digest`, `entry_points`) are built by `absorb`/`compute_digest` rather
  # than assigned from `initialize` parameters, so #1154 does not cover them (same shape as
  # `Registry#additional_initializers`); `entry_points` joined residue in the vocabulary slice
  # when its element type was typed (`Array[EffectEntryPoints]` vs the `Array[untyped]` sig-gen
  # proves — declared-divergent). `class_row` and `result_row` are declared-divergent (sig-gen
  # infers `nil` — the `ancestry` memo helper is opaque to it), `edges_for` is
  # declared-divergent (`Array[untyped]` from `select`), and `path_row` / `self_path_row` /
  # `descends_from?` are unrenderable. `extend_registry` left residue the same slice — typed
  # `Effects::Registry` in and out makes it parameter-intent.
  "sig/rigor/effects/plugin_facts.rbs" => 11,
  # New file (#1181 vocabulary slice): `vocabulary_version`, `labels` and `descriptions` are
  # #1154-marked — the issue covers any ivar assigned in `initialize` from a parameter,
  # normalized or verbatim; `roots` is computed from `@known` — not a parameter — so it pins
  # unmarked. The factories/`with` are earned; `known?`, `suggest`, `retired` are unrenderable —
  # their bodies route through private helpers sig-gen declines.
  "sig/rigor/effects/registry.rbs" => 4,
  # New file (#1181 collection-side slice): `bundles`/`declared_bundles`/`causes` are
  # #1154-marked (normalized `initialize` kwargs), while `declared`/`proven` are flattened from
  # the bundle tables — not parameters — so they pin unmarked beside `trivial?` (unrenderable).
  "sig/rigor/effects/summary.rbs" => 3,
  "sig/rigor/effects/taint_cause.rbs" => 0,
  "sig/rigor/environment.rbs" => 39,
  # -1 (#1429): a value-position `case` now types each arm under the subject's `when` narrowing, so
  # `ExpressionTyper#type_of_virtual`'s `when AST::TypeNode then node.type` arm reads `node` as the node class
  # and its return renders.
  "sig/rigor/inference.rbs" => 83,
  "sig/rigor/inference/builtins/method_catalog.rbs" => 1,
  "sig/rigor/inference/void_origin.rbs" => 5,
  "sig/rigor/plugin.rbs" => 3,
  # New file (#1181 slice): the `alias eql? ==` row has no sig-gen shape — the sole residue.
  "sig/rigor/plugin/additional_initializer.rbs" => 1,
  # New file (#1181 vocabulary slice): the init-parameter readers are #1154-marked; the three
  # unmarked rows are the computed predicates `receiver_path?`/`self_path?` (`include?`/
  # `start_with?` bodies sig-gen declines) and the `eql?` alias row.
  "sig/rigor/plugin/effect_attribution.rbs" => 3,
  # New files (#1181 vocabulary slice): sole residue in each is the `eql?` alias row.
  "sig/rigor/plugin/effect_ancestry.rbs" => 1,
  "sig/rigor/plugin/effect_edge.rbs" => 1,
  "sig/rigor/plugin/effect_entry_points.rbs" => 1,
  # -1 (#1181 slice): `protocol_contracts` tightened to `Array[ProtocolContract]` — sig-gen
  # already inferred that exact type through `manifest.protocol_contracts`, so the row is
  # generated-equivalent now.
  "sig/rigor/plugin/base.rbs" => 21,
  "sig/rigor/plugin/blueprint.rbs" => 3,
  "sig/rigor/plugin/fact_store.rbs" => 2,
  # -2 (#720): `file?` / `directory?` are `probe(path) { … }`, and the block's `bool` now reaches the
  # caller, so sig-gen generates what the two hand-written declarations say.
  "sig/rigor/plugin/io_boundary.rbs" => 2,
  "sig/rigor/plugin/load_error.rbs" => 3,
  "sig/rigor/plugin/loader.rbs" => 2,
  # -2 (#1181 slices): `additional_initializers` and `protocol_contracts` tightened to
  # `Array[Plugin::AdditionalInitializer]` / `Array[Plugin::ProtocolContract]` and marked #1154.
  # +1 (#1181 vocabulary slice): the six `effect_*` readers are #1154-marked and `effects?` /
  # `effect_owner` earned (the reader bound once into a local narrows, so sig-gen proves
  # `String`); `effect_discharge_allowed?` is unrenderable.
  "sig/rigor/plugin/manifest.rbs" => 22,
  # New file (#1181 slice): `to_h` is declared-divergent (sig-gen infers a string-literal-keyed
  # union; `Hash[String, untyped]` matches the manifest `to_h` convention) and `eql?` is an alias
  # row with no sig-gen shape.
  "sig/rigor/plugin/protocol_contract.rbs" => 2,
  # +4 (#1181 slices): `additional_initializers`, `protocol_contracts` and
  # `effect_contributions` readers are unmarked residue — `compile_aggregates` /
  # `compile_effect_contributions` build the ivars with `flat_map`/`filter_map` (memoised for the
  # latter), not from `initialize` parameters, so no gap issue covers them;
  # `contracts_for_path` is declared-divergent (sig-gen infers the `path.nil?` `[]` arm
  # separately). `Contribution`'s members and constructors are #1150-marked.
  "sig/rigor/plugin/registry.rbs" => 13,
  # -1 (#1181 slice): `read_effect_envelope` now returns `Effects::Envelope?`, which sig-gen proves
  # through the `build_*_envelope` helpers — no longer residue. -1 (#1390): `read_return_type_override`'s
  # block `return` now reaches its inferred return, which matches the declared `Type::t?`.
  "sig/rigor/rbs_extended.rbs" => 21,
  "sig/rigor/reflection.rbs" => 8,
  # +1 (#1412): `singleton_def_through_ancestors` walks `until queue.empty?; current = queue.shift; …;
  # enqueue_ancestors(current, queue, …)`. The loop body now enters with `queue` at its unknown-store
  # widening, and a callee store floors it to `Array[untyped]`, as straight-line code after the same call
  # already reads it, so `current` and the `[found, current]` return are `untyped`. At runtime the queue only
  # ever holds Strings (`enqueue_ancestors` pushes resolved class names), so the `String` sig-gen proved from
  # the seed `[class_name.to_s]` was right: this is a precision loss the callee floor causes, not a
  # correction. `user_def_through_ancestors` (already residue) loses its `[Prism::DefNode, String]` arm the
  # same way.
  "sig/rigor/scope.rbs" => 112,
  "sig/rigor/sig_gen/skip_reason_catalog.rbs" => 8,
  "sig/rigor/source.rbs" => 4,
  "sig/rigor/testing.rbs" => 4,
  "sig/rigor/trinary.rbs" => 5,
  # -3 (#1429): a value-position `case` now types each arm under the subject's `when` narrowing, so the
  # `when Constant then type.value.is_a?(String)` arms of `Combinator#literal_string_compatible?`,
  # `#non_empty_string_compatible?` and `#non_zero_int_compatible?` read `type` as the carrier the `when` names
  # rather than `untyped`, and each `bool` return renders.
  "sig/rigor/type.rbs" => 208
}.freeze

module SigProvenanceSpecHelpers
  def provenance_failure(label, rows)
    lines = rows.map(&:to_s)
    shown = lines.first(SIG_PROVENANCE_LISTING_CAP)
    suffix = lines.size > shown.size ? "\n  … #{lines.size - shown.size} more" : ""
    "#{label}: #{lines.size} declaration(s)\n  #{shown.join("\n  ")}#{suffix}"
  end

  # Runs the whole classifier over a two-file fixture project, so a unit example exercises the same
  # join the corpus examples do rather than a parallel reimplementation of it.
  def audit_fixture(ruby:, rbs:)
    write_fixture("lib/fixture.rb", ruby)
    write_fixture("sig/fixture.rbs", rbs)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["lib"], "signature_paths" => [File.join(fixture_root, "sig")]
      )
    )
    SigProvenanceAuditor.audit(root: fixture_root, configuration: configuration)
  end

  def classifications_for(ruby:, rbs:, method: nil)
    audit_fixture(ruby: ruby, rbs: rbs)
      .reject { |row| row.classification == SigProvenanceAuditor::NON_METHOD }
      .select { |row| method.nil? || row.declaration.method_name == method }
      .map(&:classification)
  end

  def write_fixture(relative, contents)
    full = File.join(fixture_root, relative)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
  end
end

RSpec.describe "sig/ provenance (ADR-107 G3)" do
  include SigProvenanceSpecHelpers

  describe "the classifier (fixture projects, independent of the corpus)" do
    let(:fixture_root) { Dir.mktmpdir }

    after { FileUtils.remove_entry(fixture_root) }

    it "calls a declaration whose return is what sig-gen proves `generated`" do
      rows = classifications_for(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                                 rbs: "class Widget\n  def n: () -> 42\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::GENERATED])
    end

    it "calls the same declaration with a typed parameter `parameter_intent` (ADR-5 clause 2)" do
      rows = classifications_for(ruby: "class Widget\n  def n(x)\n    42\n  end\nend\n",
                                 rbs: "class Widget\n  def n: (Integer x) -> 42\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::PARAMETER_INTENT])
    end

    it "calls a constructor stub earned — sig-gen always spells `initialize` as `-> void`" do
      rows = classifications_for(ruby: "class Widget\n  def initialize(x)\n    @x = x\n  end\nend\n",
                                 rbs: "class Widget\n  def initialize: (Integer x) -> void\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::RETURN_INTENT])
    end

    it "calls any `-> void` declaration `return_intent`, not only a constructor's (#836)" do
      # `void` says the return is not part of the contract, so there is nothing for sig-gen to prove
      # and nothing to record: the declaration is earned without a marker.
      rows = classifications_for(ruby: "class Widget\n  def register(x)\n    @x = [x]\n  end\nend\n",
                                 rbs: "class Widget\n  def register: (untyped x) -> void\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::RETURN_INTENT])
    end

    it "counts `return_intent` as earned, so it is neither residue nor a marker case" do
      row = audit_fixture(ruby: "class Widget\n  def register(x)\n    @x = [x]\n  end\nend\n",
                          rbs: "class Widget\n  def register: (untyped x) -> void\nend\n")
            .find { |r| r.declaration.method_name == "register" }

      expect(SigProvenanceAuditor::EARNED).to include(row.classification)
      expect(row).not_to be_residue
    end

    it "calls a declaration sig-gen would narrow `tighter_return`" do
      rows = audit_fixture(ruby: "class Widget\n  def n\n    4.2\n  end\nend\n",
                           rbs: "class Widget\n  def n: () -> Numeric\nend\n")
      row = rows.find { |r| r.declaration.method_name == "n" }
      expect(row.classification).to eq(SigProvenanceAuditor::TIGHTER_RETURN)
      expect(row).not_to be_marked
    end

    it "reads the gap marker off the member's RBS comment" do
      rbs = "class Widget\n  # sig-gen gap: #1155 — the wider declaration is deliberate.\n  " \
            "def n: () -> Numeric\nend\n"
      row = audit_fixture(ruby: "class Widget\n  def n\n    4.2\n  end\nend\n", rbs: rbs)
            .find { |r| r.declaration.method_name == "n" }
      expect(row).to be_marked
      expect(row.declaration.marker).to eq("1155")
    end

    it "reads the authored marker off the member's RBS comment and counts the row as marked" do
      # An intentionally hand-written row (no engine work would ever answer it) carries `# authored:`
      # instead of a gap pointer; either marker records the row against the residue ratchet.
      rbs = "class Widget\n  # authored: hook-contract widening — no engine work would answer it.\n  " \
            "def n: () -> Numeric\nend\n"
      row = audit_fixture(ruby: "class Widget\n  def n\n    4.2\n  end\nend\n", rbs: rbs)
            .find { |r| r.declaration.method_name == "n" }
      expect(row).to be_marked
      expect(row.declaration.marker).to be_nil
      expect(row.declaration.authored_reason).to include("hook-contract widening")
    end

    it "rejects #TBD — a placeholder points at no engine work, and every gap now has an issue" do
      rbs = "class Widget\n  # sig-gen gap: #TBD — the wider declaration is deliberate.\n  " \
            "def n: () -> Numeric\nend\n"
      row = audit_fixture(ruby: "class Widget\n  def n\n    4.2\n  end\nend\n", rbs: rbs)
            .find { |r| r.declaration.method_name == "n" }
      expect(row).not_to be_marked
      expect(row.classification).to eq(SigProvenanceAuditor::TIGHTER_RETURN)
    end

    it "does not read a marker out of an unrelated comment" do
      rbs = "class Widget\n  # A plain doc comment mentioning sig-gen and #825.\n  " \
            "def n: () -> Numeric\nend\n"
      row = audit_fixture(ruby: "class Widget\n  def n\n    4.2\n  end\nend\n", rbs: rbs)
            .find { |r| r.declaration.method_name == "n" }
      expect(row).not_to be_marked
      expect(row.classification).to eq(SigProvenanceAuditor::TIGHTER_RETURN)
    end

    it "calls a declaration sig-gen will not swap `declared_divergent`" do
      rows = classifications_for(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                                 rbs: "class Widget\n  def n: () -> String\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::DECLARED_DIVERGENT])
    end

    it "calls a declaration whose body sig-gen cannot type `unrenderable`" do
      rows = classifications_for(ruby: "class Widget\n  def n(x)\n    x\n  end\nend\n",
                                 rbs: "class Widget\n  def n: (untyped x) -> Integer\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::UNRENDERABLE])
    end

    it "calls a declaration with no matching def `no_source`" do
      rows = classifications_for(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                                 rbs: "class Widget\n  def gone: () -> Integer\nend\n",
                                 method: "gone")
      expect(rows).to eq([SigProvenanceAuditor::NO_SOURCE])
    end

    it "calls a `define_method` declaration `synthetic_source` — sig-gen enumerates defs (#839)" do
      rows = classifications_for(ruby: "class Widget\n  define_method(:n) { 42 }\nend\n",
                                 rbs: "class Widget\n  def n: () -> Integer\nend\n", method: "n")
      expect(rows).to eq([SigProvenanceAuditor::SYNTHETIC])
    end

    it "calls a `Data.define` member declaration `synthetic_source` (#839)" do
      rows = classifications_for(ruby: "Point = Data.define(:x, :y)\n",
                                 rbs: "class Point\n  def x: () -> Integer\nend\n", method: "x")
      expect(rows).to eq([SigProvenanceAuditor::SYNTHETIC])
    end

    it "calls a declaration whose def lives on a project superclass `inherited_source` (#839)" do
      rows = classifications_for(ruby: "class Base\n  def n\n    42\n  end\nend\n\nclass Widget < Base\nend\n",
                                 rbs: "class Widget\n  def n: () -> Integer\nend\n", method: "n")
      expect(rows).to eq([SigProvenanceAuditor::INHERITED])
    end

    it "counts the #839 states as residue — existence says nothing about where the type came from" do
      row = audit_fixture(ruby: "class Widget\n  define_method(:n) { 42 }\nend\n",
                          rbs: "class Widget\n  def n: () -> Integer\nend\n")
            .find { |r| r.declaration.method_name == "n" }

      expect(SigProvenanceAuditor::EARNED).not_to include(row.classification)
      expect(row).to be_residue
    end

    it "leaves constants and type aliases out of scope as `non_method`" do
      rows = audit_fixture(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                           rbs: "class Widget\n  SIZE: Integer\n  type key = Symbol\n  def n: () -> 42\nend\n")
      expect(rows.map(&:classification)).to include(SigProvenanceAuditor::NON_METHOD)
      expect(rows.select { |r| r.classification == SigProvenanceAuditor::NON_METHOD }.size).to be >= 2
    end

    it "matches an RBS `self?.` module function against sig-gen's instance-side candidate" do
      rows = classifications_for(ruby: "module Widget\n  module_function\n\n  def n\n    42\n  end\nend\n",
                                 rbs: "module Widget\n  def self?.n: () -> 42\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::GENERATED])
    end
  end

  describe "the classifier's two states the corpus does not currently reach" do
    def row_for(candidate, method: "n", return_rbs: "Integer")
      declaration = SigProvenanceAuditor::Declaration.new(
        path: "sig/widget.rbs", line: 2, class_name: "Widget", method_name: method,
        kind: :instance, typed_params: false, return_rbs: return_rbs, marker: nil
      )
      SigProvenanceAuditor.classify([declaration], [candidate]).first
    end

    def candidate(classification, **overrides)
      Rigor::SigGen::MethodCandidate.new(
        path: "lib/widget.rb", class_name: "Widget", method_name: :n, kind: :instance,
        classification: classification, **overrides
      )
    end

    it "calls an equivalent whose declared return sig-gen could not translate `untranslatable_declared`" do
      row = row_for(candidate(Rigor::SigGen::Classification::EQUIVALENT,
                              inferred_return: Rigor::Type::Combinator.nominal_of("Integer"),
                              declared_return_rbs: nil))
      expect(row.classification).to eq(SigProvenanceAuditor::UNTRANSLATABLE)
    end

    it "calls a non-constructor new-method `unmatched_declaration`" do
      row = row_for(candidate(Rigor::SigGen::Classification::NEW_METHOD,
                              inferred_return: Rigor::Type::Combinator.nominal_of("Integer")))
      expect(row.classification).to eq(SigProvenanceAuditor::UNMATCHED)
    end
  end

  describe "the corpus" do
    it "reads a non-empty sig tree (guards the glob against a tree reshuffle)" do
      paths = SigProvenanceAuditor.declarations(root: SIG_PROVENANCE_ROOT).map(&:path).uniq
      expect(paths.size).to be >= 30
      expect(paths).to include("sig/rigor.rbs")
    end

    it "carries a recorded-gap marker on every tighter-return (ADR-14's contradiction rule)" do
      unmarked = SIG_PROVENANCE_ROWS.select do |row|
        row.classification == SigProvenanceAuditor::TIGHTER_RETURN && !row.marked?
      end
      expect(unmarked).to be_empty, lambda {
        "#{provenance_failure('unmarked tighter-return', unmarked)}\n\n" \
          "sig-gen proposes a narrower return than each declaration says. Per ADR-14 either apply " \
          "the tightening, or record why it stays with a marker in the member's RBS comment:\n  " \
          "# sig-gen gap: #NNN — why sig-gen's proposal is not the contract\n  " \
          "# authored: hand-written by contract — no engine work would answer it\n" \
          "#NNN must be an allow-listed gap issue (spec/rigor/sig_gen/gap_issues.yml): it is the " \
          "pointer to the engine work that would let the generator answer, so a placeholder or a " \
          "closed feature issue does not count as a marker."
      }
    end

    it "cites a listed gap issue from every corpus marker (the allow-list is the reviewed artefact)" do
      stray = SIG_PROVENANCE_ROWS.filter_map do |row|
        next if row.declaration.marker.nil?

        issue = row.declaration.marker.to_i
        "#{row.declaration} cites ##{issue}" unless GAP_ISSUE_ALLOW_LIST.include?(issue)
      end
      expect(stray).to be_empty, lambda {
        "#{stray.size} marker(s) cite an issue the allow-list does not carry:\n  #{stray.join("\n  ")}\n\n" \
          "A `# sig-gen gap: #NNN` marker points at the issue that tracks the ENGINE GAP, never " \
          "at the feature issue that added the row (ruling 2026-09-19 on #1011). " \
          "`spec/rigor/sig_gen/gap_issues.yml` is the reviewed allow-list: add a number only when " \
          "a marker must cite it, and remove a number when that gap issue closes, which forces " \
          "the markers to move."
      }
    end

    it "keeps each file's hand-authored residue at its pinned count" do
      actual = SigProvenanceAuditor.residue_counts(SIG_PROVENANCE_ROWS)
      drift = (actual.keys | SIG_PROVENANCE_RESIDUE.keys).filter_map do |path|
        pinned = SIG_PROVENANCE_RESIDUE.fetch(path, 0)
        found = actual.fetch(path, 0)
        "  #{path}: #{found} (pinned #{pinned})" unless found == pinned
      end
      expect(drift).to be_empty, lambda {
        "#{drift.size} file(s) drifted from SIG_PROVENANCE_RESIDUE:\n#{drift.join("\n")}\n\n" \
          "A declaration that is neither generated-equivalent nor parameter intent is a gap " \
          "sig-gen could not close (ADR-107 § Decision). Mark it — a `# sig-gen gap:` marker " \
          "(or an `# authored:` marker for a deliberately hand-written row) subtracts from the " \
          "count — or move the pin in this file with the reason in the commit body. A count that " \
          "DROPPED is an engine fix: lower the pin in the same commit."
      }
    end

    it "reports the residue as a total, so the number is visible without a failure" do
      expect(SIG_PROVENANCE_ROWS.count(&:residue?)).to eq(SIG_PROVENANCE_RESIDUE.values.sum)
    end

    it "resolves every declaration to a def, a recognised shape, or a runtime-defined method (#839)" do
      stale = SIG_PROVENANCE_ROWS.select { |row| row.classification == SigProvenanceAuditor::NO_SOURCE }
      expect(stale).to be_empty, lambda {
        listing = stale.map { |row| "#{row.declaration} — no source" }
        "#{provenance_failure('stale declaration', listing)}\n\n" \
          "Each names a method nothing defines: not a `def` sig-gen can attribute, not a shape " \
          "Rigor's own cross-file recognition knows (`attr_*`, `define_method`, `alias`, a " \
          "`Data` / `Struct` member, an ancestor the project declares), and not a method the " \
          "loaded tree carries. A declaration is worse than a missing one — RBS resolves calls " \
          "through it — so delete it, or restore the code it describes.\n" \
          "Nothing else in the tree asks this direction: `make check` and `make steep-check` both " \
          "ask whether the implementation matches `sig/`."
      }
    end

    it "confirms the documented runtime-generated declaration rather than exempting it (#839)" do
      # `sig/prism_node_children.rbs` declares `#rigor_each_child` on the abstract `Prism::Node` so
      # every subclass resolves against one declaration; `Source::NodeChildren` compiles it onto each
      # CONCRETE node class at load. Reflection is what tells that apart from a stale declaration.
      row = SIG_PROVENANCE_ROWS.find { |r| r.declaration.method_name == "rigor_each_child" }
      expect(row.declaration.path).to eq("sig/prism_node_children.rbs")
      expect(row.classification).to eq(SigProvenanceAuditor::RUNTIME_DEFINED)
      expect(row.detail).to include("subclass")
    end
  end
end
