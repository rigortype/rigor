# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../source/node_walker"
require_relative "../source/constant_path"
require_relative "../inference/singleton_object_constant"
require_relative "../inference/object_mixins"
require_relative "shadow_harness"
require_relative "../type"
require_relative "diagnostic"
require_relative "dependency_recorder"
require_relative "check_rules/rule_ids"
require_relative "check_rules/call_facts"
require_relative "check_rules/inferred_param_guard"
require_relative "check_rules/declaration_sourced_guard"
require_relative "check_rules/published_constant_guard"
require_relative "check_rules/dead_version_guard_arms"
require_relative "check_rules/rule_walk"
require_relative "check_rules/always_raises_shield"
require_relative "check_rules/always_truthy_condition_collector"
require_relative "check_rules/unreachable_clause_collector"
require_relative "check_rules/shadowed_rescue_collector"
require_relative "check_rules/dead_assignment_collector"
require_relative "check_rules/duplicate_hash_key_collector"
require_relative "check_rules/return_in_ensure_collector"
require_relative "check_rules/ivar_write_collector"
require_relative "check_rules/main_pass_collector"
require_relative "check_rules/void_value_use_collector"
require_relative "check_rules/self_closedness_scanner"
require_relative "check_rules/source_arity"
require_relative "check_rules/lexical_method_sites"
require_relative "check_rules/rebinding_block_callees"
require_relative "check_rules/rbs_receiver_surface"
require_relative "check_rules/special_global_setters"
require_relative "check_rules/ruby_deprecations"
require_relative "check_rules/plugin_api_surface"
require_relative "check_rules/receiver_predicates"
require_relative "check_rules/suppression"
require_relative "check_rules/argument_type"
require_relative "check_rules/undefined_method"
require_relative "check_rules/return_type"
require_relative "check_rules/unreachable_branch"
require_relative "check_rules/nil_receiver"
require_relative "check_rules/wrong_arity"
require_relative "check_rules/override_param_narrowed"
require_relative "check_rules/override_return_widened"
require_relative "check_rules/override_support"
require_relative "check_rules/override_visibility"
require_relative "check_rules/visibility_mismatch"
require_relative "check_rules/always_raises"
require_relative "check_rules/raise_non_exception"
require_relative "check_rules/rigor_testing"
require_relative "check_rules/self_undefined_method"
require_relative "check_rules/special_global_write"
require_relative "check_rules/unresolved_toplevel"
require_relative "../typing_state"

