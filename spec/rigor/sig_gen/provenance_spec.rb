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
# 587 -> 584 since #2317. The classifier now compares an inferred return with the spelling sig-gen writes
# (`TypeElaborator` applied before `erase_to_rbs`), not the raw carrier. A written `Set` is `Set[untyped]`
# in sig-gen (#2177), so a `Set[String]` declaration no longer matches the inferred return and reads
# `declared_divergent`; each such row that is hand-written carries `# authored:` with its element type, so it
# stays out of the count (scope.rbs and inference.rbs back to their pre-PR pins). A bare `Array` now elaborates
# to the `Array[untyped]` a declaration already names and reads `generated`, so the three files whose rows now
# generate drop to zero (-1 each). Net -3 against the pre-PR total. The
# per-row reasons are at their pins. This is a gate checking more, not an engine change: no declaration text moved.
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
# 711 since #1449. `DiscoveryIndex` gains the `implicit_self_evidence` member, whose `Data` row is residue as
# every member row of that class is (`scope.rbs` +1; the reason is at its pin).
# 707 since #1429. A value-position `case` types each arm under the subject's `when` narrowing, so four rows
# whose body is a `case … when <Class>` render their return (`inference.rbs` -1, `type.rbs` -3; the reasons are
# at the pins). The new `Scope` guard rows are sig-gen output or carry the #1154 marker, so they add none.
# 566 since #2321. The class-ivar census types an ivar assigned an expression over declared parameters, so 18
# unmarked rows render the declared type (`environment.rbs` -1, `type.rbs` -17; the reasons are at the pins).
# 554 since #2719. `enclosing_def`'s body now proves `Prism::DefNode?`, which sig-gen declines to propose
# (`node_context.rbs` +1; the reason is at its pin, #2914).
# 553 since #2914. sig-gen proposes a subclass narrowing of a nil-able union, so `enclosing_def` declares its
# `Prism::DefNode | nil` and the row is generated (`node_context.rbs` -1; the pin is gone).
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
  # -16 (#1154): an ivar a declared parameter assigns now reads that type, so 16 rows over it render.
  "sig/rigor.rbs" => 31,
  # -4 (#1181 slice): Bucket/DriftRow member rows are marked under #1183 and `buckets` under #1154;
  # `audit`/`without`/`initialize` tightened to generated/intent, leaving `filter`'s honest
  # `[Array[untyped], Integer]` divergence as the sole unmarked row.
  "sig/rigor/analysis/baseline.rbs" => 1,
  # -1 each (#2317): `collect` returns a bare `Array`, which the elaborator now spells `Array[untyped]`, the
  # declared spelling; both rows classify as generated (these are the only three files whose rows now generate).
  "sig/rigor/analysis/check_rules/always_truthy_condition_collector.rbs" => 0,
  "sig/rigor/analysis/check_rules/dead_assignment_collector.rbs" => 0,
  "sig/rigor/analysis/dependency_source_inference/gem_resolver.rbs" => 1,
  # -2 (#1092): an RBS `-> self` return keeps the receiver's type arguments, so `FactStore#normalize`
  # and `CheckRules.filter_suppressed` stop inferring the raw `Array`; both now classify as parameter
  # intent (their declared `Array[Fact]` / `Array[Diagnostic]` follows from the declared parameters).
  "sig/rigor/analysis/fact_store.rbs" => 14,
  # New file (#1181 slice): the three members whose element classes are not sig-covered yet
  # (`synthetic_method_index`, `project_patched_methods`, `template_units`) stay `untyped` — they are
  # Data members sig-gen cannot infer, but the declared type is `untyped` anyway, so no gap marker
  # applies; they pin as unmarked residue. The typed members and both constructors are #1150-marked.
  "sig/rigor/analysis/project_scan.rbs" => 3,
  # -1 (#1154): an ivar a declared parameter assigns now reads that type, so 1 row over it renders.
  "sig/rigor/ast.rbs" => 0,
  "sig/rigor/cache.rbs" => 2,
  "sig/rigor/cli/diff_command.rbs" => 1,
  "sig/rigor/cli/explain_command.rbs" => 1,
  "sig/rigor/cli/sig_gen_command.rbs" => 2,
  # -1 (#2317): `record_parse_error`'s bare `Array` is spelled `Array[untyped]` by the elaborator, as declared.
  "sig/rigor/cli/type_scan_command.rbs" => 0,
  # New files (#1181 slice): the bound side of `Effects::*`. Marked rows are #1150 Data members;
  # unmarked residue is the ordinary unrenderable/declared-divergent mix (`label_set.rbs` also pins
  # the `eql?` alias row, `origin.rbs`/`taint_cause.rbs` fully classify).
  # -1 (#2411): `for_classes`' tail `each_with_object({})` now reads its stores, `Hash[String, Envelope]`, as declared.
  "sig/rigor/effects/config_envelopes.rbs" => 2,
  # New file (#1181 collection-side slice): `Entry`'s members and constructors are #1150-marked;
  # the five unmarked rows are `[]`/`keys`/`each`/`size`/`empty?` — unrenderable
  # (`sig.skipped.untyped-return`, all single-expression readers sig-gen declines).
  "sig/rigor/effects/effect_table.rbs" => 5,
  # -1 (#1181 collection-side slice): `Envelope#tolerates?` reads `Summary::TRIVIAL_BOUND`, and
  # `Summary` being declared lets sig-gen resolve the reference it could not name before.
  # -1 (#1153): an empty-collection early return no longer leaves a stray `[]` arm beside an `Array[E]` arm,
  # so the declared `Array[...]` now matches what sig-gen proposes.
  "sig/rigor/effects/envelope.rbs" => 0,
  "sig/rigor/effects/envelope_index.rbs" => 2,
  # New file (#1181 collection-side slice): `Edge` members/constructors are #1150-marked and the
  # five attr_readers #1154-marked; the sole unmarked row is `empty?` (unrenderable).
  "sig/rigor/effects/file_collection.rbs" => 1,
  "sig/rigor/effects/label.rbs" => 4,
  # -1 (#1154): an ivar a declared parameter assigns now reads that type, so 1 row over it renders.
  "sig/rigor/effects/label_set.rbs" => 7,
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
  "sig/rigor/effects/plugin_facts.rbs" => 10,
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
  # -3 (#1153): an empty-collection early return no longer leaves a stray `[]` arm beside an `Array[E]` arm,
  # so the declared `Array[...]` now matches what sig-gen proposes.
  # -3 (#1154): an ivar a declared parameter assigns now reads that type, so 3 more rows over it render.
  # -1 (#2321): an ivar assigned an expression over a declared parameter now reads that expression's type, so
  # `RbsLoader#libraries` renders.
  "sig/rigor/environment.rbs" => 32,
  # -1 (#1429): a value-position `case` now types each arm under the subject's `when` narrowing, so
  # `ExpressionTyper#type_of_virtual`'s `when AST::TypeNode then node.type` arm reads `node` as the node class
  # and its return renders.
  # 0 net (#2317): `ScopeIndexer#finalize_constant_writes` returns `Hash[String, Set[String]]` as its second element,
  # which the elaborator spells `Set[untyped]`, so the row moved from `parameter_intent` to `declared_divergent`.
  # It is marked `# authored:` with its element type by contract, so the count is back at 83. The declared
  # parameter is unchanged.
  # -7 (#3285, ADR-116 pure move). `Narrowing`'s five declarations of methods that moved (`subclass_of?` and
  # `class_ordering` to `Narrowing::ClassDispatch`; `trusted_equality_literal?`, `falsey_value?` and `falsey_nominal?`
  # to `Narrowing::Complements`) are re-declared under their new owners with the same signatures, so the two
  # `unrenderable` rows (`class_ordering`, `falsey_value?`) stay residue. Seven rows leave `unrenderable` for
  # `parameter_intent` (return equivalent, parameters narrower): `narrow_class`, `narrow_not_class`, `narrow_equal`,
  # `narrow_not_equal`, `narrow_falsey`, `narrow_nil` and `narrow_not_refinement`, since the helpers their bodies call
  # are now typed module functions rather than private singleton methods sig-gen declines.
  # -8 (#3345, ADR-116 WD12 S0). `MethodDispatcher::CallContext` is a plain class, no longer a `Data`. Its `with` has a
  # source `def` whose return sig-gen generates (`runtime_defined`, inherited from `Data`, before), and its newly
  # declared `initialize` types the nine parameters, so the seven readers with a declared type render it from the
  # ivar `initialize` assigns (`synthetic_source`, a `Data` member, before). `call_node` and `scope` are declared
  # `untyped` and stay residue, as `unrenderable`.
  # 0 net (#3345, ADR-116 WD12 S1). `MethodDispatcher.resolve_site` is declared `-> Type::t?` and is `unrenderable`:
  # it holds the tier ladder `resolve` held, and sig-gen renders no return for a body that answers what
  # `RbsDispatch.try_dispatch` answers (`sig.skipped.untyped-return`). `MethodDispatcher.dispatch` leaves
  # `unrenderable` for `parameter_intent`: its body is now a call of the declared `dispatch_site`, whose own body
  # returns `resolve_site`'s declared answer, so sig-gen renders both. The unrenderable row moved to the method the
  # ladder moved to.
  # 0 net (#3345, ADR-116 WD12 S6). `ExpressionTyper#infer_user_method_return` is public for the call ladder's port
  # and is declared `-> Type::t?`, so that what a rung module gets back from it is typed. It is `unrenderable`:
  # sig-gen renders no return for the memo, guard and fixpoint body (`sig.skipped.untyped-return`).
  # `ExpressionTyper#return_type_for` leaves `unrenderable` for `parameter_intent`: its body is one call of the
  # declared method, so sig-gen renders it. The unrenderable row moved from the public face to the method behind it.
  "sig/rigor/inference.rbs" => 68,
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
  # -1 (#1529 auditor fix): the join is now kind-aware. `Base#manifest` (instance, the no-arg reader) used to
  # join the singleton `def manifest(**fields)` candidate first-wins and read as unrenderable; it now joins its
  # own instance candidate, which is generated-equivalent.
  # -3 (#1153): an empty-collection early return no longer leaves a stray `[]` arm beside an `Array[E]` arm,
  # so the declared `Array[...]` now matches what sig-gen proposes.
  "sig/rigor/plugin/base.rbs" => 16,
  "sig/rigor/plugin/blueprint.rbs" => 2,
  "sig/rigor/plugin/fact_store.rbs" => 2,
  # -2 (#720): `file?` / `directory?` are `probe(path) { … }`, and the block's `bool` now reaches the
  # caller, so sig-gen generates what the two hand-written declarations say.
  "sig/rigor/plugin/io_boundary.rbs" => 1,
  "sig/rigor/plugin/load_error.rbs" => 3,
  # -1 (#1154): an ivar a declared parameter assigns now reads that type, so 1 row over it renders.
  "sig/rigor/plugin/loader.rbs" => 1,
  # -2 (#1181 slices): `additional_initializers` and `protocol_contracts` tightened to
  # `Array[Plugin::AdditionalInitializer]` / `Array[Plugin::ProtocolContract]` and marked #1154.
  # +1 (#1181 vocabulary slice): the six `effect_*` readers are #1154-marked and `effects?` /
  # `effect_owner` earned (the reader bound once into a local narrows, so sig-gen proves
  # `String`); `effect_discharge_allowed?` is unrenderable.
  "sig/rigor/plugin/manifest.rbs" => 21,
  # New file (#1181 slice): `to_h` is declared-divergent (sig-gen infers a string-literal-keyed
  # union; `Hash[String, untyped]` matches the manifest `to_h` convention) and `eql?` is an alias
  # row with no sig-gen shape.
  "sig/rigor/plugin/protocol_contract.rbs" => 2,
  # +4 (#1181 slices): `additional_initializers`, `protocol_contracts` and
  # `effect_contributions` readers are unmarked residue — `compile_aggregates` /
  # `compile_effect_contributions` build the ivars with `flat_map`/`filter_map` (memoised for the
  # latter), not from `initialize` parameters, so no gap issue covers them;
  # `contracts_for_path` left residue under #1153 (its `path.nil?` `[]` arm is now absorbed).
  # `Contribution`'s members and constructors are #1150-marked.
  # -1 (#1153): an empty-collection early return no longer leaves a stray `[]` arm beside an `Array[E]` arm,
  # so the declared `Array[...]` now matches what sig-gen proposes.
  "sig/rigor/plugin/registry.rbs" => 12,
  # -1 (#1181 slice): `read_effect_envelope` now returns `Effects::Envelope?`, which sig-gen proves
  # through the `build_*_envelope` helpers — no longer residue. -1 (#1390): `read_return_type_override`'s
  # block `return` now reaches its inferred return, which matches the declared `Type::t?`.
  "sig/rigor/rbs_extended.rbs" => 21,
  # -1 (#1153): an empty-collection early return no longer leaves a stray `[]` arm beside an `Array[E]` arm,
  # so the declared `Array[...]` now matches what sig-gen proposes.
  "sig/rigor/reflection.rbs" => 7,
  # +1 (#1412): `singleton_def_through_ancestors` walks `until queue.empty?; current = queue.shift; …;
  # enqueue_ancestors(current, queue, …)`. The loop body now enters with `queue` at its unknown-store
  # widening, and a callee store floors it to `Array[untyped]`, as straight-line code after the same call
  # already reads it, so `current` and the `[found, current]` return are `untyped`. At runtime the queue only
  # ever holds Strings (`enqueue_ancestors` pushes resolved class names), so the `String` sig-gen proved from
  # the seed `[class_name.to_s]` was right: this is a precision loss the callee floor causes, not a
  # correction. `user_def_through_ancestors` (already residue) loses its `[Prism::DefNode, String]` arm the
  # same way.
  # +1 (#1449): the new `DiscoveryIndex#implicit_self_evidence` `Data` member is `synthetic_source`
  # residue, like every member row of that class (#1150). It is declared `untyped` because its value, an
  # `Inference::LastLine::SelfEvidence`, carries no signature.
  # ±0 (#1567): `user_def_through_ancestors`, `singleton_def_through_ancestors` and
  # `external_ancestor_name_candidates` no longer walk a queue; each answers through
  # `Scope::ResolutionChain#search`, whose value is whatever its block returns, which sig-gen does not render.
  # The three rows move from `declared_divergent` to `unrenderable` and stay residue; the declarations are
  # unchanged and still true.
  # -35 (#1154): an ivar a declared parameter assigns now reads that type, so 35 rows over it render. A further
  # -8 (`local`, `ivar`, `cvar`, `global`, `user_def_site_for`, `user_singleton_def_site_for`, `superclass_of`,
  # `includes_of`) come from master's sig-gen fixes, not from this change: they already rendered as
  # `declared_divergent` (dropping `| nil` or adding `| []`) and match the declaration since #2249 (the lookup
  # keeps its nil) and #2298 (the empty early return is absorbed).
  # -4 (#1148, #1149): `class_cvars_for` and `class_ivars_for` end `Hash[...] | {}`, and the empty `{}` arm is now
  # absorbed beside the `Hash` arm (the Hash analogue of #2298), so both render and match. `opaque_block_self` and
  # `opaque_block_self?` read an ivar `initialize` assigns from a parameter; the `initialize` declaration now names
  # that keyword (and `block_self_unknown:` / `singleton_class_body:`), so they render (#1154's mechanism).
  # -20 (#2313): `initialize` now declares every keyword the Ruby `initialize` takes, each typed as the reader over
  # the ivar it seeds, so those readers (`local_origins`, `ivar_origins`, `void_origins`, `plugin_typed_calls`,
  # `optimistic_*`, `indexed_narrowings`, `method_chain_narrowings`, `struct_fold_safe_locals`, `lexical_nesting`,
  # `declaration_sourced`, and the predicates over them) render and match, or classify as parameter intent. The
  # `# sig-gen gap: #1154` markers on the rows that became generated-equal or parameter intent are gone too. The
  # three Set readers (`published_constant_sourced`, `declaration_sourced`,
  # `struct_fold_safe_locals`) carry `# authored:`
  # notes instead: sig-gen proposes `Set[untyped]` for them (#2177, #2317), and a marker does not move this count.
  # -2 (#2306): a truthiness test no longer drops the optimistic mark on its falsey edge, so `data_member_layout`
  # and `struct_member_layout` regenerate with the `?` their declarations carry.
  # 0 net (#2317): the classifier elaborates an inferred return through `TypeElaborator`, so a Set return is
  # compared as `Set[untyped]`, the spelling sig-gen writes (#2177). Five Set readers that read `generated` before
  # now read `declared_divergent` and each carries an `# authored:` marker stating its element type by contract:
  # `discovered_global_write_census`, `published_constant_names`, `local_constant_names`,
  # `discovered_class_sources`, `constant_sources`. Marked rows are not residue, so the count is back at 43.
  # The three earlier Set readers (`published_constant_sourced`, `declaration_sourced`, `struct_fold_safe_locals`)
  # move class the same way and were already marked.
  "sig/rigor/scope.rbs" => 41,
  "sig/rigor/sig_gen/skip_reason_catalog.rbs" => 8,
  "sig/rigor/source.rbs" => 4,
  "sig/rigor/testing.rbs" => 4,
  # -1 (#1154): an ivar a declared parameter assigns now reads that type, so 1 row over it renders.
  "sig/rigor/trinary.rbs" => 4,
  # -3 (#1429): a value-position `case` now types each arm under the subject's `when` narrowing, so the
  # `when Constant then type.value.is_a?(String)` arms of `Combinator#literal_string_compatible?`,
  # `#non_empty_string_compatible?` and `#non_zero_int_compatible?` read `type` as the carrier the `when` names
  # rather than `untyped`, and each `bool` return renders.
  # -14 (#1154): an ivar a declared parameter assigns now reads that type, so 14 more rows over it render.
  # -17 (#2321): an ivar assigned an expression over a declared parameter (`members.freeze`,
  # `elements.dup.freeze`, `min.zero? ? 0.0 : min`) now reads that expression's type, so 17 more rows over it render.
  # `Nominal#type_args` does not: its parameter defaults to a constant the census cannot place in the declared type.
  "sig/rigor/type.rbs" => 175
}.freeze

# The `parameter_only` class (#3323), per file, marked and unmarked rows apart. Exact in BOTH directions, like the
# residue pins above: the count is expected to GROW as parameters are declared on methods whose return sig-gen cannot
# yet render, and to SHRINK as those returns become renderable (the row then leaves for `generated`,
# `tighter_return` or `declared_divergent`). Edit a pin in the same PR that moves it, with the reason in the commit
# body, so a PR that adds 500 such rows shows 500 in its diff. A row that is `parameter_only` is not residue, so the
# class is bounded only by this table.
SIG_PROVENANCE_PARAMETER_ONLY = {
  # +8 (#3315): the `try_dispatch` of eight dispatch tiers declares its `CallContext` parameter; sig-gen still renders
  # no return for `BlockFolding`, `ConstantFolding`, `DataFolding`, `ProcessFolding`, `RbsDispatch`, `ShapeDispatch`,
  # `StructFolding` or `UniversalObjectDispatch` (`sig.skipped.untyped-return`).
  # +3 (#3345, ADR-116 WD12 D1): three of the four tiers moved out of `method_dispatcher.rb` declare their
  # `try_dispatch` the same way, and sig-gen renders no return for `HktBuiltinReturn`, `MetaIntrospection` or
  # `StaticRefinement` (`sig.skipped.untyped-return`). The fourth, `SynthesizedStub`, declares the return sig-gen
  # generates and is earned.
  # +2 (#3345, ADR-116 WD12 D2): two of the four tiers the second batch moved declare their `try_dispatch` the same
  # way, and sig-gen renders no return for `PluginContribution` or `SyntheticMethodDispatch`
  # (`sig.skipped.untyped-return`). The other two, `DependencySource` and `ProjectPatched`, declare the
  # `Type::Dynamic | nil` sig-gen generates and are earned.
  # +1 (#3345, ADR-116 WD12 D3): of the last three tiers moved, sig-gen renders no return for `UserClassFallback`
  # (`sig.skipped.untyped-return`: it answers what `RbsDispatch.try_dispatch` answers, itself a row here). The other
  # two declare the return sig-gen generates and are earned: `DiscoveredMethod` `Type::Dynamic | nil`, and
  # `CompositeReceiver` every member of `Type::t` or nil, declared `Type::t?`.
  # +2 (#3345, ADR-116 WD12 S6): `CallLadder::UserMethod`, the first rung module, has twelve functions, and eleven
  # are declared (`note_missing_class` is not). Of those, sig-gen renders no return for
  # `resolve_typing_def_with_owner` (it answers what `MemoAudit.check` yields) or `definer_without_single_body?` (it
  # answers `DiscoveryIndex` predicates, undeclared), both `sig.skipped.untyped-return`. Each declares its parameters
  # so that the `typer` and the `scope` it is given read as `ExpressionTyper` and `Scope` inside it, which the
  # self-typing ratchet counts: 36 precise expressions and 8 call sites of `user_method.rb`, measured. The other
  # nine declared functions declare the return sig-gen generates and are earned.
  # +12 (#3345, ADR-116 WD12 S5): `CallLadder::ProjectSingleton`, the second rung module, has twenty-three functions,
  # and nineteen are declared. Seven declare the return sig-gen generates and are earned (`try_call`, its two tiers,
  # `compute_singleton_def_with_owner`, `foreign_definer_behind_copy?`, `hidden_hook_definer?` and
  # `dynamic_singleton_definer_ahead?`). For the other twelve sig-gen renders no return (`sig.skipped.untyped-return`:
  # each answers what an undeclared `Scope::ResolutionChain`, `DiscoveryIndex` predicate or `MemoAudit.check` gives,
  # or what another such function answers), and
  # each declares its parameters so that the `scope` or `typer` it is given reads as `Scope` or `ExpressionTyper`
  # inside it, which the self-typing ratchet counts: 98 precise expressions and 19 call sites of
  # `project_singleton.rb`, measured with and without. The four functions whose parameters are all `untyped`
  # (`unordered_prepend_definer?`, `answered_ahead?`, `level_start_of`, `own_singleton_index`) gain nothing from a
  # declaration, measured, and are left undeclared.
  # +2 (#3345, ADR-116 WD12 S8): `CallLadder::TopLevelDef` and `CallLadder::OverridingDef` declare all twelve of their
  # functions. Ten declare the return sig-gen generates and are earned. For `self_type_answers?` and
  # `singleton_self_answers?` sig-gen renders no return (`sig.skipped.untyped-return`: the second answers an
  # undeclared `Scope::ResolutionChain#unnamed_mixin?`, and the first what the second answers), and each declares its
  # parameters so that the `typer` or `scope` it is given reads as `ExpressionTyper` or `Scope` inside it, which the
  # self-typing ratchet counts: 27 precise expressions and 8 call sites of `top_level_def.rb`, measured with and
  # without.
  # +1 (#3345, ADR-116 WD12 S4): `CallLadder::Refined` has twelve functions, and eleven are declared. Ten declare the
  # return sig-gen generates and are earned. For `opaque_refinement_span?` sig-gen renders no return
  # (`sig.skipped.untyped-return`: it answers the undeclared `InEffectRefinements.opaque_in?`), and it declares its
  # parameters so that the `scope` it is given reads as `Scope` inside it, which the self-typing ratchet counts: 10
  # precise expressions and 3 call sites of `refined.rb`, measured with and without. `refined_receiver_class_name`,
  # which takes no scope or typer and for which sig-gen renders no return either, is left undeclared: its
  # declaration moved 1 precise expression and no call site, measured.
  "sig/rigor/inference.rbs" => { unmarked: 31, marked: 0 },
  # Both rows were marked `unrenderable` rows before the class existed.
  "sig/rigor/scope.rbs" => { unmarked: 0, marked: 2 }
}.freeze