module Rigor
  module Analysis
    # Catalogue of `rigor check` diagnostic rules.
    #
    # Rules fire ONLY when the engine is confident enough to make a
    # useful claim and MUST NOT raise on unrecognised AST shapes,
    # RBS gaps, or missing scope information. Each rule consumes
    # the per-node scope index produced by
    # `Rigor::Inference::ScopeIndexer.index` and yields zero or
    # more `Rigor::Analysis::Diagnostic` values.
    #
    # The primary rule (`call.undefined-method`) flags an
    # explicit-receiver `Prism::CallNode` whose receiver statically
    # resolves to a class known to the RBS environment and whose
    # method name does not appear on that class's method table.
    # It does NOT fire for:
    #
    # - implicit-self calls (no `node.receiver`) — too noisy
    #   without per-method RBS for every helper in the class.
    # - dynamic / unknown receivers (`Dynamic[T]`, `Top`)
    #   — by definition we cannot enumerate the method set.
    # - shape carriers: `Tuple` → "Array", `HashShape` → "Hash",
    #   `Constant` → the constant's class — `concrete_class_name`
    #   resolves these to their runtime class for dispatch.
    # - receivers whose class name is NOT registered in the
    #   loader (RBS-blind environments, unknown stdlib).
    module CheckRules
      # ADR-87 WD4 — the canonical rule-id table lives in the light `check_rules/rule_ids.rb` (required at the
      # top of this file) so {Analysis::RuleCatalog} can read it without loading the engine.

      # The token expansion (`resolve_rule_token` / `expand_rule_tokens` / `expand_token`) lives in the light
      # `check_rules/rule_ids.rb`, so {SeverityStamp} can apply the `disable:` list on the engine-free hit path.

      module_function

      # Returns the diagnostics for `root`'s subtree across the rule
      # catalogue. The caller MUST have already produced `scope_index` through
      # `Rigor::Inference::ScopeIndexer.index(root, default_scope:)`.
      #
      # @param path — used to populate
      #   `Diagnostic#path`; the rule does not open files.
      #
      # ADR-53 B4 — when `node_collectors` is supplied, the converged
      # {Plugin::NodeRuleWalk} traversal has already populated the built-in
      # collectors (including the main pass) in one shared walk with the
      # plugin node-rules, so they are consumed as-is. When it is nil (a
      # direct caller with no plugin walk, e.g. a unit test), the standalone
      # {RuleWalk} walk runs here instead, so `diagnose` stays correct
      # without the converged path.
      #
      # @param stated_runtime_ruby — {Configuration#stated_runtime_ruby}: the explicit `target_ruby`, or nil. Only
      #   {RubyDeprecations} reads it, and it walks the file only when the stated Ruby deprecates something.
      def diagnose(path:, root:, scope_index:, self_call_misses: [], comments: [], disabled_rules: [], # rubocop:disable Metrics/ParameterLists
                   node_collectors: nil, stated_runtime_ruby: nil)
        collectors = node_collectors || run_node_collectors(path, root, scope_index)
        diagnostics = collectors[:main_pass].results.dup
        diagnostics.concat(SelfUndefinedMethod.diagnostics(path, self_call_misses, root, scope_index))
        COLLECTOR_DIAGNOSTIC_BUILDERS.each do |role, builder|
          collector = OPTIONAL_COLLECTOR_ROLES.include?(role) ? collectors[role] : collectors.fetch(role)
          diagnostics.concat(builder.diagnostics(path, collector.results)) if collector
        end
        # ADR-47 WD5 — the dead arm of a decidable version guard (#627) reports nothing: it cannot run on
        # the Ruby being checked with, so a diagnostic there is a false positive. Applied before
        # `suppression.*` joins the list, which stays reportable inside a dead arm — a malformed
        # `# rigor:disable` marker is an authoring error regardless of whether its code runs.
        diagnostics = DeadVersionGuardArms.filter(diagnostics, root)
        # The ADR-47 WD5 amendment (#1692) — joined after that filter: the deprecation rule reads each version guard
        # against the stated Ruby itself, and the analyzer's own Ruby says nothing about where the call runs.
        diagnostics.concat(RubyDeprecations.diagnostics(path, root, scope_index, stated_runtime_ruby))
        # Suppression-marker validation (`suppression.*`) runs BEFORE the filter so its own diagnostics are
        # suppressible like any other rule — `# rigor:disable suppression.unknown-rule` on the offending
        # comment's line works, with no regress (the token itself is known, so it never re-fires).
        diagnostics.concat(Suppression.suppression_marker_diagnostics(path, comments))
        Suppression.filter_suppressed(diagnostics, comments: comments, disabled_rules: disabled_rules)
      end

      # The per-collector diagnostic builders {.diagnose} folds over, in the historical emission order
      # (value-use-void → always-truthy → unreachable-clause → shadowed-rescue → ivar-write →
      # dead-assignment → duplicate-hash-key → return-in-ensure → plugin-api-surface). Keys match
      # {.build_node_collectors}' roles; each value is the collector class (or module) whose
      # `diagnostics(path, results)` builds the rows.
      # `void_value_use` leads because its standalone walk used to run before this fold, and the emission order is
      # byte-identical output, not an implementation detail.
      COLLECTOR_DIAGNOSTIC_BUILDERS = {
        void_value_use: VoidValueUseCollector,
        always_truthy: AlwaysTruthyConditionCollector,
        unreachable_clauses: UnreachableClauseCollector,
        shadowed_rescues: ShadowedRescueCollector,
        ivar_writes: IvarWriteCollector,
        dead_assignments: DeadAssignmentCollector,
        duplicate_hash_keys: DuplicateHashKeyCollector,
        return_in_ensure: ReturnInEnsureCollector,
        plugin_api_surface: PluginApiSurface
      }.freeze
      private_constant :COLLECTOR_DIAGNOSTIC_BUILDERS

      # The roles {.build_node_collectors} builds only on request: `plugin_api_surface`, when the rule is active
      # ({PluginApiSurface.active?}). {.diagnose} skips an absent optional role; every other role is required, and a
      # missing one raises.
      OPTIONAL_COLLECTOR_ROLES = %i[plugin_api_surface].freeze

      # The verbatim per-node dispatch of the former inline main pass
      # (`diagnose`'s `Source::NodeWalker.each` `case`), now invoked by
      # {MainPassCollector} on the shared {RuleWalk}. Returns the
      # diagnostics for one node, in the same emission order as before.
      def main_pass_node_diagnostics(path, node, scope_index, eval_ranges = nil, lexical_sites = nil,
                                     raise_shield = nil)
        case node
        when Prism::CallNode
          call_node_diagnostics(path, node, scope_index, eval_ranges, lexical_sites, raise_shield)
        when Prism::DefNode
          [
            ReturnType.diagnostic(path, node, scope_index, lexical_sites),
            OverrideVisibility.diagnostic(path, node, scope_index),
            OverrideReturnWidened.diagnostic(path, node, scope_index),
            OverrideParamNarrowed.diagnostic(path, node, scope_index)
          ].compact
        when Prism::IfNode, Prism::UnlessNode
          [UnreachableBranch.diagnostic(path, node, scope_index)].compact
        when Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode, Prism::MultiWriteNode
          SpecialGlobalWrite.diagnostics(path, node, scope_index, lexical_sites)
        else
          []
        end
      end

      # Constructs the fresh, unpopulated built-in collector set keyed by
      # role, including the main pass. Split out so the converged walk
      # (ADR-53 B4) can build the collectors, drive them via a
      # {RuleWalk::CollectorDriver} inside the single {Plugin::NodeRuleWalk}
      # traversal, and hand the populated set back to {.diagnose} as
      # `node_collectors:`. The main pass needs `path` because its per-node
      # diagnostics carry it (ADR-53 B3c hosts it on the same walk).
      #
      # `plugin_api_surface:` adds the `plugin.api-surface` collector, which the runner asks for only when the rule
      # resolves to a reporting severity ({PluginApiSurface.active?}).
      def build_node_collectors(path, scope_index, root = nil, plugin_api_surface: false)
        eval_ranges = receiver_eval_block_ranges(root)
        lexical_sites = LexicalMethodSites.new(root, stamped_refinements(scope_index, root))
        raise_shield = root && AlwaysRaisesShield.new(root)
        main_pass = lambda do |node|
          main_pass_node_diagnostics(path, node, scope_index, eval_ranges, lexical_sites, raise_shield)
        end
        collectors = {
          main_pass: MainPassCollector.new(main_pass),
          void_value_use: VoidValueUseCollector.new(scope_index),
          always_truthy: AlwaysTruthyConditionCollector.new(scope_index),
          unreachable_clauses: UnreachableClauseCollector.new(scope_index),
          shadowed_rescues: ShadowedRescueCollector.new(scope_index),
          ivar_writes: IvarWriteCollector.new(scope_index),
          dead_assignments: DeadAssignmentCollector.new(scope_index),
          duplicate_hash_keys: DuplicateHashKeyCollector.new(scope_index),
          return_in_ensure: ReturnInEnsureCollector.new(scope_index)
        }
        collectors[:plugin_api_surface] = PluginApiSurface::Collector.new(scope_index) if plugin_api_surface
        collectors
      end

      # A {RuleWalk::CollectorDriver} over a built-in collector set, for a
      # foreign traversal to drive (ADR-53 B4). The driver visits each node
      # and derives child contexts exactly as the standalone {RuleWalk}
      # walk would.
      def node_collector_driver(collectors)
        RuleWalk::CollectorDriver.new(collectors.values)
      end

      # ADR-53 Track B — the {RuleWalk}-hosted built-in collectors (the main
      # pass and the fact collectors) all ride one traversal of the
      # file instead of one walk each. Returns the populated collectors
      # keyed by role so the caller can build the diagnostics from each
      # collector's `results`. Used on the standalone path (no converged
      # plugin walk); the converged path populates the same collector set
      # via {.node_collector_driver} instead.
      #
      # Under `RIGOR_SHADOW_RULE_WALK=1` each hosted collector's legacy
      # single-collector `#collect` walk also runs as the oracle and any
      # divergence aborts the run — the corpus-scale half of the
      # equivalence harness (the curated half is `rule_walk_equivalence_spec`).
      def run_node_collectors(path, root, scope_index)
        collectors = build_node_collectors(path, scope_index, root)
        RuleWalk.run(root, collectors.values)
        shadow_verify_node_collectors(path, root, scope_index, collectors) if ShadowHarness.enabled?
        collectors
      end

      def shadow_verify_node_collectors(path, root, scope_index, collectors)
        divergences = collectors.filter_map do |role, collector|
          legacy = oracle_results(role, collector, path, root, scope_index)
          next if comparable(legacy) == comparable(collector.results)

          "#{role} legacy=#{legacy.size} walk=#{collector.results.size}"
        end
        return if divergences.empty?

        raise "RIGOR_SHADOW_RULE_WALK divergence: #{divergences.join('; ')}"
      end

      # Normalises a collector's result for value comparison. The fact
      # collectors return `Data` / Hash structures that already compare by
      # value; the main pass returns {Diagnostic} objects (plain objects
      # with identity `==`), so serialise those to hashes first.
      def comparable(results)
        return results.map(&:to_h) if results.is_a?(Array) && results.first.is_a?(Diagnostic)

        results
      end

      # The oracle each hosted collector's walk result is checked against.
      # The fact collectors re-run their legacy single-collector `#collect`
      # walk; the main pass re-runs the former inline `Source::NodeWalker`
      # `case` (`main_pass_oracle`) since its diagnostics are the result.
      def oracle_results(role, collector, path, root, scope_index)
        return main_pass_oracle(path, root, scope_index) if role == :main_pass

        collector.class.new(scope_index).collect(root)
      end

      # Issue #1673 — the in-effect refinements `Inference::ScopeIndexer` stamped for `root`, read off the root's scope
      # so the rules answer from the query the typer reads; nil where the index holds no scope for it.
      def stamped_refinements(scope_index, root)
        return nil if root.nil? || scope_index.nil?

        scope_index[root]&.discovery&.in_effect_refinements
      end

      # The former inline main pass, kept as the shadow oracle: walks the
      # tree with `Source::NodeWalker.each` and accumulates the same
      # per-node diagnostics in the same order {MainPassCollector} now
      # produces them on the shared walk.
      def main_pass_oracle(path, root, scope_index)
        diagnostics = []
        eval_ranges = receiver_eval_block_ranges(root)
        lexical_sites = LexicalMethodSites.new(root, stamped_refinements(scope_index, root))
        raise_shield = AlwaysRaisesShield.new(root)
        Source::NodeWalker.each(root) do |node|
          diagnostics.concat(
            main_pass_node_diagnostics(path, node, scope_index, eval_ranges, lexical_sites, raise_shield)
          )
        end
        diagnostics
      end

      # ADR-53 B4 — corpus-scale oracle for the CONVERGED walk: the
      # collectors (including the main pass, ADR-53 B3c) were populated by
      # the {Plugin::NodeRuleWalk} traversal, not by `RuleWalk.run`, so
      # re-run each collector's legacy oracle (the fact collectors'
      # `#collect` walk, the main pass's inline `Source::NodeWalker` `case`)
      # and assert the converged walk produced byte-identical results. Same
      # divergence contract as {.shadow_verify_node_collectors}; nil
      # collectors (caller without built-in collection) is a no-op. `path`
      # is threaded because the main pass's oracle carries it.
      def shadow_verify_converged_collectors(path, root, scope_index, collectors)
        return if collectors.nil?

        shadow_verify_node_collectors(path, root, scope_index, collectors)
      end

      # Issue #2786 — the rules that type the call's receiver read it from one {CallFacts}, so the receiver chain is
      # typed once per call node rather than once per rule.
      def call_node_diagnostics(path, node, scope_index, eval_ranges = nil, lexical_sites = nil,
                                raise_shield = nil)
        facts = CallFacts.new(node, scope_index)
        [
          UndefinedMethod.diagnostic(path, node, facts, lexical_sites),
          UnresolvedToplevel.diagnostic(path, node, scope_index, eval_ranges, lexical_sites),
          WrongArity.diagnostic(path, node, facts, lexical_sites),
          ArgumentType.diagnostic(path, node, facts, lexical_sites),
          NilReceiver.diagnostic(path, node, facts, lexical_sites),
          RigorTesting.dump_diagnostic(path, node, scope_index),
          RigorTesting.assert_diagnostic(path, node, scope_index),
          AlwaysRaises.diagnostic(path, node, facts, lexical_sites, raise_shield),
          RaiseNonException.diagnostic(path, node, scope_index),
          VisibilityMismatch.diagnostic(path, node, facts, lexical_sites)
        ].compact
      end

      # ADR-116 WD1 — the suppression filters live in {Suppression}; these keep `CheckRules.filter_suppressed` and
      # `CheckRules.filter_plugin_suppressed` callable under their old names.
      def filter_suppressed(diagnostics, comments:, disabled_rules:)
        Suppression.filter_suppressed(diagnostics, comments: comments, disabled_rules: disabled_rules)
      end

      def filter_plugin_suppressed(diagnostics, path:, comments:)
        Suppression.filter_plugin_suppressed(diagnostics, path: path, comments: comments)
      end

      class << self
        private

        # ScopeIndexer keeps RECEIVER_EVAL_CALLS private; this list is the same family
        # (`class_eval` / `module_eval` / `class_exec` / `module_exec` / `instance_eval` /
        # `instance_exec`). Used only to decline ADR-34 inside those blocks.
        RECEIVER_EVAL_CALL_NAMES = %i[
          class_eval module_eval class_exec module_exec instance_eval instance_exec
        ].freeze
        private_constant :RECEIVER_EVAL_CALL_NAMES
        EMPTY_EVAL_RANGES = [].freeze
        private_constant :EMPTY_EVAL_RANGES

        def receiver_eval_block_ranges(root)
          return EMPTY_EVAL_RANGES if root.nil?

          ranges = []
          Source::NodeWalker.each(root) do |node|
            next unless node.is_a?(Prism::CallNode)
            next unless RECEIVER_EVAL_CALL_NAMES.include?(node.name)

            block = node.block
            next unless block.is_a?(Prism::BlockNode)

            loc = block.location
            ranges << [loc.start_offset, loc.end_offset]
          end
          ranges
        end
      end
    end
  end
end