# The only `parameter_only` rows allowed to carry a marker: marked `unrenderable` rows that predate the class. A
# marker on a `parameter_only` row silences the later `tighter_return` (a marked row is never flagged), so a marker
# would turn the watched class into a permanent exemption. The set can only shrink.
SIG_PROVENANCE_PARAMETER_ONLY_MARKED = [
  "sig/rigor/scope.rbs Rigor::Scope::DiscoveryIndex#empty_value",
  "sig/rigor/scope.rbs Rigor::Scope#def_node_slot"
].freeze

# #3335 — method declarations whose parameter list was compared with a recorded `def` on the tree this pin was taken
# from (1109 on 2026-11-20 after #3345's eleven `try_dispatch` declarations for the tiers moved out of
# `method_dispatcher.rb` in three batches, its `dispatch_site` and `resolve_site`, the fourteen of slice S6 (the eleven
# declared functions of `CallLadder::UserMethod` and three typer methods of the call ladder's port), the nineteen
# declared functions of `CallLadder::ProjectSingleton` of slice S5 and the two of `CallLadder::LiteralSend` of slice S7,
# every one fitting; 1121 after the twelve declared functions of `CallLadder::TopLevelDef` and `CallLadder::OverridingDef`
# of slice S8; 1132 after the eleven declared functions of `CallLadder::Refined` of slice S4). A floor, not an exact
# pin, because every new declaration of a `def` raises it: raise it when the count grows, and lower it only with the
# reason in the commit body (a deleted declaration, or a `def` the pairing stopped finding, which is the case this
# floor exists to catch).
SIG_PARAMETER_SHAPE_COMPARED_FLOOR = 1132

module SigProvenanceSpecHelpers
  # The hard-rule failure for unmarked `tighter_return` rows. A row whose declared return is the bare `untyped` claims
  # nothing, so a marker on it would keep the `untyped` for good (the row just left `parameter_only`, or never typed
  # its return): it is told to adopt the proposal and is offered no marker (#3335).
  def tighter_return_message(rows)
    untyped, typed = rows.partition { |row| row.declaration.untyped_return }
    parts = []
    unless untyped.empty?
      parts << "#{provenance_failure('unmarked tighter-return over a declared `untyped`', untyped)}\n\n" \
               "The declared return is `untyped`, so it states nothing a marker could record: adopt sig-gen's " \
               "proposal (`rigor sig-gen --print` names it) as the declared return."
    end
    unless typed.empty?
      parts << "#{provenance_failure('unmarked tighter-return', typed)}\n\n" \
               "sig-gen proposes a narrower return than each declaration says. Per ADR-14 either apply " \
               "the tightening, or record why it stays with a marker in the member's RBS comment:\n  " \
               "# sig-gen gap: #NNN — why sig-gen's proposal is not the contract\n  " \
               "# authored: hand-written by contract — no engine work would answer it\n" \
               "#NNN must be an allow-listed gap issue (spec/rigor/sig_gen/gap_issues.yml): it is the " \
               "pointer to the engine work that would let the generator answer, so a placeholder or a " \
               "closed feature issue does not count as a marker."
    end
    parts.join("\n\n")
  end

  def parameter_shape_message(result)
    "#{result.mismatches.size} declaration overload(s) admit a call their `def` rejects (#{result.summary}):\n  " \
      "#{result.mismatches.join("\n  ")}\n\n" \
      "Each overload's parameter list must be one the `def` accepts (docs/agents/type-authoring.md § \"The " \
      "provenance gate's row classes\"). Regenerate the shape with `rigor sig-gen --print` and keep the declared " \
      "parameter types; the parameter TYPES are yours, the list is the def's."
  end

  def provenance_failure(label, rows)
    lines = rows.map(&:to_s)
    shown = lines.first(SIG_PROVENANCE_LISTING_CAP)
    suffix = lines.size > shown.size ? "\n  … #{lines.size - shown.size} more" : ""
    "#{label}: #{lines.size} declaration(s)\n  #{shown.join("\n  ")}#{suffix}"
  end

  # Runs the whole classifier over a two-file fixture project, so a unit example exercises the same
  # join the corpus examples do rather than a parallel reimplementation of it.
  # `keys` is every marked `parameter_only` row; only those beyond the grandfathered set are named.
  def parameter_only_marker_message(keys)
    added = keys - SIG_PROVENANCE_PARAMETER_ONLY_MARKED
    "a marker on a `parameter_only` row silences the `tighter_return` the row earns once sig-gen renders its " \
      "return, so it would turn the watched class into a permanent exemption. Remove the marker: #{added.join(', ')}"
  end

  def parameter_only_grandfather_message(gone)
    "a grandfathered `parameter_only` row left the class or lost its marker: shrink " \
      "SIG_PROVENANCE_PARAMETER_ONLY_MARKED (#{gone.join(', ')})"
  end

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

    it "compares a Set return with the `Set[untyped]` sig-gen writes, not the element the engine read (#2177, #2317)" do
      # The reader returns an ivar seeded from the declared `Set[Symbol]` parameter: sig-gen's raw carrier is
      # `Set[Symbol]`, which equals the declaration, but the spelling it writes is `Set[untyped]`.
      ruby = "class Widget\n  def initialize(names)\n    @names = names\n  end\n  def n\n    @names\n  end\nend\n"
      rbs = "class Widget\n  def initialize: (Set[Symbol] names) -> void\n  def n: () -> Set[Symbol]\nend\n"
      row = audit_fixture(ruby: ruby, rbs: rbs).find { |r| r.declaration.method_name == "n" }
      expect(row.classification).to eq(SigProvenanceAuditor::DECLARED_DIVERGENT)
      expect(row.detail).to eq("declared Set[Symbol], sig-gen infers Set[untyped]")
    end

    # Control (guard): passes with the elaboration removed. It pins that a declaration already spelled as
    # sig-gen writes it stays `generated`, so the elaboration must not move it.
    it "calls a Set return declared as sig-gen writes it `generated`" do
      rows = classifications_for(ruby: "class Widget\n  def n\n    Set[1]\n  end\nend\n",
                                 rbs: "class Widget\n  def n: () -> Set[untyped]\nend\n")
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
      rbs = "class Widget\n  # sig-gen gap: #1149 — the wider declaration is deliberate.\n  " \
            "def n: () -> Numeric\nend\n"
      row = audit_fixture(ruby: "class Widget\n  def n\n    4.2\n  end\nend\n", rbs: rbs)
            .find { |r| r.declaration.method_name == "n" }
      expect(row).to be_marked
      expect(row.declaration.marker).to eq("1149")
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

    # #3323 — a declaration whose return is the bare `untyped`, on a method sig-gen skips as `untyped-return`, with
    # a typed parameter. `y` is returned untyped, so no declared type of `x` can make the return renderable.
    describe "`parameter_only` (#3323)" do
      let(:unrenderable_ruby) { "class Widget\n  def n(x, y, &blk)\n    x\n    y\n  end\nend\n" }

      def only_row(rbs, ruby: unrenderable_ruby)
        audit_fixture(ruby: ruby, rbs: rbs).find { |r| r.declaration.method_name == "n" }
      end

      def widget(signature) = "class Widget\n  def n: #{signature}\nend\n"

      it "classes a typed-parameter, bare-`untyped` return on an unrenderable method `parameter_only`, not residue" do
        row = only_row(widget("(Integer x, untyped y) -> untyped"))
        expect(row.classification).to eq(SigProvenanceAuditor::PARAMETER_ONLY)
        expect(row.detail).to eq("sig.skipped.untyped-return")
        expect(row).not_to be_residue
        expect(SigProvenanceAuditor::EARNED).not_to include(row.classification)
        expect(SigProvenanceAuditor.residue_counts([row])).to be_empty
      end

      it "still counts a TYPED return on the same unrenderable method as residue" do
        row = only_row(widget("(Integer x, untyped y) -> Integer"))
        expect(row.classification).to eq(SigProvenanceAuditor::UNRENDERABLE)
        expect(row).to be_residue
      end

      it "still counts an all-`untyped` declaration as residue: no parameter is stated" do
        row = only_row(widget("(untyped x, untyped y) -> untyped"))
        expect(row.classification).to eq(SigProvenanceAuditor::UNRENDERABLE)
        expect(row).to be_residue
      end

      it "gives no exemption to any return other than the bare `untyped`" do
        returns = ["void", "boolish", "bool", "top", "bot", "nil", "self", "instance", "class", "Integer",
                   "[untyped, untyped]", "Array[untyped]", "untyped?", "(untyped | Integer)", "_ToS"]
        classes = returns.to_h { |ret| [ret, only_row(widget("(Integer x, untyped y) -> #{ret}")).classification] }
        expect(classes.values.uniq).to eq([SigProvenanceAuditor::UNRENDERABLE])
      end

      it "needs every overload's return to be the bare `untyped`" do
        both = only_row(widget("(Integer x, untyped y) -> untyped | (String x, untyped y) -> untyped"))
        mixed = only_row(widget("(Integer x, untyped y) -> untyped | (String x, untyped y) -> Integer"))
        expect(both.classification).to eq(SigProvenanceAuditor::PARAMETER_ONLY)
        expect(mixed.classification).to eq(SigProvenanceAuditor::UNRENDERABLE)
      end

      it "counts a signature as typed only when it states some type: `(?)` and untyped blocks do not" do
        shapes = ["(?) -> untyped", "(untyped x, untyped y) { (untyped) -> untyped } -> untyped",
                  "(untyped x, untyped y) ?{ () -> untyped } -> untyped",
                  "(untyped x, untyped y) { (?) -> untyped } -> untyped"]
        classes = shapes.to_h { |sig| [sig, only_row(widget(sig)).classification] }
        expect(classes.values.uniq).to eq([SigProvenanceAuditor::UNRENDERABLE])
      end

      it "counts a type anywhere in the block as typing something, a block parameter or the block's own return" do
        shapes = ["(untyped x, untyped y) { (Integer) -> untyped } -> untyped",
                  "(untyped x, untyped y) { (untyped) -> String } -> untyped",
                  "(untyped x, untyped y) ?{ (untyped) -> String } -> untyped"]
        classes = shapes.to_h { |sig| [sig, only_row(widget(sig)).classification] }
        expect(classes.values.uniq).to eq([SigProvenanceAuditor::PARAMETER_ONLY])
      end

      it "does not read the block's return as the method's return: a typed method return stays residue" do
        row = only_row(widget("(untyped x, untyped y) { (untyped) -> untyped } -> Integer"))
        expect(row.classification).to eq(SigProvenanceAuditor::UNRENDERABLE)
      end

      it "treats `untyped?`, `top` and `top?` as stating nothing, in a parameter and in a block" do
        shapes = ["(untyped? x, untyped y) -> untyped", "(top x, untyped y) -> untyped",
                  "(top? x, untyped y) -> untyped", "(untyped x, untyped y) { (untyped?) -> top } -> untyped"]
        classes = shapes.to_h { |sig| [sig, only_row(widget(sig)).classification] }
        expect(classes.values.uniq).to eq([SigProvenanceAuditor::UNRENDERABLE])
      end

      it "still counts a container of `untyped` as stating a type" do
        shapes = ["(Array[untyped] x, untyped y) -> untyped", "([untyped, untyped] x, untyped y) -> untyped",
                  "({ a: untyped } x, untyped y) -> untyped", "(^(untyped) -> untyped x, untyped y) -> untyped"]
        classes = shapes.to_h { |sig| [sig, only_row(widget(sig)).classification] }
        expect(classes.values.uniq).to eq([SigProvenanceAuditor::PARAMETER_ONLY])
      end

      it "counts any non-`untyped` parameter kind: optional, rest, keyword and keyword-rest" do
        shapes = ["(untyped x, untyped y, ?Integer z) -> untyped", "(untyped x, untyped y, *Integer z) -> untyped",
                  "(untyped x, untyped y, k: Integer) -> untyped", "(untyped x, untyped y, **Integer rest) -> untyped"]
        ruby = "class Widget\n  def n(x, y, z = nil, *r, k: 1, **o)\n    y\n  end\nend\n"
        classes = shapes.to_h { |sig| [sig, only_row(widget(sig), ruby: ruby).classification] }
        expect(classes.values.uniq).to eq([SigProvenanceAuditor::PARAMETER_ONLY])
      end

      it "classes a stale typed/`untyped` declaration `no_source` and residue, never `parameter_only`" do
        row = audit_fixture(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                            rbs: "class Widget\n  def gone: (Integer x) -> untyped\nend\n")
              .find { |r| r.declaration.method_name == "gone" }
        expect(row.classification).to eq(SigProvenanceAuditor::NO_SOURCE)
        expect(row).to be_residue
      end

      it "classes a `define_method` member declared with typed parameters and `untyped` `synthetic_source`" do
        row = audit_fixture(ruby: "class Widget\n  define_method(:n) { |x| x }\nend\n",
                            rbs: "class Widget\n  def n: (Integer x) -> untyped\nend\n")
              .find { |r| r.declaration.method_name == "n" }
        expect(row.classification).to eq(SigProvenanceAuditor::SYNTHETIC)
        expect(row).to be_residue
      end

      it "leaves a MARKED all-`untyped` row `unrenderable`: a marker never qualifies a row" do
        rbs = "class Widget\n  # authored: nothing stated.\n  def n: (untyped x, untyped y) -> untyped\nend\n"
        row = only_row(rbs)
        expect(row.classification).to eq(SigProvenanceAuditor::UNRENDERABLE)
        expect(row).to be_marked
      end

      it "never leaves the class on its own for a self-recursive method: the author declares the return" do
        ruby = "class Widget\n  def n(xs, k)\n    return k if xs.empty?\n\n    n(xs.drop(1), k + 1)\n  end\nend\n"
        stuck = only_row(widget("(Array[Integer] xs, Integer k) -> untyped"), ruby: ruby)
        declared = only_row(widget("(Array[Integer] xs, Integer k) -> Integer"), ruby: ruby)
        expect(stuck.classification).to eq(SigProvenanceAuditor::PARAMETER_ONLY)
        expect(declared.classification).to eq(SigProvenanceAuditor::PARAMETER_INTENT)
      end

      it "leaves for `declared_divergent` residue, not `tighter_return`, when the return becomes a bare `nil`" do
        row = only_row(widget("(Integer x) -> untyped"), ruby: "class Widget\n  def n(x)\n    nil\n  end\nend\n")
        expect(row.classification).to eq(SigProvenanceAuditor::DECLARED_DIVERGENT)
        expect(row).to be_residue
      end

      it "does not apply to a skip for any other reason" do
        declaration = SigProvenanceAuditor::Declaration.new(
          path: "sig/widget.rbs", line: 2, class_name: "Widget", method_name: "n", kind: :instance,
          typed_params: true, types_something: true, return_rbs: "untyped", untyped_return: true,
          marker: nil
        )
        classes = %i[untyped_return complex_shape unrenderable_rbs].to_h do |reason|
          skipped = Rigor::SigGen::MethodCandidate.new(
            path: "lib/widget.rb", class_name: "Widget", method_name: :n, kind: :instance,
            classification: Rigor::SigGen::Classification::SKIPPED, skip_reason: reason
          )
          [reason, SigProvenanceAuditor.classify([declaration], [skipped], environment: nil).first.classification]
        end
        expect(classes).to eq(untyped_return: SigProvenanceAuditor::PARAMETER_ONLY,
                              complex_shape: SigProvenanceAuditor::UNRENDERABLE,
                              unrenderable_rbs: SigProvenanceAuditor::UNRENDERABLE)
      end

      it "keeps the marker meaning: a marked row is recorded, and still counted as watched" do
        rbs = "class Widget\n  # authored: parameters only until sig-gen can render the return.\n  " \
              "def n: (Integer x, untyped y) -> untyped\nend\n"
        row = only_row(rbs)
        expect(row.classification).to eq(SigProvenanceAuditor::PARAMETER_ONLY)
        expect(row).to be_marked
        expect(row).to be_watched
        expect(row).not_to be_residue
      end

      it "leaves a declared `untyped` return on a RENDERABLE method flagged as before (tighter-return)" do
        row = only_row(widget("(Integer x) -> untyped"), ruby: "class Widget\n  def n(x)\n    x\n  end\nend\n")
        expect(row.classification).to eq(SigProvenanceAuditor::TIGHTER_RETURN)
        expect(row).not_to be_marked
      end

      it "returns to scrutiny the moment typing a parameter makes the return renderable (the ratchet)" do
        before = only_row(widget("(Integer x, untyped y) -> untyped"))
        after = only_row(widget("(Integer x, String y) -> untyped"))
        expect(before.classification).to eq(SigProvenanceAuditor::PARAMETER_ONLY)
        expect(after.classification).to eq(SigProvenanceAuditor::TIGHTER_RETURN)
        expect(after.detail).to include("sig-gen proposes String")
        expect(after).not_to be_marked
      end

      it "prints the count per file and in total in the report, marked rows included" do
        rows = audit_fixture(ruby: unrenderable_ruby, rbs: widget("(Integer x, untyped y) -> untyped"))
        out = StringIO.new
        SigProvenanceReport.render(rows, out: out)
        expect(out.string).to include("### parameter_only (watched, not residue): 1 total, 0 marked")
        expect(out.string).to include("- `sig/fixture.rbs`: 1")
        expect(out.string).to match(%r{\| `sig/fixture.rbs` \|(?: \d+ \|)+ 1 \| \d+ \| 0 \|$})
      end
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

  describe "the parameter-shape check (#3335)" do
    def misfit(signature, ruby)
      def_node = Prism.parse(ruby).value.statements.body.first
      SigParameterShape.misfit(RBS::Parser.parse_method_type(signature), SigParameterShape.def_shape(def_node))
    end

    def misfits(*pairs) = pairs.map { |signature, ruby| misfit(signature, ruby) }

    it "accepts what an overload legitimately does: omit an optional, require one, or narrow a rest or a block" do
      fits = misfits(
        ["(untyped x) -> untyped", "def n(x, y = 1) = x"],
        ["(untyped x, untyped y) -> untyped", "def n(x, y = 1) = x"],
        ["(untyped x, ?untyped y) -> untyped", "def n(x, y = 1) = x"],
        ["(untyped x, untyped y, untyped z) -> untyped", "def n(x, *rest) = x"],
        ["(untyped x, *untyped rest) -> untyped", "def n(x, *rest) = x"],
        ["(untyped x, untyped y) -> untyped", "def n(x, *, y) = x"],
        ["(k: untyped) -> untyped", "def n(k:, j: 1) = k"],
        ["(k: untyped, ?j: untyped) -> untyped", "def n(k:, j: 1) = k"],
        ["(k: untyped, other: untyped, **untyped) -> untyped", "def n(k:, **opts) = k"],
        ["() -> untyped", "def n(&blk) = blk"],
        ["() { () -> untyped } -> untyped", "def n(&blk) = blk"],
        ["() ?{ () -> untyped } -> untyped", "def n = (yield if block_given?)"],
        ["() { () -> untyped } -> untyped", "def n = super"],
        ["() { () -> untyped } -> untyped", "def n(x = 1) = super(x)"],
        ["(untyped x, untyped y, k: untyped, **untyped) { () -> untyped } -> untyped", "def n(x, ...) = m(...)"]
      )
      expect(fits.uniq).to eq([nil])
    end

    it "lets keywords fill a free optional or rest slot of a def with no keyword parameter (a positional Hash)" do
      expect(misfits(
        ["(untyped a, ?key: Integer) -> untyped", "def m(a, o = {}) = a"],
        ["(key: Integer) -> untyped", "def n(*a) = a"],
        ["(Integer, key: Integer) -> untyped", "def o(*) = 1"],
        ["(untyped a, **untyped) -> untyped", "def m(a, o = {}) = a"]
      ).uniq).to eq([nil])
    end

    it "still rejects keywords with no free positional slot, or on a `**nil` def" do
      expect(misfits(
        ["(untyped a, key: Integer) -> untyped", "def p(a) = a"],
        ["(untyped a, untyped o, key: Integer) -> untyped", "def m(a, o = {}) = a"],
        ["(untyped a, key: Integer) -> untyped", "def q(a, o = {}, **nil) = a"]
      ).uniq).to eq(["names keyword(s) the def does not take: key"])
    end

    it "reads a block query only bare, on `self` or on `Kernel`, and a `yield` inside a block of the body" do
      expect(misfits(
               ["() { () -> untyped } -> untyped", "def n = Kernel.block_given?"],
               ["() { () -> untyped } -> untyped", "def n = ::Kernel.block_given?"],
               ["() { () -> untyped } -> untyped", "def n = self.block_given?"],
               ["() { () -> untyped } -> untyped", "def n = iterator?"],
               ["() { (untyped) -> untyped } -> untyped", "def n = [1].each { |e| yield e }"],
               ["() { () -> untyped } -> untyped", "def n = x.block_given?"],
               ["() { () -> untyped } -> untyped", "def n = Other.block_given?"]
             )).to eq([nil, nil, nil, nil, nil,
                       "declares a block, the def neither takes nor yields one",
                       "declares a block, the def neither takes nor yields one"])
    end

    it "rejects a positional count the def cannot take, in either direction" do
      expect(misfits(
               ["(untyped x) -> untyped", "def n(x, y) = x"],
               ["(untyped x, untyped y, untyped z) -> untyped", "def n(x, y = 1) = x"],
               ["(untyped x, *untyped rest) -> untyped", "def n(x, y = 1) = x"],
               ["(?untyped x) -> untyped", "def n(x) = x"],
               ["(untyped a) -> untyped", "def m(a, *r, b) = a"],
               ["() -> untyped", "def n(x, ...) = m(...)"]
             )).to eq(["admits 1 positional argument(s), the def requires 2",
                       "admits 3 positional argument(s), the def takes at most 2",
                       "admits any number of positional argument(s), the def takes at most 2",
                       "admits 0 positional argument(s), the def requires 1",
                       "admits 1 positional argument(s), the def requires 2",
                       "admits 0 positional argument(s), the def requires 1"])
    end

    it "rejects a keyword the def does not take, a required keyword left out or made optional, and a **rest" do
      expect(misfits(
               ["(untyped x, untyped y, key: String) -> untyped", "def n(x, y, &blk) = x"],
               ["(?j: untyped) -> untyped", "def n(k:, j: 1) = k"],
               ["(?k: untyped) -> untyped", "def n(k:, j: 1) = k"],
               ["(k: untyped, **untyped) -> untyped", "def n(k:, j: 1) = k"]
             )).to eq(["names keyword(s) the def does not take: key",
                       "does not require keyword(s) the def requires: k",
                       "does not require keyword(s) the def requires: k",
                       "declares **rest, the def takes no keyword rest"])
    end

    it "rejects a declared block on a def that neither takes nor yields one, a nested def's yield included" do
      expect(misfits(
        ["() { () -> untyped } -> untyped", "def n = 1"],
        ["() ?{ () -> untyped } -> untyped", "def n\n  def m = yield\nend"]
      ).uniq).to eq(["declares a block, the def neither takes nor yields one"])
    end

    describe "over a fixture project" do
      let(:fixture_root) { Dir.mktmpdir }

      after { FileUtils.remove_entry(fixture_root) }

      it "fails a wrong keyword name and a wrong positional count, naming file, method, both lists" do
        ruby = "class Widget\n  def n(x, y, &blk)\n    x\n  end\n\n  def m(a, b = 1)\n    a\n  end\nend\n"
        rbs = "class Widget\n  def n: (untyped x, untyped y, key: String) -> untyped\n  " \
              "def m: (Integer a, Integer b, Integer c) -> untyped\nend\n"
        result = SigParameterShape.check(audit_fixture(ruby: ruby, rbs: rbs))
        expect(result.mismatches.map(&:to_s)).to eq(
          ["sig/fixture.rbs:2: Widget#n — declared `(untyped x, untyped y, key: String) -> untyped`, " \
           "def `def n(x, y, &blk)`: names keyword(s) the def does not take: key",
           "sig/fixture.rbs:3: Widget#m — declared `(Integer a, Integer b, Integer c) -> untyped`, " \
           "def `def m(a, b = 1)`: admits 3 positional argument(s), the def takes at most 2"]
        )
        expect(result.compared).to eq(2)
      end

      it "checks every overload, not only the first, and pairs a constructor and a `self?.` module function" do
        ruby = "class Widget\n  def initialize(x)\n    @x = x\n  end\n\n  def n(x)\n    x\n  end\nend\n" \
               "module Tool\n  module_function\n\n  def run(a)\n    a\n  end\nend\n"
        rbs = "class Widget\n  def initialize: () -> void\n  " \
              "def n: (Integer x) -> untyped | (Integer x, Integer y) -> untyped\nend\n" \
              "module Tool\n  def self?.run: () -> untyped\nend\n"
        result = SigParameterShape.check(audit_fixture(ruby: ruby, rbs: rbs))
        expect(result.mismatches.map { |m| [m.declaration.method_name, m.declared] }).to eq(
          [["initialize", "() -> void"], ["n", "(Integer x, Integer y) -> untyped"], ["run", "() -> untyped"]]
        )
      end

      it "compares a def sig-gen makes no candidate of: a parameterless `initialize`" do
        rows = audit_fixture(ruby: "class Widget\n  def initialize\n  end\nend\n",
                             rbs: "class Widget\n  def initialize: (Integer x) -> void\nend\n")
        row = rows.find { |r| r.declaration.method_name == "initialize" }
        expect(row.paired).to be(false)
        result = SigParameterShape.check(rows)
        expect(result.mismatches.map(&:to_s)).to eq(
          ["sig/fixture.rbs:2: Widget#initialize — declared `(Integer x) -> void`, def `def initialize()`: " \
           "admits 1 positional argument(s), the def takes at most 0"]
        )
      end

      it "passes an overload any def of a contested slot accepts, and names every def when none does" do
        ruby = "class Widget\n  if RUBY_VERSION > \"3\"\n    def n(x)\n      x\n    end\n  else\n    " \
               "def n(x, y)\n      x\n    end\n  end\nend\n"
        rbs = "class Widget\n  def n: (untyped x) -> untyped | (untyped x, untyped y) -> untyped | " \
              "(untyped x, untyped y, untyped z) -> untyped\nend\n"
        result = SigParameterShape.check(audit_fixture(ruby: ruby, rbs: rbs))
        expect(result.mismatches.map(&:to_s)).to eq(
          ["sig/fixture.rbs:2: Widget#n — declared `(untyped x, untyped y, untyped z) -> untyped`, " \
           "def `def n(x)` | `def n(x, y)`: admits 3 positional argument(s), the def takes at most 1"]
        )
      end

      it "compares against the def in every file of a reopened class" do
        write_fixture("lib/other.rb", "class Widget\n  def n(x, y)\n    x\n  end\nend\n")
        rbs = "class Widget\n  def n: (untyped x) -> untyped | (untyped x, untyped y) -> untyped\nend\n"
        rows = audit_fixture(ruby: "class Widget\n  def n(x)\n    x\n  end\nend\n", rbs: rbs)
        expect(rows.find { |r| r.declaration.method_name == "n" }.source_defs.size).to eq(2)
        expect(SigParameterShape.check(rows).mismatches).to be_empty
      end

      it "spells a singleton declaration and its def as Ruby calls them" do
        result = SigParameterShape.check(audit_fixture(ruby: "class Widget\n  def self.n(x)\n    x\n  end\nend\n",
                                                       rbs: "class Widget\n  def self.n: () -> untyped\nend\n"))
        expect(result.mismatches.map(&:to_s)).to eq(
          ["sig/fixture.rbs:2: Widget.n — declared `() -> untyped`, def `def self.n(x)`: " \
           "admits 0 positional argument(s), the def requires 1"]
        )
      end

      it "counts each declaration it cannot compare as exempt by reason, never dropping one" do
        ruby = "class Widget\n  attr_reader :a, :b\n  define_method(:d) { |x| x }\n\n  " \
               "def u(x)\n    x\n  end\n\n  def n(x)\n    x\n  end\nend\n"
        rbs = "class Widget\n  attr_reader a: Integer\n  def d: (Integer x) -> untyped\n  " \
              "def u: (?) -> untyped\n  def n: (Integer x) -> untyped\n  def b: () -> Integer\nend\n"
        result = SigParameterShape.check(audit_fixture(ruby: ruby, rbs: rbs))
        expect(result.exempt).to eq(SigParameterShape::EXEMPT_ATTRIBUTE => 1, SigParameterShape::EXEMPT_NO_DEF => 1,
                                    SigParameterShape::EXEMPT_UNTYPED_FUNCTION => 1,
                                    SigParameterShape::EXEMPT_CANDIDATE_WITHOUT_DEF => 1)
        expect(result.compared).to eq(1)
        expect(result.mismatches).to be_empty
      end

      it "prints the compared and exempt counts, and each mismatch, in the report" do
        rows = audit_fixture(ruby: "class Widget\n  def n(x)\n    x\n  end\nend\n",
                             rbs: "class Widget\n  def n: () -> untyped\nend\n")
        out = StringIO.new
        SigProvenanceReport.render(rows, out: out, shapes: SigParameterShape.check(rows))
        expect(out.string).to include(
          "### parameter lists against the def: 1 compared, 0 exempt (no_def 0, attribute 0, " \
          "candidate_without_def 0, untyped_function 0), 1 mismatched"
        )
        expect(out.string).to include("- sig/fixture.rbs:2: Widget#n — declared `() -> untyped`, def `def n(x)`")
      end
    end
  end

  describe "the classifier's two states the corpus does not currently reach" do
    def row_for(candidate, method: "n", return_rbs: "Integer")
      declaration = SigProvenanceAuditor::Declaration.new(
        path: "sig/widget.rbs", line: 2, class_name: "Widget", method_name: method,
        kind: :instance, typed_params: false, return_rbs: return_rbs, marker: nil
      )
      SigProvenanceAuditor.classify([declaration], [candidate], environment: nil).first
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
      expect(unmarked).to be_empty, -> { tighter_return_message(unmarked) }
    end

    describe "the tighter-return failure message (#3335)" do
      def tighter_row(return_rbs)
        declaration = SigProvenanceAuditor::Declaration.new(
          path: "sig/widget.rbs", line: 2, class_name: "Widget", method_name: "n", kind: :instance,
          return_rbs: return_rbs, untyped_return: return_rbs == "untyped", marker: nil
        )
        SigProvenanceAuditor::Row.new(declaration: declaration, classification: SigProvenanceAuditor::TIGHTER_RETURN,
                                      detail: "declared #{return_rbs}, sig-gen proposes Integer")
      end

      it "tells a declared `untyped` return to adopt the proposal and offers no marker" do
        message = tighter_return_message([tighter_row("untyped")])
        expect(message).to include("adopt sig-gen's proposal")
        expect(message).to include("sig/widget.rbs:2: Widget#n")
        expect(message).not_to include("sig-gen gap:")
        expect(message).not_to include("authored:")
      end

      it "offers a marker for a declared return that states a type" do
        message = tighter_return_message([tighter_row("Numeric")])
        expect(message).to include("# sig-gen gap: #NNN")
        expect(message).to include("# authored:")
        expect(message).not_to include("adopt sig-gen's proposal")
      end
    end

    it "fits every declaration's parameter list to the def it declares (#3335)" do
      result = SigParameterShape.check(SIG_PROVENANCE_ROWS)
      expect(result.mismatches).to be_empty, -> { parameter_shape_message(result) }
    end

    it "accounts for every method declaration as compared or exempt by reason, and compares no fewer (#3335)" do
      result = SigParameterShape.check(SIG_PROVENANCE_ROWS)
      RSpec.configuration.reporter.message("sig/ parameter lists against the def: #{result.summary}")
      methods = SIG_PROVENANCE_ROWS.count { |row| row.declaration.kind }
      expect(result.compared + result.exempt.values.sum).to eq(methods)
      expect(result.exempt.keys - SigParameterShape::EXEMPT_REASONS).to be_empty
      expect(result.compared).to be >= SIG_PARAMETER_SHAPE_COMPARED_FLOOR, lambda {
        "#{result.summary}: fewer declarations compared than SIG_PARAMETER_SHAPE_COMPARED_FLOOR " \
          "(#{SIG_PARAMETER_SHAPE_COMPARED_FLOOR}). Lower it only with the reason in the commit body."
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

    it "keeps each file's `parameter_only` count at its pin, marked and unmarked apart, in both directions" do
      rows = SIG_PROVENANCE_ROWS.select { |row| row.classification == SigProvenanceAuditor::PARAMETER_ONLY }
      actual = rows.group_by { |row| row.declaration.path }.transform_values do |group|
        marked, unmarked = group.partition(&:marked?)
        { unmarked: unmarked.size, marked: marked.size }
      end
      drift = (actual.keys | SIG_PROVENANCE_PARAMETER_ONLY.keys).filter_map do |path|
        pinned = SIG_PROVENANCE_PARAMETER_ONLY.fetch(path, { unmarked: 0, marked: 0 })
        found = actual.fetch(path, { unmarked: 0, marked: 0 })
        "  #{path}: #{found} (pinned #{pinned})" unless found == pinned
      end
      expect(drift).to be_empty, lambda {
        "#{drift.size} file(s) drifted from SIG_PROVENANCE_PARAMETER_ONLY:\n#{drift.join("\n")}\n\n" \
          "`parameter_only` rows are declarations with typed parameters and a bare `untyped` return on a method " \
          "sig-gen cannot render. The count is expected to GROW as parameters are declared and to SHRINK as returns " \
          "become renderable (an increase is expected only for newly declared parameters, a decrease means a return " \
          "became renderable); edit the pin in this file in the same PR, with the reason in the commit body."
      }
    end

    it "carries no marker on a `parameter_only` row beyond the grandfathered two (a marker would make it permanent)" do
      marked = SIG_PROVENANCE_ROWS.select { |row| row.classification == SigProvenanceAuditor::PARAMETER_ONLY && row.marked? }
      keys = marked.map { |row| "#{row.declaration.path} #{row.declaration.class_name}##{row.declaration.method_name}" }
      added = keys - SIG_PROVENANCE_PARAMETER_ONLY_MARKED
      expect(added).to be_empty, -> { parameter_only_marker_message(keys) }
      gone = SIG_PROVENANCE_PARAMETER_ONLY_MARKED - keys
      expect(gone).to be_empty, -> { parameter_only_grandfather_message(gone) }
    end

    it "names only the NEW marked `parameter_only` rows in its failure message, never the grandfathered ones" do
      message = parameter_only_marker_message(SIG_PROVENANCE_PARAMETER_ONLY_MARKED + ["sig/new.rbs Widget#n"])
      expect(message).to include("Remove the marker: sig/new.rbs Widget#n")
      SIG_PROVENANCE_PARAMETER_ONLY_MARKED.each { |key| expect(message).not_to include(key) }
      gone = parameter_only_grandfather_message(["sig/old.rbs Widget#m"])
      expect(gone).to include("left the class or lost its marker")
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
