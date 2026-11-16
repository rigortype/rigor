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
require_relative "check_rules/undefined_method"
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
    # rubocop:disable-next Metrics/ModuleLength
    module CheckRules
      # ADR-87 WD4 — the canonical rule-id table lives in the light `check_rules/rule_ids.rb` (required at the
      # top of this file) so {Analysis::RuleCatalog} can read it without loading the engine.

      # ADR-35 slice 1 — the public > protected > private ordering used to decide whether an override reduces
      # visibility. The override rules' ancestor walk is bounded by `Scope::ANCESTOR_WALK_LIMIT`, the
      # resolution chain's.
      VISIBILITY_RANK = { public: 2, protected: 1, private: 0 }.freeze

      # ADR-35 WD10 (issue #1716) — the object-lifecycle hooks the three override rules skip. `initialize` is
      # reached through `Class#new` on the class the caller names, and the copy hooks are handed an instance
      # of the receiver's own class by `dup` / `clone`, so neither is called with the PARENT's declared
      # arguments through a parent-typed reference; `new` / `dup` / `clone` discard all four returns.
      LIFECYCLE_HOOKS = %i[initialize initialize_copy initialize_dup initialize_clone].freeze

      # The names CRuby makes private on every non-singleton `def` whatever section it is written in
      # (`vm_method.c` `rb_method_entry_make`), so a source-discovered visibility for them is not the
      # runtime one and `def.override-visibility-reduced` cannot prove a reduction.
      IMPLICITLY_PRIVATE_METHODS = (LIFECYCLE_HOOKS + %i[respond_to_missing?]).freeze

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
        diagnostics.concat(self_undefined_method_diagnostics(path, self_call_misses, root, scope_index))
        COLLECTOR_DIAGNOSTIC_BUILDERS.each do |role, builder|
          collector = OPTIONAL_COLLECTOR_ROLES.include?(role) ? collectors[role] : collectors.fetch(role)
          diagnostics.concat(send(builder, path, collector.results)) if collector
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
      # {.build_node_collectors}' roles; each value is a `(path, results)` module_function on this module.
      # `void_value_use` leads because its standalone walk used to run before this fold, and the emission order is
      # byte-identical output, not an implementation detail.
      COLLECTOR_DIAGNOSTIC_BUILDERS = {
        void_value_use: :void_value_use_diagnostics,
        always_truthy: :always_truthy_condition_diagnostics,
        unreachable_clauses: :unreachable_clause_diagnostics,
        shadowed_rescues: :shadowed_rescue_diagnostics,
        ivar_writes: :ivar_write_mismatch_diagnostics,
        dead_assignments: :dead_assignment_diagnostics,
        duplicate_hash_keys: :duplicate_hash_key_diagnostics,
        return_in_ensure: :return_in_ensure_diagnostics,
        plugin_api_surface: :plugin_api_surface_diagnostics
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
            refinement_aware_return_type_mismatch(path, node, scope_index, lexical_sites),
            override_visibility_diagnostic(path, node, scope_index),
            override_return_widened_diagnostic(path, node, scope_index),
            override_param_narrowed_diagnostic(path, node, scope_index)
          ].compact
        when Prism::IfNode, Prism::UnlessNode
          [unreachable_branch_diagnostic(path, node, scope_index)].compact
        when Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode, Prism::MultiWriteNode
          special_global_write_diagnostics(path, node, scope_index, lexical_sites)
        else
          []
        end
      end

      # Issue #1120, maintainer ruling a′ — a `def` in a `refine X do … end` body redefines X's method by design, so
      # X's declared return for the name is not its contract and a mismatch against it is not reported. Every other
      # check in the body stands. The refine-body test runs only once a mismatch would report, so a file pays the
      # {LexicalMethodSites} walk only then.
      def refinement_aware_return_type_mismatch(path, node, scope_index, lexical_sites)
        replaced = lexical_sites&.replaced_singleton_defs(scope_index)
        diagnostic = return_type_mismatch_diagnostic(path, node, scope_index, replaced)
        return diagnostic if diagnostic.nil? || lexical_sites.nil?

        lexical_sites.refinements.refinement_def?(node) ? nil : diagnostic
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
          unresolved_toplevel_diagnostic(path, node, scope_index, eval_ranges, lexical_sites),
          wrong_arity_diagnostic(path, node, facts, lexical_sites),
          argument_type_diagnostic(path, node, facts, lexical_sites),
          nil_receiver_diagnostic(path, node, facts, lexical_sites),
          dump_type_diagnostic(path, node, scope_index),
          assert_type_diagnostic(path, node, scope_index),
          always_raises_diagnostic(path, node, facts, lexical_sites, raise_shield),
          raise_non_exception_diagnostic(path, node, scope_index),
          visibility_mismatch_diagnostic(path, node, facts, lexical_sites)
        ].compact
      end

      # v0.1.2 — `def.ivar-write-mismatch`. Walks every
      # ClassNode / ModuleNode body, gathers per-class ivar
      # writes with their rvalue types, and emits a diagnostic
      # when a later write's concrete class disagrees with the
      # first write's. The first write per (class, ivar) is
      # treated as the "declared" type; subsequent writes that
      # land on a different concrete class trigger.
      #
      # Conservative envelope:
      # - Only fires when both the first and the offending
      #   write resolve to a `concrete_class_name` (Nominal /
      #   Singleton / Constant / Tuple → "Array" / HashShape →
      #   "Hash"). Unions / Dynamic / IntegerRange / shape-
      #   varied carriers fall through.
      # - `NilClass` is an intentional widening idiom (`@x =
      #   "value"` then later `@x = nil` to "clear") — skipped.
      # - Singleton-method (`def self.foo`) bodies are skipped.
      #   Class-level ivars (`@x = 1` outside any def, in the
      #   class body) are also skipped — they're a separate
      #   surface (`Module#@var`) the engine doesn't yet model.
      # - A divergence the class's RBS declaration admits is withheld: when the ivar is declared (`@x: T`,
      #   or the slot an `attr_*` member implies) and that type accepts both the first write and the
      #   later one, the union is the author's intent. The declaration only silences here; checking
      #   writes against it is #1406.
      def ivar_write_mismatch_diagnostics(path, ivar_writes)
        ivar_writes.flat_map do |class_name, writes_by_ivar|
          writes_by_ivar.flat_map do |ivar_name, writes|
            ivar_mismatch_diagnostics_for(path, class_name, ivar_name, writes)
          end
        end
      end

      # v0.1.2 — `flow.dead-assignment`. Walks every `DefNode`
      # body and emits a diagnostic for each plain
      # `LocalVariableWriteNode` whose target name is never
      # read in the same body. The
      # `Analysis::CheckRules::DeadAssignmentCollector` describes
      # the conservative envelope.
      def dead_assignment_diagnostics(path, dead_assignments)
        dead_assignments.map do |result|
          build_dead_assignment_diagnostic(path, result[:write_node], result[:def_node])
        end
      end

      # v0.3.0 — `flow.duplicate-hash-key`. Emits a diagnostic for each LATER occurrence of a repeated
      # LITERAL key within one Hash literal (braced or bare-kwargs) — Ruby keeps the last entry silently
      # at runtime, so the earlier value is dead. The
      # `Analysis::CheckRules::DuplicateHashKeyCollector` describes the value-pinned-literal-only
      # envelope (symbols / plain strings / integers / floats / true / false / nil; never
      # cross-kind, never interpolation / constants / calls / splats).
      def duplicate_hash_key_diagnostics(path, duplicate_keys)
        duplicate_keys.map do |result|
          build_duplicate_hash_key_diagnostic(path, result)
        end
      end

      # v0.3.0 — `flow.return-in-ensure`. One diagnostic per explicit
      # `return` lexically inside an `ensure` clause body: it silently
      # discards the method's in-flight return value and swallows any
      # in-flight exception. Purely syntactic; the
      # `Analysis::CheckRules::ReturnInEnsureCollector` describes the
      # frame-aware envelope (nested def / lambda / `define_method`
      # blocks are excluded, plain blocks are not).
      def return_in_ensure_diagnostics(path, results)
        results.map do |result|
          build_return_in_ensure_diagnostic(path, result[:return_node])
        end
      end

      # v0.1.2 — `flow.always-truthy-condition`. Fires on
      # `if` / `unless` / ternary predicates whose inferred
      # type is a `Type::Constant` AND that don't fall in
      # the literal-only / inside-loop-or-block / defensive-
      # predicate skip envelope (see
      # `Analysis::CheckRules::AlwaysTruthyConditionCollector`
      # for the full triage rationale).
      def always_truthy_condition_diagnostics(path, results)
        results.map do |result|
          build_always_truthy_condition_diagnostic(path, result.node, result.polarity)
        end
      end

      # ADR-47 — `flow.unreachable-clause`. One diagnostic per `when` / `in` clause
      # the flow engine's narrowing proves can never match (its narrowed
      # subject is `bot`), and per `else` it proves never runs. The squiggle lands
      # on the dead clause's body, mirroring `flow.unreachable-branch`.
      def unreachable_clause_diagnostics(path, results)
        results.map do |result|
          build_unreachable_clause_diagnostic(path, result)
        end
      end

      # ADR-128 WD6 / ADR-130 slice 2 — `plugin.api-surface`, from its collector's results.
      def plugin_api_surface_diagnostics(path, results)
        PluginApiSurface.diagnostics(path, results)
      end

      # ADR-100 WD2 — `static.value-use.void`. Its value-context slot inspection rides the shared per-node
      # {RuleWalk} like the other collectors, so the file is not re-traversed for it. Each result is a
      # value-context use of a call whose author-declared `-> void` return the engine recovered to `top`.
      def void_value_use_diagnostics(path, results)
        results.map do |result|
          build_void_value_use_diagnostic(path, result)
        end
      end

      # `flow.shadowed-rescue-clause` — one diagnostic per rescue clause every earlier-comparable class of
      # which is already caught by an earlier clause of the same chain (see {ShadowedRescueCollector} for
      # the ancestry-certainty envelope).
      def shadowed_rescue_diagnostics(path, results)
        results.map do |result|
          build_shadowed_rescue_diagnostic(path, result)
        end
      end

      def ivar_mismatch_diagnostics_for(path, class_name, ivar_name, writes)
        return [] if writes.size < 2

        # Skip past leading `NilClass` writes when establishing
        # the canonical type. The common nullable-slot idiom
        # (`@x = nil` placeholder in `initialize` / a default
        # state slot, then `@x = :foo` on first concrete state)
        # would otherwise fire a false positive on every
        # concrete write because `first_class` was `NilClass`
        # and every subsequent `Symbol` / `String` / `Hash`
        # write triggered the divergence rule. The first
        # concrete (non-nil) write is the canonical type;
        # additional `NilClass` writes are still tolerated
        # downstream by the existing `other_class == "NilClass"`
        # check (the nullable-slot resets to nil between work).
        canonical = writes.find { |w| ivar_class_for(w[:type]) != "NilClass" }
        return [] if canonical.nil?

        first_class = ivar_class_for(canonical[:type])
        return [] if first_class.nil?

        canonical_index = writes.index(canonical)
        writes[(canonical_index + 1)..].filter_map do |write|
          other_class = ivar_class_for(write[:type])
          next nil if other_class.nil? || other_class == "NilClass" || other_class == first_class
          next nil if declaration_admits?(write[:declared], canonical[:type], write[:type])
          next nil if separate_invocations?(write, other_class, writes)

          build_ivar_write_mismatch_diagnostic(path, write[:node], class_name, ivar_name, first_class, other_class)
        end
      end

      # ADR-125 — a divergent write is never live together with the writes it conflicts with when the class
      # serves one entry point per instance (a plugin-declared per-invocation class, e.g. a Rails controller:
      # one action per request) and every conflicting write — non-nil, of a concrete class other than this
      # write's — sits in a DIFFERENT action of the same class. An action is a public method no declared
      # non-action macro names (`before_action :x`, `helper_method :y`); {IvarWriteCollector} decides it. A
      # conflicting write in a private or protected helper, a callback target, a `helper_method`,
      # `initialize`, or the same method keeps the finding. Which helper each action reaches is not proved
      # here.
      def separate_invocations?(write, write_class, writes)
        return false unless write[:action]

        writes.all? do |other|
          other_class = ivar_class_for(other[:type])
          next true if other_class.nil? || other_class == "NilClass" || other_class == write_class

          other[:action] && other[:method_name] != write[:method_name]
        end
      end

      def declaration_admits?(declared, *write_types)
        return false if declared.nil?

        write_types.none? { |type| Inference::Acceptance.accepts(declared, type, mode: :gradual).no? }
      end

      # ADR-116 WD1 — the suppression filters live in {Suppression}; these keep `CheckRules.filter_suppressed` and
      # `CheckRules.filter_plugin_suppressed` callable under their old names.
      def filter_suppressed(diagnostics, comments:, disabled_rules:)
        Suppression.filter_suppressed(diagnostics, comments: comments, disabled_rules: disabled_rules)
      end

      def filter_plugin_suppressed(diagnostics, path:, comments:)
        Suppression.filter_plugin_suppressed(diagnostics, path: path, comments: comments)
      end

      # rubocop:disable-next Metrics/ClassLength
      class << self
        private

        # ADR-34 — `call.unresolved-toplevel`. Fires on an
        # implicit-self call (no explicit receiver) at toplevel
        # scope (`scope.toplevel?`, i.e. outside any class /
        # module body) whose name does not resolve against:
        #
        # 1. A same-file toplevel `def` via
        #    {Scope#top_level_def_for}.
        # 2. The ADR-17 `ProjectPatchedMethods` registry under
        #    `(Object, name, :instance)` — projects declare
        #    their toplevel-injecting monkey-patches in
        #    `.rigor.yml`'s `pre_eval:` array as the canonical
        #    opt-out per ADR-34 WD2.
        # 3. The standard `Kernel` / `Object` private-method
        #    surface (`puts`, `p`, `require`, `loop`, `raise`,
        #    …) drawn from the loaded RBS environment.
        # 4. The private singleton methods of the top-level `main`
        #    object (`using`, `include`, `public`, `private`,
        #    `define_method`), read from RBS core's
        #    `RBS::Unnamed::TopLevelSelfClass`, plus
        #    `ruby2_keywords` (issue #1383).
        # 5. The instance methods of a module the project mixes
        #    into `Object` — a top-level `include M`, or an
        #    `include M` in `class Object` — or any call at all
        #    when such a module's surface is unknown (issue #1697).
        #
        # The rule deliberately does NOT generalise to
        # implicit-self calls inside `def` / `class` / `module`
        # bodies — ADR-24 WD3's lenient-on-unresolved default
        # stays in force there. ADR-24 WD4's gated class-body
        # diagnostic is a separate decision this ADR does not
        # open.
        #
        # Authored severity is `:warning`; the severity profile
        # remaps it (`strict` → `:error`, `balanced` →
        # `:warning`, `lenient` → `:off` / suppressed).
        def unresolved_toplevel_diagnostic(path, call_node, scope_index, eval_ranges = nil, lexical_sites = nil)
          return nil unless call_node.receiver.nil?

          scope = scope_index[call_node]
          return nil if scope.nil?
          return nil unless scope.toplevel?

          name = call_node.name
          return nil if scope.top_level_def_for(name)
          return nil if ReceiverPredicates.source_declared_method?(scope, "Object", name, :instance)
          return nil if Rigor::Reflection.instance_method_definition("Object", name, scope: scope)
          # Issue #1708 — `main` is an Object, so a `pre_eval:` patch on `Kernel` or `BasicObject` defines the name too.
          return nil if ReceiverPredicates.project_patched_through_ancestors?(scope, "Object", name, :instance)
          return nil if main_singleton_method?(name, scope)
          return nil if Inference::ObjectMixins.may_define?(scope, name, receiver: :implicit)
          # `Target.class_eval { def added = 1; def use_added = added }` files the defs on Target
          # but leaves the eval body with a nil `self_type`, so `toplevel?` still holds. An eval
          # body is morally a class body, so ADR-34 stays silent there — including on a genuinely
          # undefined name inside the block. Ranges are computed once per file.
          return nil if call_inside_receiver_eval_ranges?(eval_ranges, call_node)
          return nil if lexically_declined_toplevel_call?(call_node, scope, lexical_sites, scope_index)

          build_unresolved_toplevel_diagnostic(path, call_node)
        end

        # The `call.unresolved-toplevel` declines that read the file's syntax, asked last because they walk it.
        def lexically_declined_toplevel_call?(call_node, scope, lexical_sites, scope_index = nil)
          # ADR-121 WD7 — a refinement of `Object` (or one Rigor cannot read) in effect here may define the name.
          return true if ReceiverPredicates.refined_method_in_effect?("Object", call_node, scope, :instance,
                                                                      lexical_sites)
          return false if lexical_sites.nil?

          # Issue #1817 — a block handed to a project method that may `module_eval` / `instance_exec` it runs under
          # another `self`, so a call in it is not a top-level one ({RebindingBlockCallees}).
          RebindingBlockCallees.inside_rebound_block?(call_node, scope, lexical_sites.block_calls, scope_index)
        end

        # Issue #1383 — RBS core declares `main`'s private singleton methods on
        # `RBS::Unnamed::TopLevelSelfClass`, so the set follows RBS rather than a hand-kept
        # list. CRuby 4.0's `main` also has `ruby2_keywords`, which RBS does not declare.
        # rbs 3.x has no `TopLevelSelfClass`, so there only `ruby2_keywords` is covered.
        # A call inside a top-level block (`describe do include M end`) is judged here too;
        # silencing it is the cheaper error.
        MAIN_SINGLETON_CLASS_NAME = "RBS::Unnamed::TopLevelSelfClass"
        MAIN_SINGLETON_METHODS_MISSING_FROM_RBS = %i[ruby2_keywords].freeze
        private_constant :MAIN_SINGLETON_CLASS_NAME, :MAIN_SINGLETON_METHODS_MISSING_FROM_RBS

        def main_singleton_method?(name, scope)
          return true if MAIN_SINGLETON_METHODS_MISSING_FROM_RBS.include?(name)
          # `TopLevelSelfClass < Object`: when the project's own RBS broke `Object`, building it would only
          # fail again and report a second, unfixable class name beside `Object` (#696's report).
          return false if Rigor::Reflection.instance_definition("Object", scope: scope).nil?

          !Rigor::Reflection.instance_method_definition(MAIN_SINGLETON_CLASS_NAME, name, scope: scope).nil?
        end

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

        def call_inside_receiver_eval_ranges?(eval_ranges, call_node)
          return false if eval_ranges.nil? || eval_ranges.empty?

          loc = call_node.location
          eval_ranges.any? do |start_offset, end_offset|
            loc.start_offset >= start_offset && loc.end_offset <= end_offset
          end
        end

        def build_unresolved_toplevel_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            path: path,
            message: "unresolved toplevel call to `#{call_node.name}`. " \
                     "If a project file defines `#{call_node.name}` via a toplevel " \
                     "`def` or a monkey-patch on Object/Kernel, list that file in " \
                     "`.rigor.yml`'s `pre_eval:` (ADR-17) so the analyzer sees it.",
            severity: :warning,
            rule: RULE_UNRESOLVED_TOPLEVEL,
            method_name: call_node.name.to_s
          )
        end

        # ADR-24 slice 4 — `call.self-undefined-method`. Consumes the engine's
        # recorded unresolved implicit-self calls
        # ({Analysis::SelfCallResolutionRecorder}) and adds only the
        # closedness POLICY — it NEVER recomputes resolution (the reverted
        # attempt-1 mistake that produced 135 FPs). A miss reaches here only
        # because the engine's real resolution found the method nowhere.
        #
        # The v1 gate is deliberately the most conservative "confidently
        # closed" shape: a STANDALONE project class — no superclass and no
        # `include`/`prepend` (so its in-file method surface is complete) —
        # that is not a module / mixin contract, defines no `method_missing`,
        # has no dynamic `attr_*(*splat)` accessor, and is not an ADR-26 open
        # receiver. Widening to superclass / include chains is a later slice,
        # each behind the external corpus FP gate. Authored `:warning` but
        # mapped to `:off` in every shipped profile until that gate is green
        # (ADR-24 § "Slice 4"); a project opts in via `severity_overrides:`.
        def self_undefined_method_diagnostics(path, self_call_misses, root, scope_index)
          return [] if self_call_misses.empty?

          open_names = SelfClosednessScanner.new(root).open_class_names
          self_call_misses.filter_map do |miss|
            next if open_names.include?(miss.class_name)

            scope = scope_index[miss.node]
            next if scope.nil?
            next unless confidently_closed_self_class?(miss.class_name, scope)
            next if method_defined_on_known_subclass?(miss.class_name, miss.method_name, scope)

            build_self_undefined_method_diagnostic(path, miss)
          end
        end

        # ADR-24 slice 4 — subclass-aware gating (the abstract / template-method
        # base-class false positive the WD4 corpus eval surfaced). A base class
        # legitimately calls a method its subclasses implement
        # (`Mail::CommonField#decoded` calls `do_decode`, which
        # `Mail::UnstructuredField < CommonField` and its siblings define; the
        # same shape covers `Mail::Retriever#find` → POP3 / IMAP). When the
        # missed method is discovered on ANY known subclass of the self-class,
        # the call is a template-method hook, not a typo — suppress. Walks the
        # project subclass closure (the `discovered_superclasses` child→parent
        # map inverted, cycle-guarded). A pure narrowing — it only ever
        # suppresses a firing the closed-class gate would otherwise emit.
        def method_defined_on_known_subclass?(class_name, method_name, scope)
          supers = scope.discovered_superclasses
          seen = {}
          queue = direct_subclasses(class_name, supers)
          until queue.empty?
            subclass = queue.shift
            next if seen[subclass]

            seen[subclass] = true
            return true if method_known_on_class?(subclass, method_name, scope)

            queue.concat(direct_subclasses(subclass, supers))
          end
          false
        end

        # The directly-recorded subclasses of `class_name`. `discovered_superclasses`
        # keys the child fully-qualified (`Mail::POP3`) but records the parent
        # *as written* (`Retriever`), so a qualified miss class (`Mail::Retriever`)
        # is matched by resolving the parent name in the child's namespace.
        def direct_subclasses(class_name, discovered_superclasses)
          discovered_superclasses.filter_map { |child, parent| child if parent_matches?(child, parent, class_name) }
        end

        # Ruby constant lookup: a recorded parent `Retriever` on child
        # `Mail::POP3` resolves to `Mail::Retriever` (walk the child's namespace
        # prefixes, longest first), matched against the miss's fully-qualified
        # class name. Namespace-anchored, so it cannot match a same-named base in
        # an unrelated namespace.
        def parent_matches?(child, parent, class_name)
          parent_name = parent.to_s
          # Issue #722 residue 1 — a rooted parent (`< ::Base`) names the top level, so the namespace walk
          # below must not run for it. This peel is one of the two that predate
          # `Scope#ancestor_name_candidates` and resolve their own pair.
          return parent_name.delete_prefix("::") == class_name if parent_name.start_with?("::")
          return true if parent_name == class_name

          segments = child.to_s.split("::")[0...-1]
          until segments.empty?
            return true if "#{segments.join('::')}::#{parent_name}" == class_name

            segments.pop
          end
          false
        end

        # Whether `method_name` is defined on `class_name` in the project — a
        # plain `def` (the def-node table) or a dynamic definition
        # (`define_method` / `attr_*` / `alias`). `discovered_method?` alone
        # misses plain defs, which is exactly what the abstract hooks are.
        def method_known_on_class?(class_name, method_name, scope)
          !scope.user_def_for(class_name, method_name).nil? ||
            scope.discovered_method?(class_name, method_name, :instance)
        end

        # ADR-24 slice 4 — the universal bases. A recorded self-call miss tagged
        # with one of these means the engine fell back to the root self-type
        # because it could NOT resolve the real class (a class-body macro context
        # where self is the Class object, top-level `main`, `instance_eval`, an
        # FFI / `define_method` metaprogramming surface). Their instance method
        # set is never "project-known and complete" — every object also responds
        # to whatever the unresolved real class adds — so a miss there is a
        # resolution gap, not a typo. This is the dominant false-positive class
        # the WD4 corpus eval surfaced (protobuf 73 / tdiary 199 / pycall 10 /
        # … FFI + class-macro calls, 287 firings across the corpus); excluding
        # it is a pure narrowing.
        SELF_UNDEFINED_UNIVERSAL_BASES = %w[Object BasicObject Kernel].to_set.freeze
        private_constant :SELF_UNDEFINED_UNIVERSAL_BASES

        def confidently_closed_self_class?(class_name, scope)
          return false if SELF_UNDEFINED_UNIVERSAL_BASES.include?(class_name)
          return false if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
          return false if scope.discovered_method?(class_name, :method_missing, :instance)
          # A superclass or mixin extends the surface beyond what this file
          # declares; the engine's ancestor walk may have hit an unresolvable
          # ancestor, so a miss is not provably a typo. Defer to a later slice.
          return false if scope.superclass_of(class_name)
          return false unless scope.includes_of(class_name).empty?

          true
        end

        def build_self_undefined_method_diagnostic(path, miss)
          Diagnostic.new(
            path: path,
            line: miss.line || 1,
            column: miss.column || 1,
            message: "implicit-self call to `#{miss.method_name}` resolves to no method on " \
                     "`#{miss.class_name}` (a standalone class with a complete, project-known " \
                     "method surface). Likely a typo or a missing `def`.",
            severity: :warning,
            rule: RULE_SELF_UNDEFINED_METHOD,
            source_family: :builtin,
            receiver_type: miss.class_name,
            method_name: miss.method_name
          )
        end

        # Slice 7 phase 11 — wrong-arity diagnostic. Fires when
        # an explicit-receiver `Prism::CallNode` resolves to a
        # method whose declared overloads do not admit the
        # supplied positional argument count (across all
        # overloads, see {#compute_arity_envelope}). One overload
        # with required keyword arguments or trailing positionals
        # leaves the whole method unchecked; calls with `*splat`, keyword, or
        # block-pass arguments are silently skipped to avoid
        # false positives. The check piggybacks on the same
        # scope-index lookup used by `undefined_method_diagnostic`;
        # it returns nil when the call's receiver / RBS coverage /
        # call shape disqualifies the rule.
        # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def wrong_arity_diagnostic(path, call_node, facts, lexical_sites = nil)
          return nil if call_node.receiver.nil?
          return nil unless plain_positional_call?(call_node)

          scope = facts.scope
          return nil if scope.nil?

          # ADR-67 WD6b — an inferred-parameter receiver's type is an open-call-site lower bound; a wrong-arity
          # firing against it is an FP by construction. Decline.
          return nil if ReceiverPredicates.inferred_param_receiver?(call_node, scope)

          receiver_type = facts.receiver_type
          class_name = ReceiverPredicates.concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # Issue #879 — the receiver whose surface `call.undefined-method` already refuses to enumerate.
          # Deciding an arity against a declaration this rule cannot prove the receiver actually runs is the
          # same unsoundness in signature form: the includer may declare the name with a wider arity, and
          # then the call is correct code.
          return nil if ReceiverPredicates.unenumerable_receiver_shape?(receiver_type, class_name, scope)

          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          # `Struct.new(:a, :b).new(...)` chained: the inner
          # `Struct.new(...)` is an anonymous Struct *subclass* whose
          # `.new` accepts any positional arity (one slot per member,
          # all defaulting to nil) — including zero. The receiver types
          # as `Singleton[Struct]` (so the call-site `.new` dispatches,
          # per the dispatcher's `struct_new_lift`), but validating that
          # `.new` against the real `Struct.new(*Symbol)` signature is a
          # false positive. Skip arity-checking the chained position.
          return nil if anonymous_struct_new_call?(call_node, class_name, kind)

          arity_envelope = arity_envelope_for(facts, class_name, kind)
          return nil if arity_envelope.nil?

          actual = (call_node.arguments&.arguments || []).size
          min, max, source_arity = arity_envelope
          if actual.between?(min, max)
            source_arity&.settle_by_definitions
            return nil
          end
          return nil if arity_report_withheld?(source_arity, class_name, call_node, scope, kind, lexical_sites)

          build_arity_diagnostic(path, call_node, class_name, min, max, actual)
        end

        # The declines `call.wrong-arity` asks only once the arity is out of the envelope.
        def arity_report_withheld?(source_arity, class_name, call_node, scope, kind, lexical_sites)
          # Issue #992 — a source envelope's remaining declines can only withhold, so they run only now.
          source_arity&.settle_by_walk
          return true if source_arity && !source_arity.authoritative?(class_name)

          ReceiverPredicates.refined_redefinition_in_effect?(class_name, call_node, scope, kind, lexical_sites)
        end

        # The `[min, max]` the call is checked against — a declared signature's, or (issue #992) the project
        # `def`'s own when no signature declares the method, with the {SourceArity} that found it as a third
        # element — or nil when neither may be trusted.
        #
        # Issue #991 — `discovered_method?` used to exempt the call outright before ever asking for a
        # declaration. `trustworthy_signature` is the same lookup `argument_type_diagnostic` treats as
        # authoritative over a source `def` (see its own comment beside that call), and the two rules must agree
        # on whose contract binds, so a declared method is checked against its declaration.
        def arity_envelope_for(facts, class_name, kind)
          receiver_type = facts.receiver_type
          call_node = facts.call_node
          scope = facts.scope
          if Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
            return nil unless ReceiverPredicates.definition_available?(receiver_type, class_name, scope)

            method_def = ReceiverPredicates.receiver_signature(facts)
            if method_def && !Rigor::RbsExtended.inferred_signature?(method_def)
              return nil if undeclared_constructor?(class_name, call_node, kind, method_def)

              return compute_arity_envelope(method_def)
            end
            return nil unless source_lane_open?(method_def, receiver_type, class_name, call_node, scope)
          end

          source_arity_envelope(class_name, call_node, scope, kind)
        end

        # Issue #992 — whether a class RBS knows may still be checked against its project `def`. Two lanes:
        #
        # - the member resolved and carries `%a{rigor:v1:inferred-signature}`: under ADR-93 the bundled
        #   `rigor-rbs-inline` plugin emits a full skeleton for EVERY `def` in a file carrying at least one
        #   annotation (#823), with every type slot defaulted, so nobody asserted anything about it. Its arity
        #   is NOT read here — the `def`'s envelope is, through the same {SourceArity} walk as a method with no
        #   member at all, so one `def` is never judged by two readings of its parameter list;
        # - no member resolved, and the class's declaration is the project's own `sig/`
        #   (`project_declared_class?`): a partial sidecar of a project class whose `def` lives in source.
        #
        # Everything else declines. A bundled declaration (core / stdlib / gem) describes a class the project
        # does not own, so a project `def` on it is an ADR-17 monkey-patch that another library may patch too;
        # a lookup that raised, or a name an open receiver only inherited (`trustworthy_signature` answered
        # nil for those while a raw lookup does not), is not "no member".
        def source_lane_open?(method_def, receiver_type, class_name, call_node, scope)
          return true if method_def

          ReceiverPredicates.lookup_method(receiver_type, class_name, call_node.name, scope).nil? &&
            Rigor::Reflection.project_declared_class?(class_name, scope: scope)
        end

        # Issue #992 — stage 1 of {SourceArity}: the nearest project definition's envelope, after the
        # receiver-level declines that need no walk. Stage 2 (`SourceArity#authoritative?`) runs only once the
        # count is known to fall outside it.
        def source_arity_envelope(class_name, call_node, scope, kind)
          return nil unless scope.discovered_parameter_envelopes.key?(Scope::DiscoveryIndex::ENVELOPE_PROJECT_WIDE)
          return nil if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
          return nil if ReceiverPredicates.plugin_typed_call?(call_node, scope)
          # An instance of a project module is an instance of whatever includes it (#739's reasoning, which
          # `module_mixin_receiver?` can only apply to a module RBS declares).
          return nil if kind == :instance && project_module?(class_name, scope)
          return nil if project_module_class_receiver?(call_node, scope)

          arity = SourceArity.new(scope, call_node.name, kind)
          envelope = arity.owner_envelope(class_name)
          if envelope.nil? || envelope[2]
            envelope.nil? && arity.ambiguous? ? arity.settle_by_walk : arity.settle_by_definitions
            return nil
          end

          [envelope[0], envelope[1] || Float::INFINITY, arity]
        end

        # `self.class.f(1)` inside a project module's instance method: the engine types `self.class` as the
        # module's singleton, but at runtime it is the includer's class, whose class methods are its own. The
        # source-lane twin of {#mixin_self_class_receiver?}, which can only see a module RBS declares.
        def project_module_class_receiver?(call_node, scope)
          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :class && receiver.arguments.nil?
          return false if receiver.receiver.nil?

          inner = ReceiverPredicates.concrete_class_name(scope.type_of(receiver.receiver))
          !inner.nil? && project_module?(inner, scope)
        end

        # Read off the table directly rather than through `Scope#parameter_envelopes_of`: a class does not turn
        # into a module without its declaration (and so the receiver's own typing) changing, so this answer
        # needs no ADR-46 class edge of its own.
        def project_module?(class_name, scope)
          bucket = scope.discovered_parameter_envelopes[class_name.to_s]
          !bucket.nil? && bucket.key?(Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK)
        end

        # Issue #917 — no loaded RBS declares a constructor for this class. The definition builder
        # synthesizes `.new` from the nearest `initialize` in the ancestry, and when nothing declares
        # one that is `BasicObject#initialize: () -> void`, so `.new` derives a nullary envelope that
        # is an artifact of the fallback rather than a statement about the class. `Gem::Specification`
        # is declared in full by the vendored rubygems sigs except for its constructor, and every
        # argument at the real one was reported. The rule needs "this class declares a nullary
        # constructor", and only a `defined_in` naming a class other than `BasicObject` is that
        # evidence — except on `BasicObject` and `Object` themselves, where the declaration is their
        # own and `.new` really does take no arguments.
        def undeclared_constructor?(class_name, call_node, kind, method_def)
          return false unless kind == :singleton && call_node.name == :new
          return false unless method_def.respond_to?(:defined_in)

          defined_in = method_def.defined_in
          return false unless defined_in.nil? || ReceiverPredicates.strip_root(defined_in.to_s) == "BasicObject"

          !%w[BasicObject Object].include?(ReceiverPredicates.strip_root(class_name))
        end

        # True for the outer `.new` of a chained `Struct.new(...).new`:
        # `class_name`/`kind` already pin the receiver to
        # `Singleton[Struct]`, and the receiver node is itself a
        # `Struct.new` (or `::Struct.new`) call — the anonymous subclass.
        def anonymous_struct_new_call?(call_node, class_name, kind)
          return false unless class_name == "Struct" && kind == :singleton
          return false unless call_node.name == :new

          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :new

          inner = receiver.receiver
          return true if inner.is_a?(Prism::ConstantReadNode) && inner.name == :Struct

          # `::Struct.new(...).new` — a top-level constant path.
          inner.is_a?(Prism::ConstantPathNode) && inner.parent.nil? && inner.name == :Struct
        end

        def plain_positional_call?(call_node)
          arguments = call_node.arguments
          return true if arguments.nil?

          arguments.arguments.all? { |arg| simple_positional?(arg) }
        end

        def simple_positional?(arg)
          return false if arg.is_a?(Prism::SplatNode)
          return false if arg.is_a?(Prism::KeywordHashNode)
          return false if arg.is_a?(Prism::BlockArgumentNode)
          return false if arg.is_a?(Prism::ForwardingArgumentsNode)

          true
        end

        # Returns `[min, max]` positional-argument arity for the
        # method (across all overloads), or nil when the rule
        # does not apply. We disqualify only when the method
        # uses required keyword arguments (which the caller MUST
        # pass at the call site, and our plain-positional check
        # would not have caught) or trailing positionals (rare,
        # complex). `optional_keywords` and `rest_keywords` do
        # NOT affect positional arity. `rest_positionals` raises
        # `max` to `Float::INFINITY`.
        def compute_arity_envelope(method_def)
          mins = []
          maxes = []
          method_def.method_types.each do |mt|
            function = mt.type
            return nil unless arity_eligible?(function)

            min_arity = function.required_positionals.size
            max_arity =
              if function.rest_positionals
                Float::INFINITY
              else
                min_arity + function.optional_positionals.size
              end
            mins << min_arity
            maxes << max_arity
          end
          return nil if mins.empty?

          [mins.min, maxes.max]
        end

        def arity_eligible?(function)
          # `RBS::Types::UntypedFunction` (used for `(?) ->`
          # untyped sigs) does not expose the per-arity
          # accessors. Treating it as ineligible is the
          # correct conservative move: an untyped function
          # has no static arity to enforce.
          return false unless function.respond_to?(:required_keywords)

          function.required_keywords.empty? && function.trailing_positionals.empty?
        end

        # Slice 7 phase 14 — nil-receiver diagnostic. Fires when
        # the receiver type is a `Type::Union` containing a
        # nil-bearing member (`Constant[nil]` or
        # `Nominal[NilClass]`) AND the called method does not
        # exist on `NilClass`. This is the canonical "you forgot
        # to nil-check before calling X" signal: the engine has
        # proved that on at least one execution path the receiver
        # is nil, and the call would raise NoMethodError.
        #
        # The rule deliberately ignores receivers that are
        # exactly `Constant[nil]` / `Nominal[NilClass]` (those
        # are already covered by `undefined_method_diagnostic`)
        # and union receivers where every member already
        # disqualifies the call (avoid duplicating the
        # undefined-method diagnostic).
        def nil_receiver_diagnostic(path, call_node, facts, lexical_sites = nil)
          return nil if call_node.receiver.nil?
          # Safe-navigation calls (`recv&.method`) already
          # short-circuit on nil at runtime, so a nil-bearing
          # receiver is not a bug for them.
          return nil if call_node.safe_navigation?
          # Restrict to direct local-variable reads. Local
          # narrowing (Slice 6 phase 1) is the only narrowing
          # surface that can prove a guard like
          # `return if x.nil?` removed nil from the union, so
          # firing on chained / method-call receivers would
          # produce false positives we cannot suppress.
          return nil unless call_node.receiver.is_a?(Prism::LocalVariableReadNode)

          scope = facts.scope
          return nil if scope.nil?

          # ADR-58 WD1 — a receiver whose `nil` constituent is purely
          # declaration-sourced (the class-ivar index seed of a ctor
          # `@x = nil` written in another method, possibly copied into a
          # local via `r = @right`) does not fire by default: the working
          # program's cross-method invariant is assumed per the robustness
          # principle. The nil stays in the displayed type; only its use as
          # diagnostic fuel is withheld. Any flow-live touch (method-local
          # nil write, failed-guard narrowing) drops the mark upstream, so
          # flow-observed nil keeps firing exactly as before. The receiver
          # is already narrowed to a local read above, so this asks
          # {DeclarationSourcedGuard} exactly what it asked before — but it
          # now asks it through the predicate the argument-type gates share
          # (issue #324), which is what keeps the two rules from drifting.
          #
          # Issue #1362 — a local copied from a global still on its declared seed (`sep = $/`) is asked against the
          # file's writes to that global instead: its declared `nil` is withheld, and one the file writes still fires.
          return nil if DeclarationSourcedGuard.withholds_nil?(call_node.receiver, scope)

          # ADR-67 WD6b — an inferred-parameter receiver's type (incl. any nil constituent unioned in from a
          # nil call site) is an open-call-site lower bound; a possible-nil firing against it is an FP by
          # construction. Decline.
          return nil if scope.inferred_param?(call_node.receiver.name)

          receiver_type = facts.receiver_type
          return nil unless receiver_type.is_a?(Type::Union)

          # The rule only fires when the analyzer has access to
          # an RBS loader; without it, the per-member method-
          # presence checks below cannot rule out a sound call.
          return nil unless Rigor::Reflection.rbs_class_known?("NilClass", scope: scope)

          return nil unless nil_bearing_union_witnesses?(receiver_type, call_node.name, scope)
          return nil if nil_receiver_withheld?(call_node, receiver_type, scope, facts.scope_index, lexical_sites)

          build_nil_receiver_diagnostic(path, call_node)
        end

        # The declines `call.possible-nil-receiver` asks only once a report would fire.
        def nil_receiver_withheld?(call_node, receiver_type, scope, scope_index, lexical_sites)
          # Issue #1703 — a `nil` that only a `key?` guard on the same receiver and key rules out. It re-walks the file
          # once with guards on, and only to withhold this report.
          return true if Inference::KeyPresenceGuard.withholds_nil?(call_node, receiver_type, lexical_sites&.root,
                                                                    scope_index)

          # ADR-121 WD7 — a refinement of `NilClass` (or one Rigor cannot read) in effect may define the name.
          ReceiverPredicates.refined_method_in_effect?("NilClass", call_node, scope, :instance, lexical_sites)
        end

        # The receiver-type half of the rule, factored out of the node-shape
        # guards above: the union must carry nil, must carry a non-nil arm the
        # presence question can be asked of, must support the method on every
        # non-nil arm (so the call is only wrong on the nil path), and the
        # method must be absent from `NilClass` (so the nil path really raises).
        def nil_bearing_union_witnesses?(receiver_type, method_name, scope)
          union_contains_nil?(receiver_type) &&
            union_has_nameable_non_nil_arm?(receiver_type, scope) &&
            union_method_present_on_non_nil?(receiver_type, method_name, scope) &&
            !nil_class_has_method?(method_name, scope)
        end

        def union_contains_nil?(union)
          union.members.any? { |member| ReceiverPredicates.nil_member?(member) }
        end

        # Possible-nil may witness only where the presence question below is
        # ANSWERABLE. `method_present_anywhere?` reports "present" for a
        # nameless arm (Dynamic / Top / Bot) — the permissive polarity the
        # union-undefined-method rule's FP safety rests on — so a union whose
        # non-nil arms are ALL nameless satisfied that gate vacuously and fired
        # on every method name, including names defined on no class anywhere.
        # That inverted the intent: the gate suppressed exactly where knowledge
        # exists (`String | nil` calling a nonexistent method stays silent) and
        # permitted exactly where none does. Requiring one nameable concrete
        # arm restores the polarity without touching the shared helper:
        # `String | nil` keeps firing, and so does `Dynamic | String | nil` —
        # the nameless arm stays permissive inside the all-arms check, which is
        # only about the arms' method surface. That union no longer arises from
        # a merge re-joining the narrowed edges of one untyped local, which
        # binds it back to `Dynamic[top]` (issue #1840,
        # `Inference::UntypedRejoin`); it still does when the program writes
        # the `nil` (`x = nil if c`) and no `nil?` edge strips it before the
        # re-joining merge, or when the arms are not a narrowing of one
        # untyped value.
        def union_has_nameable_non_nil_arm?(union, scope)
          union.members.any? do |m|
            next false if ReceiverPredicates.nil_member?(m)

            class_name = ReceiverPredicates.concrete_class_name(m)
            next false if class_name.nil?

            # Issue #574 — nameable is not the same as ANSWERABLE. `method_present_anywhere?` reports
            # "present" for a named arm nothing knows the surface of, purely because nothing is known —
            # which is the same vacuity this gate's docstring says it exists to prevent, one level in. A
            # plugin-minted nominal like `ActionController::Parameters` ships no RBS and has no project
            # source, so it counted as a full witness and `q = params[:q]; q.strip` fired at ERROR severity
            # on correct Rails code.
            Rigor::Reflection.rbs_class_known?(class_name, scope: scope) ||
              scope.discovered_classes.key?(class_name)
          end
        end

        # The non-nil members must collectively support the
        # method (i.e. for every non-nil member, the method
        # exists on its class via RBS or in-source discovery).
        # Without this guard, the rule would also fire on calls
        # that are unsound on the non-nil branch — that is the
        # `undefined_method_diagnostic` rule's job, and we want
        # exactly one diagnostic per offending call site.
        def union_method_present_on_non_nil?(union, method_name, scope)
          non_nil_members = union.members.reject { |m| ReceiverPredicates.nil_member?(m) }
          return false if non_nil_members.empty?

          non_nil_members.all? { |m| ReceiverPredicates.method_present_anywhere?(m, method_name, scope) }
        end

        def nil_class_has_method?(method_name, scope)
          definition = Rigor::Reflection.instance_definition("NilClass", scope: scope)
          return false if definition.nil?

          !definition.methods[method_name.to_sym].nil?
        end

        # Slice 7 phase 19 — PHPStan-style `dump_type(value)`. When the engine recognises a call to
        # `dump_type` (with any of the supported receiver shapes — implicit self after `include
        # Rigor::Testing`, `Rigor::Testing.dump_type`, or `Rigor.dump_type`), it emits an `:info` diagnostic
        # showing the inferred type of the argument expression. The diagnostic does NOT count toward
        # `Result#error_count` so a fixture peppered with `dump_type` calls still passes `rigor check`.
        def dump_type_diagnostic(path, call_node, scope_index)
          return nil unless rigor_testing_call?(call_node, :dump_type)
          return nil if call_node.arguments.nil? || call_node.arguments.arguments.empty?

          arg = call_node.arguments.arguments.first
          scope = scope_index[arg] || scope_index[call_node]
          return nil if scope.nil?
          return nil if inside_rigor_testing?(scope)

          type = scope.type_of(arg)
          Diagnostic.from_message_loc(
            call_node,
            path: path,
            message: "dump_type: #{type.describe(:short)}",
            severity: :info,
            rule: RULE_DUMP_TYPE
          )
        end

        # Slice 7 phase 19 — PHPStan-style `assert_type("...", value)`. The first argument MUST be a
        # string literal containing the expected `Type#describe(:short)` rendering. When the inferred
        # type's short description does not equal the expected literal, an `:error`-severity diagnostic is
        # emitted; matching calls produce no output. This lets a fixture document its expected types
        # inline: subsequent `rigor check` runs flag any drift.
        def assert_type_diagnostic(path, call_node, scope_index)
          return nil unless rigor_testing_call?(call_node, :assert_type)
          return nil if call_node.arguments.nil? || call_node.arguments.arguments.size < 2

          expected_node = call_node.arguments.arguments.first
          return nil unless expected_node.is_a?(Prism::StringNode)

          value_node = call_node.arguments.arguments[1]
          scope = scope_index[value_node] || scope_index[call_node]
          return nil if scope.nil?
          return nil if inside_rigor_testing?(scope)

          actual = scope.type_of(value_node).describe(:short)
          expected = expected_node.unescaped.to_s
          return nil if actual == expected

          build_assert_type_diagnostic(path, call_node, expected, actual)
        end

        # Recognises any of:
        #   `dump_type(x)`        (implicit self after `include Rigor::Testing`)
        #   `Testing.dump_type(x)`
        #   `Rigor.dump_type(x)`
        #   `Rigor::Testing.dump_type(x)`
        # The receiver check is purely structural — we do not consult RBS — because the helpers are no-op
        # stubs the user MAY shadow with their own definition; a name clash is the deliberate trade-off for
        # ergonomic invocation.
        RIGOR_TESTING_RECEIVERS = ["Rigor", "Rigor::Testing", "Testing"].freeze
        private_constant :RIGOR_TESTING_RECEIVERS

        # The dump/assert helpers' own implementation methods call back into `Testing.dump_type` /
        # `assert_type` to share the no-op runtime stub. We do NOT want those internal calls to surface
        # diagnostics — they are reflexive plumbing, not user assertions. This filter skips diagnostics
        # when the call site's `self_type` is the `Rigor` or `Rigor::Testing` module itself.
        SELF_REFERENTIAL_SCOPES = ["Rigor", "Rigor::Testing"].freeze
        private_constant :SELF_REFERENTIAL_SCOPES

        def inside_rigor_testing?(scope)
          self_type = scope.self_type
          return false if self_type.nil?
          return false unless self_type.respond_to?(:class_name)

          SELF_REFERENTIAL_SCOPES.include?(self_type.class_name)
        end

        def rigor_testing_call?(call_node, method_name)
          return false unless call_node.name == method_name

          receiver = call_node.receiver
          return true if receiver.nil?

          name = Source::ConstantPath.qualified_name_or_nil(receiver)
          return false if name.nil?

          RIGOR_TESTING_RECEIVERS.include?(name)
        end

        def build_assert_type_diagnostic(path, call_node, expected, actual)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_ASSERT_TYPE,
            path: path,
            message: "assert_type mismatch: expected #{expected.inspect}, got #{actual.inspect}",
            severity: :error
          )
        end

        def build_nil_receiver_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_NIL_RECEIVER,
            path: path,
            message: "possible nil receiver: `#{call_node.name}' is undefined on NilClass",
            severity: :error,
            method_name: call_node.name.to_s
          )
        end

        # Diagnoses calls that the analyzer can prove will always raise. Today the only triggering shape is
        # integer division/modulo by a literal zero divisor:
        #
        #   5 / 0          # => ZeroDivisionError
        #   x.modulo(0)    # => ZeroDivisionError when x: Integer
        #   xs.size % 0    # same — non_negative_int / Constant[0]
        #
        # Float divmod by zero returns Infinity/NaN at runtime, so the rule restricts to Integer-rooted
        # receivers (`Constant`, `IntegerRange`, `Nominal[Integer]`). The argument MUST be a
        # `Constant<Integer>` whose value is exactly zero — a `Union[Constant[0], Constant[2]]` divisor
        # "may" raise, which we surface separately (future slice).
        INTEGER_RAISING_OPERATORS = %i[/ % div modulo divmod].freeze
        private_constant :INTEGER_RAISING_OPERATORS

        def always_raises_diagnostic(path, call_node, facts, lexical_sites = nil, raise_shield = nil)
          return nil unless integer_zero_division?(call_node, facts)

          # ADR-121 WD7 — a refinement of `Integer`'s operator (or one Rigor cannot read) in effect may not raise.
          return nil if ReceiverPredicates.refined_method_in_effect?("Integer", call_node, facts.scope, :instance,
                                                                     lexical_sites)

          # Issue #3036 — a raise an enclosing `begin` / `def … rescue` catches flows to the handler.
          return nil if raise_shield&.rescued?(call_node, facts.scope)

          build_always_raises_diagnostic(path, call_node)
        end

        def integer_zero_division?(call_node, facts)
          return false unless raising_call_shape?(call_node)

          scope = facts.scope
          return false if scope.nil?
          return false unless integer_rooted_for_diagnostic?(facts.receiver_type)

          arg = single_argument(call_node)
          arg && integer_zero_constant?(scope.type_of(arg))
        end

        def raising_call_shape?(call_node)
          !call_node.receiver.nil? && INTEGER_RAISING_OPERATORS.include?(call_node.name)
        end

        def single_argument(call_node)
          args = call_node.arguments&.arguments || []
          args.size == 1 ? args.first : nil
        end

        def integer_rooted_for_diagnostic?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then type.class_name == "Integer" && type.type_args.empty?
          else false
          end
        end

        def integer_zero_constant?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Integer) && type.value.zero?
        end

        def build_always_raises_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_ALWAYS_RAISES,
            path: path,
            message: "always raises ZeroDivisionError: `#{call_node.name}' by zero on Integer receiver",
            severity: :error
          )
        end

        # `call.raise-non-exception` — `raise x` / `fail x` where the first argument's statically-inferred
        # type is provably NOT a legal raise operand (PHPStan ThrowExprTypeRule analogue). Legal operands:
        # an Exception class object, an Exception instance, a String (raises RuntimeError), or any object
        # whose class defines `#exception` (the duck protocol `raise` consults at runtime). Anything else
        # (`raise 42`, `raise :sym`, `raise nil` — an explicit nil argument is a TypeError, unlike bare
        # `raise` which re-raises `$!`) raises TypeError at runtime.
        #
        # Conservative envelope (FP discipline):
        # - Implicit-self `raise` / `fail` only; an explicit-receiver call is a user method, not Kernel#raise.
        # - Silent when the project redefines `raise` / `fail` anywhere the call could resolve (a same-file
        #   toplevel def, an Object/Kernel monkey-patch, or a def on the enclosing class — in source or via
        #   `pre_eval:`).
        # - Only the first positional argument is checked; splat / kwargs / forwarded first args bail.
        # - Fires only on a concrete verdict: Dynamic / Top / unknown / unresolved types are silent, and a
        #   Union fires only when EVERY arm is independently illegal.
        # - A Class operand (`Type::Singleton`) is exact, so both `:disjoint` and `:superclass` orderings
        #   against Exception are provably illegal — but only when the class is RBS-known, not an ADR-26
        #   open receiver / synthesized stub, and its singleton defines no `exception` method.
        # - An instance operand's nominal class is NOT exact (a runtime subclass could define `#exception`
        #   or be an Exception), so only `:disjoint` fires, and the generic carriers (`Class` / `Module` /
        #   `Object` / `BasicObject`) plus module-typed values (any includer could be an Exception) bail.
        RAISE_METHOD_NAMES = %i[raise fail].freeze
        private_constant :RAISE_METHOD_NAMES

        # Instance types whose nominal class subsumes exception values (or class objects), so a "disjoint
        # from Exception" ordering proves nothing about the runtime value. `Object` / `BasicObject` order as
        # `:superclass` (already silent) but are listed for explicitness.
        RAISE_UNEXACT_INSTANCE_CLASSES = %w[Class Module Object BasicObject].freeze
        private_constant :RAISE_UNEXACT_INSTANCE_CLASSES

        def raise_non_exception_diagnostic(path, call_node, scope_index)
          return nil unless call_node.receiver.nil?
          return nil unless RAISE_METHOD_NAMES.include?(call_node.name)
          return nil unless call_node.block.nil?

          arg = first_positional_raise_operand(call_node)
          return nil if arg.nil?

          scope = scope_index[arg] || scope_index[call_node]
          return nil if scope.nil?
          return nil if raise_redefined_in_scope?(scope, call_node.name)

          operand_type = scope.type_of(arg)
          return nil unless raise_operand_verdict(operand_type, scope) == :illegal

          build_raise_non_exception_diagnostic(path, call_node, operand_type)
        end

        def first_positional_raise_operand(call_node)
          args = call_node.arguments&.arguments
          return nil if args.nil? || args.empty?

          first = args.first
          return nil if first.is_a?(Prism::SplatNode) || first.is_a?(Prism::KeywordHashNode) ||
                        first.is_a?(Prism::BlockArgumentNode) || first.is_a?(Prism::ForwardingArgumentsNode)

          first
        end

        # True when a project-side definition of `raise` / `fail` could shadow Kernel's at this call site:
        # a same-file toplevel def, a monkey-patch on Object / Kernel (in source or `pre_eval:`), or a def
        # on the enclosing class (instance or singleton side — implicit self dispatches to either depending
        # on context, and being silent for both is the cheap conservative answer).
        def raise_redefined_in_scope?(scope, name)
          return true if scope.top_level_def_for(name)
          return true if ReceiverPredicates.source_declared_method?(scope, "Object", name, :instance)
          return true if ReceiverPredicates.source_declared_method?(scope, "Kernel", name, :instance)

          self_type = scope.self_type
          return false unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name
          return false if class_name.nil?

          ReceiverPredicates.source_declared_method?(scope, class_name, name, :instance) ||
            ReceiverPredicates.source_declared_method?(scope, class_name, name, :singleton)
        end

        # Trinary verdict — `:legal` / `:illegal` / `:unknown`. Only `:illegal` fires; anything the engine
        # cannot prove stays `:unknown` (silent).
        def raise_operand_verdict(type, scope)
          case type
          when Type::Union
            verdicts = type.members.map { |member| raise_operand_verdict(member, scope) }
            return :illegal if verdicts.all?(:illegal)

            verdicts.all?(:legal) ? :legal : :unknown
          when Type::Singleton
            raise_class_operand_verdict(type.class_name, scope)
          else
            raise_instance_operand_verdict(type, scope)
          end
        end

        # A `Type::Singleton` names ONE exact class / module object, so an ordering that places it outside
        # Exception's ancestry (`:disjoint`, or `:superclass` — e.g. `raise Object`) is a proof, provided
        # the singleton also lacks an `exception` method (`raise Klass` calls `Klass.exception`). A module
        # constant orders `:disjoint` and fires unless its singleton defines `exception`.
        def raise_class_operand_verdict(class_name, scope)
          return :unknown if class_name.nil? || scope.environment.nil?
          return :unknown if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
          return :unknown if Rigor::Reflection.discovered_class?(class_name, scope: scope)
          return :unknown unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          case Rigor::Reflection.class_ordering(class_name, "Exception", scope: scope)
          when :equal, :subclass then :legal
          when :superclass, :disjoint
            raise_duck_exception?(class_name, :singleton, scope) ? :legal : :illegal
          else
            :unknown
          end
        end

        # An instance operand: legal when its class is String-family (raises RuntimeError) or an Exception
        # descendant; illegal only when the class is fully known, exact enough (not a generic metaclass /
        # module carrier), provably disjoint from BOTH, and defines no `#exception`. `:superclass` stays
        # silent — a value typed `Object` may well BE an Exception at runtime.
        def raise_instance_operand_verdict(type, scope)
          class_name = ReceiverPredicates.concrete_class_name(type)
          return :unknown if class_name.nil? || scope.environment.nil?
          return :unknown if RAISE_UNEXACT_INSTANCE_CLASSES.include?(class_name)
          return :unknown if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
          # A project-declared class's ancestry must not be proven from RBS alone: a `sig/` declaration that
          # omits the superclass (`class Conflict` for a source-side `class Conflict < StandardError`)
          # defaults to Object in the RBS env, which would read as "disjoint from Exception" for a class
          # that IS one at runtime (the rule's first self-check firing, `Plugin::FactStore::Conflict`).
          # Source-discovered classes stay silent.
          return :unknown if Rigor::Reflection.discovered_class?(class_name, scope: scope)
          return :unknown unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return :unknown if scope.environment.rbs_module?(class_name)

          string_ordering = Rigor::Reflection.class_ordering(class_name, "String", scope: scope)
          return :legal if %i[equal subclass].include?(string_ordering)

          case Rigor::Reflection.class_ordering(class_name, "Exception", scope: scope)
          when :equal, :subclass then :legal
          when :disjoint
            raise_duck_exception?(class_name, :instance, scope) ? :legal : :illegal
          else
            :unknown
          end
        end

        # Whether the class carries an `exception` method on the given side — from RBS, an in-source `def`,
        # or a `pre_eval:` patch. An unbuildable definition returns true (assume the duck) so structural
        # RBS gaps never manufacture a firing.
        def raise_duck_exception?(class_name, kind, scope)
          return true if ReceiverPredicates.source_declared_method?(scope, class_name, :exception, kind)

          definition = if kind == :singleton
                         Rigor::Reflection.singleton_definition(class_name, scope: scope)
                       else
                         Rigor::Reflection.instance_definition(class_name, scope: scope)
                       end
          return true if definition.nil?

          !definition.methods[:exception].nil?
        end

        def build_raise_non_exception_diagnostic(path, call_node, operand_type)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_RAISE_NON_EXCEPTION,
            path: path,
            message: "`#{call_node.name}' operand types as #{operand_type.describe(:short)}, which is not " \
                     "an Exception class, an Exception instance, a String, or an object defining " \
                     "`#exception' — this raises TypeError at runtime",
            severity: :error,
            method_name: call_node.name.to_s
          )
        end

        # Issue #1367 (ADR-117 Decision point 1, WD2) — `global.write-type-mismatch` and `global.readonly-write`: a
        # write to a special global that the interpreter's setter rejects, so the write raises every time it runs.
        # The envelope is {SpecialGlobalSetters}: the setter, not the global's RBS declaration.
        #
        # - `global.readonly-write` needs no type. `$g = v`, `$g op= v` and a target of a multiple assignment
        #   (`$g, x = …`, `*$g`) always write, so a write to a read-only special raises.
        # - `global.write-type-mismatch` checks `$g = v` only when `v` is a literal node
        #   ({SpecialGlobalSetters.literal_class}), whose class the syntax fixes. Any other value is never reported,
        #   whatever its inferred type: a class RBS declares without `write` or `to_str` does not prove the object
        #   lacks it (a singleton `def`, an `extend`, or a run-time `alias to_str to_s`, as URI has).
        # - `$g ||= v` and `$g &&= v` write only when the current value is falsy (truthy), so neither rule checks
        #   them, nor a `for` index or a `rescue => $g` reference.
        # - A special that any project file aliases (`alias $stdout $out`, either side) is exempt from both.
        def special_global_write_diagnostics(path, node, scope_index, lexical_sites)
          case node
          when Prism::GlobalVariableWriteNode
            [readonly_global_write_diagnostic(path, node, scope_index) ||
              global_write_type_diagnostic(path, node, scope_index, lexical_sites)].compact
          when Prism::GlobalVariableOperatorWriteNode
            [readonly_global_write_diagnostic(path, node, scope_index)].compact
          when Prism::MultiWriteNode
            multi_write_global_targets(node).filter_map do |target|
              readonly_global_write_diagnostic(path, target, scope_index)
            end
          else
            []
          end
        end

        # The `GlobalVariableTargetNode`s a multiple assignment writes, through a splat (`*$g`) and nested
        # destructuring (`(a, $g), b = …`).
        def multi_write_global_targets(node)
          [*node.lefts, node.rest, *node.rights].flat_map do |target|
            case target
            when Prism::GlobalVariableTargetNode then [target]
            when Prism::SplatNode
              target.expression.is_a?(Prism::GlobalVariableTargetNode) ? [target.expression] : []
            when Prism::MultiTargetNode then multi_write_global_targets(target)
            else []
            end
          end
        end

        def readonly_global_write_diagnostic(path, node, scope_index)
          return nil unless SpecialGlobalSetters.read_only?(node.name)

          scope = scope_index[node]
          return nil if scope.nil? || global_aliased?(scope, node.name)

          location = node.respond_to?(:name_loc) ? node.name_loc : node.location
          Diagnostic.from_location(
            location,
            rule: RULE_GLOBAL_READONLY_WRITE,
            path: path,
            message: "`#{node.name}' is a read-only variable; this write raises NameError at runtime",
            severity: :error
          )
        end

        def global_write_type_diagnostic(path, node, scope_index, lexical_sites)
          contract = SpecialGlobalSetters.contract_for(node.name)
          return nil if contract.nil?

          class_name = SpecialGlobalSetters.literal_class(node.value)
          return nil if class_name.nil?

          scope = scope_index[node]
          return nil if scope.nil?
          return nil unless literal_rejected?(class_name, contract, node, scope, lexical_sites)
          return nil if global_aliased?(scope, node.name)

          build_global_write_type_diagnostic(path, node, contract, class_name)
        end

        # The project's {Inference::GlobalWriteCensus} with the `pre_eval:` files' own.
        def global_write_census(scope)
          census = scope.discovered_global_write_census
          pre_eval = scope.environment&.project_patched_methods&.write_census
          pre_eval.nil? || pre_eval.empty? ? census : census | pre_eval
        end

        # Whether any project or `pre_eval:` file aliases `name`, on either side, which can make it another variable.
        def global_aliased?(scope, name)
          record_global_census(Inference::GlobalWriteCensus.alias_entry(name))
          Inference::GlobalWriteCensus.aliased?(global_write_census(scope), name)
        end

        # Issue #2158 — a read of the whole-program census records the `global_census:` key of each entry it asks
        # about ({Inference::GlobalWriteCensus.dependency_key}): a file that starts or stops writing the entry (a `def
        # write`, an `alias $stdout $x`, a computed `define_method`) re-checks the write. A `pre_eval:` file moves the
        # snapshot's own fingerprint.
        def record_global_census(*entries)
          return unless DependencyRecorder.active?

          entries.each do |entry|
            DependencyRecorder.read_name(:global_census, Inference::GlobalWriteCensus.dependency_key(entry))
          end
        end

        # Whether the census holds any of `entries`, recording only what can flip the answer: the entries present
        # when it holds one (the answer stays true until every one of them vanishes, and another appearing changes
        # nothing), every entry when it holds none.
        #
        # This rests on an invariant: every census entry can only move a write toward being silenced, and a reported
        # write is always re-checked through `IncrementalSession#global_write_reporters`, so recording only the
        # present entries on a yes is sound. A future census entry that makes a write reported would break it, and
        # its reader would have to record every entry. Recording every entry on a no is defence in depth, since the
        # write that answer leaves reported re-checks through `global_write_reporters` anyway.
        def census_holds_any?(census, entries)
          present = entries.select { |entry| census.include?(entry) }
          record_global_census(*(present.empty? ? entries : present))
          !present.empty?
        end

        # A literal is rejected when its class is none the setter takes and, for a setter that also converts
        # (`to_str`, `to_int`) or asks for `write`, the literal's object cannot answer that method.
        def literal_rejected?(class_name, contract, node, scope, lexical_sites)
          return false if contract.accepts_class?(class_name)
          return true if contract.conversion.nil?

          !literal_may_answer?(class_name, contract.conversion, node, scope, lexical_sites)
        end

        # The escape hatches through which an object answers a method its class does not define: the setter's
        # `respond_to?` and implicit conversion both consult them.
        GLOBAL_WRITE_HATCHES = %i[method_missing respond_to_missing? respond_to?].freeze
        private_constant :GLOBAL_WRITE_HATCHES

        # Where RBS core declares the hatches every object inherits unchanged.
        DEFAULT_HATCH_OWNERS = %w[::BasicObject ::Kernel ::Object].freeze
        private_constant :DEFAULT_HATCH_OWNERS

        # Whether the literal's object may answer `method_name` after all:
        #
        # - RBS gives its class the method, or a hatch of its own (a project `sig/` reopening or `include` counts);
        # - the program defines the method or a hatch anywhere, in any spelling, on any receiver
        #   ({Inference::GlobalWriteCensus}): no census of where a definition lands can be complete
        #   (`class << nil`, `K = Integer; class K`, `[Integer].each { |k| k.define_method(:write) }`);
        # - an ancestor's surface is rewritten from outside (`Integer.include(M)`, `Object.include(M)`, a string
        #   `class_eval`: the `ENVELOPE_DYNAMIC_MARK`), or it or `Object` mixes in a module RBS does not rule out;
        # - for `write` only, a refinement that may add it is in effect at the write ({#refined_writer_in_effect?}).
        def literal_may_answer?(class_name, method_name, node, scope, lexical_sites)
          definition = Rigor::Reflection.instance_definition(class_name, scope: scope)
          return true if definition.nil?
          return true if definition.methods.key?(method_name) || overridden_hatch?(definition)

          ancestors = definition.ancestors.ancestors.to_set { |ancestor| ancestor.name.to_s.delete_prefix("::") }
          names = [method_name, *GLOBAL_WRITE_HATCHES]
          census = global_write_census(scope)
          program_may_answer?(ancestors, names, census, scope) ||
            (method_name == :write && refined_writer_in_effect?(census, node, scope, lexical_sites))
        end

        def overridden_hatch?(definition)
          GLOBAL_WRITE_HATCHES.any? do |name|
            method = definition.methods[name]
            method && !DEFAULT_HATCH_OWNERS.include?(method.defined_in.to_s)
          end
        end

        def program_may_answer?(ancestors, names, census, scope)
          defines = [Inference::GlobalWriteCensus::DEFINES_ANY, *names.map { |name| [:defines, name] }]
          return true if census_holds_any?(census, defines)

          dynamic_mark = Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK
          return true if ancestors.any? { |owner| scope.parameter_envelopes_of(owner).key?(dynamic_mark) }

          # One key for every top-level mixin, a deliberate trade-off: the reader asks about each, so a mixin
          # appearing or vanishing anywhere re-checks every write that reached this step.
          record_global_census(%i[main_mixin *])
          main_mixins = Inference::GlobalWriteCensus.main_mixins(census)
          main_mixins.any? { |mixin| rbs_mixin_may_answer?(mixin, names, scope) } ||
            mixin_may_answer?(ancestors, names, scope)
        end

        # A module an ancestor of the literal's class mixes in through a class body (`class Integer; include
        # Writable; end`), followed through the modules it mixes in in turn. A project module answers when its
        # surface is rewritten beyond literal names (a `send(:include, …)`, a non-constant mixin); its literal
        # definitions are the census's. Any other module answers when RBS does not know it or declares one of
        # `names`.
        def mixin_may_answer?(ancestors, names, scope)
          queue = ancestors.flat_map { |owner| scope.includes_of(owner) }
          seen = Set.new
          until queue.empty?
            mixin = queue.shift
            next unless seen.add?(mixin)

            bucket = scope.parameter_envelopes_of(mixin)
            if bucket.key?(Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK)
              return true if bucket.key?(Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)

              queue.concat(scope.includes_of(mixin))
            elsif rbs_mixin_may_answer?(mixin, names, scope)
              return true
            end
          end
          false
        end

        def rbs_mixin_may_answer?(mixin, names, scope)
          definition = Rigor::Reflection.instance_definition(mixin, scope: scope)
          definition.nil? || definition.methods.key?(names.first) || overridden_hatch?(definition)
        end

        # For `write` only: some refinement may add `write` (a `def`, `define_method` or `alias_method` in a `refine`
        # block, or an `import_methods`), and a `using` is in effect at the write. Which class it refines is not asked:
        # the target may be computed (`[Array].each { |k| refine(k) { … } }`) or a constant alias (`T = Array;
        # refine(T)`), so a refined `write` on any class declines every literal. `respond_to?(:write)` honours an
        # active refinement on Ruby 4.0.5; a refined `respond_to_missing?` or `respond_to?`, and every implicit
        # conversion, do not, so a refinement that adds only those leaves the write reported.
        def refined_writer_in_effect?(census, node, scope, lexical_sites)
          census_holds_any?(census, [Inference::GlobalWriteCensus::REFINES_ANY, %i[refines write]]) &&
            (lexical_sites.nil? || !scope.declared_refinements.empty? ||
              lexical_sites.refinements.any_at?(node.location.start_offset))
        end

        def build_global_write_type_diagnostic(path, node, contract, class_name)
          Diagnostic.from_name_loc(
            node,
            rule: RULE_GLOBAL_WRITE_TYPE_MISMATCH,
            path: path,
            message: "`#{node.name}' accepts only #{contract.accepts}; this write assigns " \
                     "#{SpecialGlobalSetters.literal_description(class_name)}, which raises TypeError at runtime",
            severity: :error
          )
        end

        # v0.1.2 — `flow.unreachable-branch`. Fires when an `IfNode` / `UnlessNode` whose predicate is a
        # literal `true` / `false` / `nil` (or a literal numeric / string / symbol whose Ruby truthiness is
        # known at-a-glance) has an observable dead branch. The diagnostic points at the dead branch (not
        # the predicate) so the squiggle lands on the code that never runs.
        #
        # Conservative envelope — by deliberate v0.1.2 design:
        # - Only **literal-shaped** predicates fire. Inferred-constant predicates (`x.method?` that happens
        #   to fold to `Constant<bool>`) are intentionally skipped — Rigor's loop / mutation /
        #   RBS-strictness modelling is incomplete enough that an inferred constant can be a false positive
        #   (e.g. accumulator `arr << x` doesn't widen the carrier; defensive `module.name.nil?` checks
        #   against anonymous-class nil that the RBS `Module#name -> String` sig hides). The literal-only
        #   envelope captures the clear "user wrote `if false`" case without false alarms.
        # - Empty dead branches (e.g. `if false; end` with no body) are skipped — there is no useful
        #   location to point at.
        # - Postfix-`if` / `unless` modifiers with a literal predicate ARE flagged (`expr if false` body
        #   never runs, exactly like the block form).
        # - Elsif chains (`subsequent` is itself an `IfNode`) ARE flagged — the entire downstream chain is
        #   unreachable when the outer predicate is a constant literal.
        #
        # Inferred-constant predicates are the `flow.always-truthy-condition` rule's ({AlwaysTruthyConditionCollector}).
        def unreachable_branch_diagnostic(path, node, scope_index)
          scope = scope_index[node]
          return nil if scope.nil?

          polarity = literal_predicate_polarity(node.predicate)
          return nil if polarity.nil?

          dead_branch = unreachable_branch_for(node, polarity == :truthy)
          return nil if dead_branch.nil?

          build_unreachable_branch_diagnostic(path, dead_branch, polarity)
        end

        TRUTHY_LITERAL_NODES = [
          Prism::TrueNode, Prism::IntegerNode, Prism::FloatNode,
          Prism::StringNode, Prism::SymbolNode, Prism::RegularExpressionNode
        ].freeze
        private_constant :TRUTHY_LITERAL_NODES

        FALSEY_LITERAL_NODES = [Prism::FalseNode, Prism::NilNode].freeze
        private_constant :FALSEY_LITERAL_NODES

        # Returns `:truthy` / `:falsey` for a syntactically-literal predicate, or nil for anything else.
        # `TrueNode`, `FalseNode`, `NilNode` are the unambiguous cases. Numeric / string / symbol literals
        # are always truthy in Ruby (any non-`false` / non-`nil` value is truthy, including `0` and `""`).
        def literal_predicate_polarity(predicate)
          return :truthy if TRUTHY_LITERAL_NODES.any? { |klass| predicate.is_a?(klass) }
          return :falsey if FALSEY_LITERAL_NODES.any? { |klass| predicate.is_a?(klass) }

          nil
        end

        # v0.1.2 — `def.method-visibility-mismatch`. Fires when an explicit-receiver `Prism::CallNode`
        # targets a user-class method whose `discovered_method_visibilities` entry is `:private`. The rule
        # is intentionally narrow:
        #
        # - Only `:private`. `:protected` access depends on subclass tracking the engine does not yet
        #   model; broadening waits for that surface.
        # - Only user classes whose visibility table the indexer built. RBS-known classes (stdlib, gems)
        #   are NOT consulted yet — RBS visibility is reliable but surfacing it would broaden the rule to a
        #   level the per-rule false-positive triage hasn't covered.
        # - Implicit-self calls are skipped (always allowed for private). Calls whose receiver is
        #   `Prism::SelfNode` are also skipped — Ruby 2.7+ permits `self.foo` for private methods.
        # - Receiver MUST resolve to a `Type::Nominal` so the rule has a single class identity to query.
        #   Unions / Dynamic / shape carriers are skipped.
        # - Issue #1568 — a module the class PREPENDS sits ahead of it in Ruby's order, so a definition there
        #   is what the call reaches; the class's own private `def` answers only when nothing prepended
        #   defines the name ({#reached_definer_visibility}).
        # - Issue #1984 — a class-object receiver (`Type::Singleton`, `K.x`) is checked against the singleton side:
        #   the definition the call reaches on `K`'s singleton chain (its own singleton methods, its extended
        #   modules' instance methods, then the superclass's singleton chain) must be recorded `:private`
        #   (`private_class_method`, `class << self` with `private`, a private method of an extended module).
        # - Issue #1984 — Ruby hands a private call to `method_missing`, so a `method_missing` or
        #   `respond_to_missing?` a project entry on the receiver's chain records, on the side the call reaches,
        #   declines the rule ({#missing_hook_on_chain?}).
        def visibility_mismatch_diagnostic(path, call_node, facts, lexical_sites = nil)
          return nil unless explicit_non_self_receiver?(call_node.receiver)

          scope = facts.scope
          return nil if scope.nil?

          # ADR-67 WD6b — an inferred-parameter receiver's nominal type is an open-call-site lower bound; a
          # private-method visibility firing against it is an FP by construction. Decline.
          return nil if ReceiverPredicates.inferred_param_receiver?(call_node, scope)

          receiver_type = facts.receiver_type
          case receiver_type
          when Type::Nominal then instance_visibility_mismatch(path, call_node, scope, receiver_type, lexical_sites)
          when Type::Singleton then singleton_visibility_mismatch(path, call_node, scope, receiver_type, lexical_sites)
          end
        end

        def instance_visibility_mismatch(path, call_node, scope, receiver_type, lexical_sites)
          visibility = scope.discovered_method_visibility(receiver_type.class_name, call_node.name)
          return nil unless visibility == :private

          reached = reached_definer_visibility(scope, receiver_type.class_name, call_node.name)
          return nil if reached == :undecided
          return nil unless reached.nil? || reached == :private
          return nil if missing_hook_on_chain?(scope, receiver_type.class_name, :instance)
          # ADR-121 WD7 — a refinement in effect (or one Rigor cannot read) may redefine the method, public.
          return nil if ReceiverPredicates.refined_method_in_effect?(receiver_type.class_name, call_node, scope,
                                                                     :instance, lexical_sites)

          build_visibility_mismatch_diagnostic(path, call_node, receiver_type.class_name)
        end

        # Issue #1984 — the singleton side reads only the reached definer: a private singleton method may be inherited
        # (`private_class_method :new` on a superclass) or come from an extended module, so there is no own-table
        # gate as on the instance side. It reports only:
        #
        # - a constant receiver (`K.x`, `A::K.x`): `self.class.x` or a local may hold a subclass that makes the name
        #   public again (`public_class_method :new`, a template-method `def self.x`);
        # - a call inside a `def` ({#load_time_call?}): code that runs while the files load (a class body's
        #   `ALL = [K.new]` before its `private_class_method :new`) may run before the call is private;
        # - no class on the chain may have had every singleton name made public (`K.public_class_method(*names)`,
        #   `K.singleton_class.class_eval { … }`; {#singleton_wildcard_contested?}).
        def singleton_visibility_mismatch(path, call_node, scope, receiver_type, lexical_sites)
          class_name = receiver_type.class_name
          return nil unless call_node.receiver.is_a?(Prism::ConstantReadNode) ||
                            call_node.receiver.is_a?(Prism::ConstantPathNode)
          return nil unless private_singleton_candidate?(scope, call_node.name)
          return nil if load_time_call?(scope, call_node)
          return nil unless reached_definer_visibility(scope, class_name, call_node.name, :singleton) == :private
          return nil if missing_hook_on_chain?(scope, class_name, :singleton)
          return nil if singleton_wildcard_contested?(scope, class_name)
          return nil if ReceiverPredicates.refined_method_in_effect?(class_name, call_node, scope, :singleton,
                                                                     lexical_sites)

          build_visibility_mismatch_diagnostic(path, call_node, "singleton(#{class_name})")
        end

        # ADR-129 WD1 — a run-scoped Memo: one `[discovery, names]` slot keyed on the discovery index's identity, the
        # only input the name set reads.
        PRIVATE_NAMES_MEMO = TypingState.memo(
          :check_rules_private_singleton_names,
          run_scoped: true, audit: "private singleton names",
          reason: "one [discovery, names] slot keyed on the discovery index's identity; the name " \
                  "set reads only its method-visibility tables"
        )
        private_constant :PRIVATE_NAMES_MEMO

        # Issue #1984 — the table-only gate the singleton side asks before it reads a chain, as the instance side asks
        # its own table first: whether any class records `name` private, on its singleton side or on its instance
        # side (an extended module's private method is private on the extender's singleton). Without it every
        # `Widget.new` would read, and file the dependency edges of, the whole singleton chain. The set is memoised per
        # discovery index.
        def private_singleton_candidate?(scope, name)
          DependencyRecorder.read_visibility("*", name) if DependencyRecorder.active?
          discovery = scope.discovery
          if Inference::MemoAudit.enabled? && Inference::MemoAudit.suspended?
            return private_recorded_names(discovery.discovered_method_visibilities).include?(name.to_sym)
          end

          state = TypingState.current
          slot = state[PRIVATE_NAMES_MEMO]
          unless slot && slot[0].equal?(discovery)
            names = Inference::MemoAudit.key_audit("private singleton names") do
              private_recorded_names(discovery.discovered_method_visibilities)
            end
            slot = [discovery, names]
            state[PRIVATE_NAMES_MEMO] = slot
            return slot[1].include?(name.to_sym)
          end
          Inference::MemoAudit.check("private singleton names", slot[1], name) do
            private_recorded_names(discovery.discovered_method_visibilities)
          end.include?(name.to_sym)
        end

        def private_recorded_names(tables)
          tables.each_value.with_object(Set.new) do |table, names|
            table.each { |slot, visibility| names << (slot.is_a?(Array) ? slot.last : slot) if visibility == :private }
          end
        end

        # Issue #1984 — whether the call is outside every `def` the file's deferred ranges name. A `def` is named
        # wherever it is written in a class body, at the top level or in a `class_eval` block, so a call in it is not
        # load time and may be reported. The top level, class bodies, and blocks and lambdas that are not such a `def`
        # (a `map { … }` or `define_method` block, a `-> { }`) are load time and decline: such code may run while the
        # files load, before a later `private_class_method` or in a load order where the private declaration has not
        # run yet.
        def load_time_call?(scope, call_node)
          rows = scope.discovered_deferred_ranges[scope.source_path]
          return true if rows.nil?

          offset = call_node.location.start_offset
          # A row with no side (a `def` in a block, a `define_method` name) is a block's range or no range at all.
          rows.none? { |(start, finish, _name, kind, _owner)| !kind.nil? && start <= offset && offset < finish }
        end

        SINGLETON_WILDCARD_SLOT = %i[singleton *].freeze
        private_constant :SINGLETON_WILDCARD_SLOT

        # Issue #1984 — whether a project class on `class_name`'s singleton chain has its wildcard singleton slot
        # contested: a call the walk saw may have made any of its singleton methods public.
        def singleton_wildcard_contested?(scope, class_name)
          discovery = scope.discovery
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          chain.entries.any? do |entry|
            DependencyRecorder.read_visibility(entry.name, SINGLETON_WILDCARD_SLOT.last) unless entry.external?
            !entry.external? && discovery.contested?(:discovered_method_visibilities,
                                                     [entry.name, SINGLETON_WILDCARD_SLOT])
          end
        end

        VISIBILITY_MISSING_HOOKS = %i[method_missing respond_to_missing?].freeze
        private_constant :VISIBILITY_MISSING_HOOKS

        # Issue #1984 — whether a project entry on `class_name`'s chain for `side` records a `method_missing` or
        # `respond_to_missing?` on the side that entry stands for (a singleton entry's singleton methods, a mixin's
        # instance methods), or the chain cannot be read whole. Ruby sends a private call to `method_missing`, so
        # such a hook may answer it.
        def missing_hook_on_chain?(scope, class_name, side)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, side, :methods)
          return true if chain.truncated?

          chain.entries.any? do |entry|
            next false if entry.external?

            kind = entry.side == :singleton ? :singleton : :instance
            VISIBILITY_MISSING_HOOKS.any? { |hook| records_hook?(scope, entry.name, hook, kind) }
          end
        end

        def records_hook?(scope, owner, hook, kind)
          return true if scope.discovered_method?(owner, hook, kind)

          !(kind == :singleton ? scope.singleton_def_for(owner, hook) : scope.user_def_for(owner, hook)).nil?
        end

        # Issue #1568, ADR-119 C1c — the recorded visibility of the definition a call on `class_name` reaches: the
        # first project entry on the class's {Scope::ResolutionChain} from its head that records the name, so a
        # module the class PREPENDS answers ahead of the class. `Inference::DefinerResolution` reads it with the
        # `:visibility` question's default answer. It is `:undecided` wherever the chain does not settle the order
        # (an unpositioned or forked mixin, a conditional include) or an ancestor ahead of the definer may define
        # the name (one RBS does not know), and the caller declines; a definer whose visibility slot ADR-119's
        # producers contest is not alone (`DefinerResolution` asks the next candidate too), so it is `:undecided`
        # there without a read of the table here. nil is nothing recording the name at all, and the class's own
        # visibility stands. An ancestor the project does not declare is passed over, as the method lookup passes it.
        def reached_definer_visibility(scope, class_name, method_name, side = :instance)
          case Inference::DefinerResolution.resolve(scope, class_name, method_name, side, question: :visibility)
          in Inference::DefinerResolution::Known(answer:)
            answer
          in Inference::DefinerResolution::UNKNOWN
            :undecided
          in Inference::DefinerResolution::ABSENT
            nil
          end
        end

        def explicit_non_self_receiver?(receiver)
          return false if receiver.nil?
          return false if receiver.is_a?(Prism::SelfNode)

          true
        end

        def build_visibility_mismatch_diagnostic(path, call_node, receiver_name)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_VISIBILITY_MISMATCH,
            path: path,
            message: "private method `#{call_node.name}' called on #{receiver_name} receiver",
            severity: :error,
            receiver_type: receiver_name,
            method_name: call_node.name.to_s
          )
        end

        # Pulls a single concrete class name from an ivar write's rvalue type. Returns nil when the type is
        # too unstable to compare (Union / Dynamic / IntegerRange / etc.). `concrete_class_name` already
        # covers Nominal / Singleton / Constant / Tuple / HashShape; the wrapper exists so the ivar rule can
        # extend the envelope (or apply different filters) without disturbing the call rules.
        #
        # `TrueClass` / `FalseClass` are both normalised to `"bool"` here so the common boolean-flag idiom
        # (`@loaded = false` in `initialize` then `@loaded = true` on first work) doesn't fire the mismatch
        # rule. A real `bool → String` drift still trips because the second write's `ivar_class_for` returns
        # `"String"`.
        def ivar_class_for(type)
          name = ReceiverPredicates.concrete_class_name(type)
          return "bool" if %w[TrueClass FalseClass].include?(name)

          name
        end

        def build_always_truthy_condition_diagnostic(path, predicate_node, polarity)
          Diagnostic.from_node(
            predicate_node,
            rule: RULE_ALWAYS_TRUTHY_CONDITION,
            path: path,
            message: "condition is always #{polarity} (the surrounding flow proves it folds to a constant)",
            severity: :warning
          )
        end

        def build_unreachable_clause_diagnostic(path, result)
          Diagnostic.from_node(
            result.body,
            rule: RULE_UNREACHABLE_CLAUSE,
            path: path,
            message: unreachable_clause_message(result),
            severity: :warning
          )
        end

        def build_void_value_use_diagnostic(path, result)
          Diagnostic.from_node(
            result.void_node,
            rule: RULE_VALUE_USE_VOID,
            path: path,
            message: "value use of `void': `#{result.origin.label}' declares `-> void', so its return " \
                     "recovers to `top' and should not be used as a value",
            severity: :warning
          )
        end

        def unreachable_clause_message(result)
          subject = result.subject_name
          kw = result.keyword
          case result.kind
          when :prior_exhaustion
            "unreachable `#{kw} #{result.condition_source}': `#{subject}' is already covered " \
            "by an earlier `#{kw}' clause"
          when :exhausted_else
            "unreachable `else': the `#{kw}' clauses already cover every value `#{subject}' can take here"
          else # :disjoint
            "unreachable `#{kw} #{result.condition_source}': `#{subject}' can never be " \
            "#{result.condition_source} here (the flow proves the subject disjoint)"
          end
        end

        def build_shadowed_rescue_diagnostic(path, result)
          Diagnostic.from_node(
            result.clause,
            rule: RULE_SHADOWED_RESCUE_CLAUSE,
            path: path,
            message: shadowed_rescue_message(result),
            severity: :warning
          )
        end

        def shadowed_rescue_message(result)
          earlier = result.earlier_sources.each_with_index.map do |source, index|
            "`#{source}' (line #{result.earlier_lines[index]})"
          end
          "shadowed `#{result.clause_source}': every exception class it names is already caught " \
            "by the earlier #{earlier.join(' and ')} clause#{'s' if earlier.size > 1}, so this clause can never run"
        end

        def build_dead_assignment_diagnostic(path, write_node, def_node)
          Diagnostic.from_name_loc(
            write_node,
            rule: RULE_DEAD_ASSIGNMENT,
            path: path,
            message: "local `#{write_node.name}' assigned in `#{def_node.name}' but never read",
            severity: :warning
          )
        end

        # The diagnostic points at the LATER occurrence (the entry that wins at runtime) and names the
        # first occurrence's line, so the fix — delete or rename one of the two — is visible from the
        # message alone.
        def build_duplicate_hash_key_diagnostic(path, result)
          first_line = result[:first_key_node].location.start_line
          Diagnostic.from_node(
            result[:key_node],
            rule: RULE_DUPLICATE_HASH_KEY,
            path: path,
            message: "duplicate hash key `#{result[:key_label]}' in the same literal; this entry " \
                     "overwrites the value first set at line #{first_line}",
            severity: :warning
          )
        end

        def build_return_in_ensure_diagnostic(path, return_node)
          Diagnostic.from_location(
            return_node.keyword_loc,
            rule: RULE_RETURN_IN_ENSURE,
            path: path,
            message: "`return' inside `ensure' discards the method's in-flight return value " \
                     "and swallows any in-flight exception",
            severity: :warning
          )
        end

        def build_ivar_write_mismatch_diagnostic(path, node, class_name, ivar_name, first_class, other_class)
          Diagnostic.from_name_loc(
            node,
            rule: RULE_IVAR_WRITE_MISMATCH,
            path: path,
            message: "instance variable `#{ivar_name}' on #{class_name} was previously assigned " \
                     "#{first_class}; this write assigns #{other_class}",
            severity: :error
          )
        end

        # Returns the dead-branch node for a literal-predicate if/unless, or nil when no observable branch
        # is dead.
        def unreachable_branch_for(node, truthy)
          dead =
            case node
            when Prism::IfNode then truthy ? node.subsequent : node.statements
            when Prism::UnlessNode then truthy ? node.statements : node.else_clause
            end
          dead unless dead.nil?
        end

        def build_unreachable_branch_diagnostic(path, dead_branch, polarity)
          Diagnostic.from_node(
            dead_branch,
            rule: RULE_UNREACHABLE_BRANCH,
            path: path,
            message: "unreachable branch: literal predicate is always #{polarity}",
            severity: :warning
          )
        end

        # v0.0.2 #4 — argument-type-mismatch diagnostic.
        # Walks a call's positional arguments and checks each
        # against the matching parameter's RBS type via
        # `Rigor::Inference::Acceptance`. Emits an `:error`
        # for the first argument whose type the parameter
        # does NOT accept under the gradual mode.
        #
        # Conservative envelope (matches the wrong-arity rule
        # plus a few additional skips):
        # - Receiver must be Nominal / Singleton / Constant
        #   (the same `concrete_class_name` test).
        # - Method must be in RBS.
        # - Overloads: a single method type is checked exactly; with several, an argument is a mismatch only
        #   when every overload rejects it ({#multi_overload_argument_mismatch}).
        # - The overload checked must have NO
        #   rest_positionals and NO trailing positionals —
        #   the two shapes under which argument N no longer
        #   binds to positional parameter N. Keyword
        #   parameters do not disqualify it (#673).
        # - The call must use plain positional arguments
        #   (no splat / kw / block-pass / forwarded).
        # - Per-argument: skip when EITHER side is `Dynamic`
        #   (the call cannot be statically refuted).
        # Ruby's universal-equality methods accept any object
        # per the `Object#==(other) → bool` /
        # `Object#eql?(other) → bool` contract. Even when a
        # subclass overrides `==` to compare specific shapes
        # (URI::Generic#==(URI::Generic), Time#==(Time), …),
        # the runtime convention is to RETURN false for
        # type-mismatched arguments rather than raise. RBS sigs
        # that declare a tight parameter type therefore over-
        # specify; checking arguments against them produces
        # spurious mismatches such as
        #   `URI::Generic#==(URI::Generic)`
        #   called with `URI::HTTP | nil`
        # tdiary-core's `config_uri == referer_uri` (where
        # `referer_uri` is `URI.parse(...) if condition`, hence
        # union-with-nil) is the canonical case. Skip arg
        # checking on these methods entirely; the call is
        # well-formed by Ruby's contract.
        UNIVERSAL_EQUALITY_METHODS = %i[== != eql? equal? <=>].to_set.freeze
        private_constant :UNIVERSAL_EQUALITY_METHODS

        # ADR-64 WD1 — the binary arithmetic / bit / ordering operators
        # dispatch through Ruby's `coerce` protocol (and `<=>` for the
        # comparisons): `5 + Money.new` is valid at runtime because
        # `Integer#+` calls `Money#coerce(5)`, even though no RBS `Integer#+`
        # overload lists `Money`. A non-`Numeric` argument to them is therefore
        # NOT statically refutable — any user type may define `coerce` — so the
        # *non-nil* argument-type-mismatch channel excludes them (a fixed
        # allow-list, modelled on {UNIVERSAL_EQUALITY_METHODS}, not `coerce`
        # detection). `nil` never coerces, so the nil channel stays in force
        # here; the exclusion applies to the non-nil case only. `<=>` and the
        # `==` family are already excluded wholesale by
        # {UNIVERSAL_EQUALITY_METHODS}.
        COERCE_DISPATCH_METHODS = %i[+ - * / % ** & | ^ << >> < > <= >=].to_set.freeze
        private_constant :COERCE_DISPATCH_METHODS

        def argument_type_diagnostic(path, call_node, facts, lexical_sites = nil)
          return nil if call_node.receiver.nil?
          return nil if UNIVERSAL_EQUALITY_METHODS.include?(call_node.name)
          return nil unless plain_positional_call?(call_node)

          scope = facts.scope
          return nil if scope.nil?

          receiver_type = facts.receiver_type
          class_name = ReceiverPredicates.concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # NOTE: unlike the undefined-method / wrong-arity
          # rules, we deliberately do NOT skip when
          # `discovered_method?` matches. When the user
          # supplies BOTH a `def` and an RBS sig, the sig is
          # the authoritative parameter contract and we
          # should validate calls against it.
          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return nil unless ReceiverPredicates.definition_available?(receiver_type, class_name, scope)

          method_def = ReceiverPredicates.receiver_signature(facts)
          return nil if method_def.nil?

          param_overrides = Rigor::RbsExtended.param_type_override_map(method_def, environment: scope.environment)
          mismatch = argument_mismatch(method_def.method_types, call_node, scope, param_overrides, facts.scope_index)
          return nil if mismatch.nil?
          return nil if argument_report_withheld?(receiver_type, class_name, call_node, mismatch, scope, lexical_sites)

          build_argument_type_diagnostic(path, call_node, class_name, mismatch)
        end

        # The declines `call.argument-type-mismatch` asks only once an argument mismatches.
        def argument_report_withheld?(receiver_type, class_name, call_node, mismatch, scope, lexical_sites)
          return true if inferred_param_mismatch_verdict?(call_node, mismatch, scope)

          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          ReceiverPredicates.refined_redefinition_in_effect?(class_name, call_node, scope, kind, lexical_sites)
        end

        # ADR-67 WD6b — an argument-type-mismatch verdict resting on an open-call-site lower bound, on
        # either side of the call. The ARGUMENT side: the mismatching argument is an inferred-parameter
        # local, so firing against it is an FP by construction. The RECEIVER side: when the receiver roots
        # at an inferred parameter, the method whose parameter contract the argument was checked against
        # was itself resolved through a lower-bound type, so the whole verdict is speculative. The 2026-07-30
        # self-check surfaced the receiver half as a guard hole: seeding `env : RBS::Environment` activated
        # this rule on `env.unload(culprits)` and flagged a correct Array argument against `unload`'s
        # declared `Set[Pathname]` — an upstream signature stricter than its implementation, exactly the FP
        # class WD6b exists to suppress. The other guarded rules already declined on a param-rooted
        # receiver; this brings argument-type-mismatch in line.
        def inferred_param_mismatch_verdict?(call_node, mismatch, scope)
          ReceiverPredicates.inferred_param_argument?(mismatch[:node], scope) ||
            ReceiverPredicates.inferred_param_receiver?(call_node, scope)
        end

        # Single overload → the exact per-argument acceptance (unchanged).
        # Multiple overloads → the nil channel (a pure-`nil` argument every
        # overload rejects) plus, on non-coerce methods, the non-nil channel
        # (a single-concrete-class argument every overload rejects). See
        # {#multi_overload_argument_mismatch}.
        #
        # Each argument is typed from its own index entry, which is the call's unless an earlier operand moved
        # the scope it was entered from (issue #1256): `(k = 0; 5)[k]` checks `k` as the `0` it holds there.
        def argument_mismatch(method_types, call_node, scope, param_overrides, scope_index)
          mismatch =
            if method_types.size == 1
              first_argument_mismatch(method_types.first, call_node, scope, param_overrides, scope_index)
            else
              multi_overload_argument_mismatch(method_types, call_node, scope, param_overrides, scope_index)
            end
          return nil if mismatch && keyword_bearing?(method_types) && nil_tainted?(mismatch[:actual])

          mismatch
        end

        # Issue #673 widened {#argument_check_eligible?} to admit keyword-bearing signatures, whose
        # POSITIONAL arguments had gone unchecked. The widening is staged, and this is the half held
        # back: on such a signature only an argument refuted on its CLASS fires; one carrying `nil`
        # does not.
        #
        # Measured, not assumed. Across redmine, mastodon, tdiary-core, faraday, liquid and
        # rubocop-ast the widening produced exactly two new verdicts, both on correct code and both
        # resting on nullability: `Addrinfo.foreach(host, nil, nil, :STREAM)` (redmine — a nil service
        # is legal at runtime; rbs declares the parameter `String | ::Integer`) and
        # `Nokogiri::HTML5(html)` guarded by `return if html.nil?` one line above (mastodon — the guard
        # is on a method call, so the type stays `Dynamic[top]?`). Zero class-refuted new verdicts were
        # false. Nullability is the property a hand-written signature most often over-declares, so it
        # stays behind the old envelope until it has evidence of its own.
        #
        # Signatures WITHOUT keywords are untouched: `"a" + nil` fires exactly as before.
        def keyword_bearing?(method_types)
          method_types.any? do |method_type|
            function = method_type.type
            next false unless function.respond_to?(:required_keywords)

            !function.required_keywords.empty? || !function.optional_keywords.empty? ||
              !function.rest_keywords.nil?
          end
        end

        def nil_tainted?(actual)
          ReceiverPredicates.nil_member?(actual) || (actual.is_a?(Type::Union) && union_contains_nil?(actual))
        end

        # Multi-overload argument-type-mismatch. The dispatcher's per-overload
        # acceptance plumbing is not run here; instead the FP-safe shape mirrors
        # the "absent on every arm" union-undefined-method rule: an argument is
        # a mismatch only when EVERY overload's matching positional param
        # rejects it.
        #
        # Two channels, both gated on a positively-refuted argument:
        # - **nil** (any method): a pure `nil` no overload admits is a
        #   guaranteed `TypeError` — `nil` never coerces.
        # - **non-nil** (ADR-64, non-coerce methods only): an argument that
        #   types to a single concrete RBS-known class that no overload admits.
        #   Excludes {COERCE_DISPATCH_METHODS} (`5 + Money.new` is valid via
        #   `coerce`), restricts to a single concrete class (WD3 — a union arg
        #   stays deferred), and decides acceptance on the RBS param type
        #   ({#param_accepts_arg_class?}) so it sees through the `int` / `string`
        #   interface-aliases the translator degrades.
        def multi_overload_argument_mismatch(method_types, call_node, scope, param_overrides, scope_index)
          functions = method_types.map(&:type)
          return nil unless functions.all? { |function| argument_check_eligible?(function) }

          coerce_method = COERCE_DISPATCH_METHODS.include?(call_node.name)
          arguments = call_node.arguments&.arguments || []
          arguments.each_with_index do |arg, index|
            params = checkable_overload_params(method_types, index, param_overrides, scope)
            next if params.nil?

            mismatch = overload_argument_mismatch(arg, params, param_overrides,
                                                  argument_scope(arg, scope, scope_index), coerce_method)
            return mismatch if mismatch
          end
          nil
        end

        # The mismatch (or nil) for one argument against the parameter every overload has at its position. Issue
        # #1362 — a builtin global's seed, or its copy, is judged by the file's writes to the global.
        def overload_argument_mismatch(arg, params, param_overrides, arg_scope, coerce_method)
          written = DeclarationSourcedGuard.written_type(arg, arg_scope)
          arg_type = written || arg_scope.type_of(arg)
          if ReceiverPredicates.nil_member?(arg_type) # pure nil only — not a `T | nil` union
            nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, arg_scope, written: !written.nil?)
          elsif !coerce_method
            non_nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, arg_scope)
          end
        end

        # The parameter set at `index` that a verdict may rest on, or nil when there is none — the two
        # reasons being arity divergence (an overload with no param there, which is `call.wrong-arity`'s
        # concern) and an overload whose param names a class carrying no definition ({#stub_typed_param?},
        # issue #661). Both channels below fire only when EVERY overload rejects, so either one is enough
        # to unseat that premise.
        def checkable_overload_params(method_types, index, param_overrides, scope)
          params = overload_positional_params(method_types, index)
          return nil if params.nil?
          return nil if params.any? { |param| stub_typed_param?(param, param_overrides, scope) }

          params
        end

        # The nil channel: a pure `nil` argument no overload admits (ADR-58
        # parity excuses a declaration-sourced ivar nil).
        def nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, scope, written: false)
          return nil if !written && declaration_sourced_nil_argument?(arg, scope)
          return nil if params.any? { |param| param_admits_nil?(param, param_overrides, scope) }

          { node: arg, name: nil, expected: overload_param_expected_label(params), actual: arg_type }
        end

        # The non-nil channel (ADR-64 WD2/WD3): a single-concrete-class
        # argument no overload admits, on a non-coerce method.
        def non_nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, scope)
          return class_object_overload_mismatch(arg, arg_type, params, param_overrides, scope) if
            arg_type.is_a?(Type::Singleton)
          return nil unless single_concrete_arg_class?(arg_type, scope)
          return nil if params.any? { |param| param_accepts_arg_class?(param, arg_type, param_overrides, scope) }

          { node: arg, name: nil, expected: overload_param_expected_label(params), actual: arg_type }
        end

        # Issue #2828 — the class-object twin of the non-nil channel. A `singleton(T)` overload the `resolv` overlay
        # prepends turned `getresources(d, String)`'s one-overload check (`expected singleton(Resolv::DNS::Query)`)
        # into this multi-overload one, which declined every class object. It fires only when every overload's
        # parameter at the position is a `singleton(...)` (a `singleton(T)` read through its class bound, see
        # `SingletonTypeParams.selection_param`) that provably refuses the argument's class; any other parameter
        # shape admits.
        def class_object_overload_mismatch(arg, arg_type, params, param_overrides, scope)
          return nil unless Rigor::Reflection.rbs_class_known?(arg_type.class_name, scope: scope)
          return nil unless params.all? do |param|
            !param_overrides[param.name] && param.type.is_a?(RBS::Types::ClassSingleton)
          end
          return nil unless params.all? { |param| class_singleton_refuses?(param.type, arg_type, scope) }

          expected = params.map { |param| param.type.to_s.sub("singleton(::", "singleton(") }.uniq.join(" | ")
          { node: arg, name: nil, expected: expected, actual: arg_type }
        end

        def class_singleton_refuses?(rbs_type, arg_type, scope)
          translated = translate_param_type(rbs_type, scope.environment)
          translated.is_a?(Type::Singleton) && Inference::Acceptance.accepts(translated, arg_type, mode: :gradual).no?
        end

        # The matching positional RBS param across every overload, or nil when
        # any overload has no param at `index` (arity divergence — the
        # wrong-arity rule's concern, not this one's).
        def overload_positional_params(method_types, index)
          params = method_types.map do |method_type|
            function = method_type.type
            param = (function.required_positionals + function.optional_positionals)[index]
            param && resolve_param_bounds(param, method_type)
          end
          params.any?(&:nil?) ? nil : params
        end

        # Substitutes each bounded method-level type parameter for its bound, so
        # `[I < _ToInt] (I index) -> …` is walked as `(_ToInt index) -> …`. A bare
        # `Variable` is undecidable to the acceptance walk and admits everything,
        # which silently disables both channels for the whole overload; the bound
        # constrains the argument exactly as an ordinary param of that type would.
        # Load-bearing since rbs 4.1 rewrote core signatures into this form
        # (`Array#fetch`'s block overload is `[I < _ToInt, T] (I index) { … }`).
        def resolve_param_bounds(param, method_type)
          param = Inference::MethodDispatcher::SingletonTypeParams.selection_param(param, method_type)
          bounded = method_type.type_params.select(&:upper_bound)
          return param if bounded.empty?

          substitution = RBS::Substitution.build(bounded.map(&:name), bounded.map(&:upper_bound))
          param.map_type { |type| type.sub(substitution) }
        end

        # ADR-26 WD8's PARAMETER-side twin (issue #661). `sig/app.rbs` declaring
        # `(ActiveSupport::TimeWithZone) -> void` in a project that never brings ActiveSupport's RBS in
        # names a class that carries no definition anywhere in the environment. Rigor still refuted
        # `App.take_twz(Time.now)` against it — `expected ActiveSupport::TimeWithZone, got Time` on a call
        # that works — because the acceptance walk compares nominals and `Time`'s ancestry does not list a
        # name nothing declares.
        #
        # WD8 already declines the two signature rules on such a RECEIVER, on the ground that there is
        # nothing authoritative to check the call against. It is the same one position over: with no
        # ancestry there is no fact that could make an argument satisfy the parameter either, so the
        # rejection is the missing signature restated as an error rather than a finding about the program.
        # Under AGENTS.md's false-positives-outrank-worst-case rule the honest answer is to decline, and
        # the report it costs is one the analyzer never had evidence for.
        #
        # Both shapes the missing name arrives in are covered, deliberately as ONE criterion. A name an
        # INSTANCE-method signature references is minted as an empty stub so the class builds
        # ({Environment::RbsLoader.stub_missing_referenced_types}) and reads back as RBS-known; the same
        # name in a SINGLETON signature is not, because that pass mirrors rbs's own membership test and
        # `validate_type_params` never reaches singleton members. That asymmetry is an artifact of which
        # pass ran, not of what is knowable, and the issue's own repro is the singleton half.
        #
        # A `rigor:v1:param` override is a real Rigor type the author wrote against the call site's own
        # method, so it is consulted first and checked normally.
        def stub_typed_param?(param, param_overrides, scope)
          return false if param_overrides[param.name]

          undefined_param_class?(param.type, scope)
        end

        # Only the arms a verdict can rest on directly: a union member, an optional's inner type, an
        # expanded alias, and the class instance / singleton itself. Deliberately NOT recursive into type
        # ARGUMENTS — `Array[Missing]` is still refuted by an `Integer` argument on the `Array` alone, and
        # declining there would be a lost report bought for nothing.
        def undefined_param_class?(rbs_type, scope)
          case rbs_type
          when RBS::Types::Union then rbs_type.types.any? { |member| undefined_param_class?(member, scope) }
          when RBS::Types::Optional then undefined_param_class?(rbs_type.type, scope)
          when RBS::Types::Alias
            expanded = scope.environment&.rbs_loader&.expand_type_alias(rbs_type)
            !expanded.nil? && undefined_param_class?(expanded, scope)
          when RBS::Types::ClassInstance, RBS::Types::ClassSingleton
            name = rbs_type.name
            ReceiverPredicates.synthesized_stub_receiver?(name, scope) ||
              !Rigor::Reflection.rbs_class_known?(name.to_s, scope: scope)
          else false
          end
        end

        # The class names whose instances `nil` IS — `NilClass` and every
        # ancestor. A parameter typed as any other class instance rejects nil.
        NIL_COMPATIBLE_CLASS_NAMES = %w[NilClass Object BasicObject Kernel].to_set.freeze
        private_constant :NIL_COMPATIBLE_CLASS_NAMES

        # Does this parameter admit a `nil` argument? Decided on the RBS
        # parameter type (a `rigor:v1:param` override takes precedence).
        # Conservative throughout: any case we cannot decide returns true
        # (admits → do not fire), so the rule never fires on uncertainty.
        def param_admits_nil?(param, param_overrides, scope)
          override = param_overrides[param.name]
          return rigor_type_admits_nil?(override) if override

          rbs_type_admits_nil?(param.type, scope)
        end

        # The `rigor:v1:param` override variant — a refinement
        # (`non-empty-string`) rejects nil; an explicit nil / nilable union /
        # gradual override admits it.
        def rigor_type_admits_nil?(type)
          return true if type.is_a?(Type::Dynamic) || type.is_a?(Type::Top)
          return true if ReceiverPredicates.nil_member?(type)
          return union_contains_nil?(type) if type.is_a?(Type::Union)

          false
        end

        # Walks the RBS parameter type. The load-bearing cases are `Alias`
        # (`string` = `String | _ToStr`) and `Interface` (`_ToStr`), which
        # {Inference::RbsTypeTranslator} degrades to `untyped` — the reason a
        # `nil` argument is invisible after translation (the interface-alias
        # gap). Resolving them here recovers the rejection. Only a concrete
        # class instance that is not a `nil` ancestor, and an interface
        # NilClass does not satisfy, return false; everything else admits.
        def rbs_type_admits_nil?(rbs_type, scope)
          case rbs_type
          when RBS::Types::Union then rbs_type.types.any? { |member| rbs_type_admits_nil?(member, scope) }
          when RBS::Types::Alias
            expanded = scope.environment&.rbs_loader&.expand_type_alias(rbs_type)
            expanded.nil? || rbs_type_admits_nil?(expanded, scope)
          when RBS::Types::ClassInstance
            NIL_COMPATIBLE_CLASS_NAMES.include?(rbs_type.name.to_s.delete_prefix("::"))
          when RBS::Types::Interface then interface_admits_nil?(rbs_type, scope)
          else true # Optional / bases / variable / tuple / record / proc / literal / intersection → conservative admit
          end
        end

        # An interface parameter (`_ToStr`) admits nil only when NilClass
        # implements every method it requires (`to_str`, `to_int`, … — which
        # NilClass does not, so `string` / `int` params reject nil; a
        # hypothetical `_ToS` would admit, since NilClass#to_s exists).
        # Unresolvable → conservative true.
        def interface_admits_nil?(rbs_type, scope)
          loader = scope.environment&.rbs_loader
          return true if loader.nil?

          methods = loader.interface_method_names(rbs_type.name.to_s)
          return true if methods.nil? || methods.empty?

          methods.all? { |method_name| nil_class_has_method?(method_name, scope) }
        end

        # ADR-64 WD3 — the non-nil channel fires only on an argument that types
        # to a single concrete, RBS-known class. A union arg mirrors the
        # union-receiver story and stays deferred; a class/module object
        # (`Singleton`) has a special acceptance surface and is skipped; a
        # non-RBS project class is skipped because its conversion protocol (a
        # duck-typed `to_int` / `to_str`) is invisible to us, so we cannot
        # refute acceptance.
        def single_concrete_arg_class?(arg_type, scope)
          return false if arg_type.is_a?(Type::Union)
          return false if arg_type.is_a?(Type::Singleton)

          class_name = ReceiverPredicates.concrete_class_name(arg_type)
          return false if class_name.nil?

          Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
        end

        # ADR-64 WD2 — does this parameter accept the (non-nil) argument?
        # The non-nil generalization of {#param_admits_nil?}: decided on the RBS
        # parameter type (a `rigor:v1:param` override takes precedence) so it
        # sees through the `int` / `string` interface-aliases the translator
        # degrades to gradual. Conservative throughout — any case we cannot
        # decide returns true (accepts → do not fire).
        def param_accepts_arg_class?(param, arg_type, param_overrides, scope)
          override = param_overrides[param.name]
          return rigor_type_accepts_arg?(override, arg_type) if override

          rbs_type_accepts_arg?(param.type, arg_type, scope)
        end

        # The `rigor:v1:param` override variant — a Rigor `Type`, so the
        # acceptance engine decides directly (gradual; only a proven rejection
        # refutes). Dynamic / Top admit unconditionally.
        def rigor_type_accepts_arg?(param_type, arg_type)
          return true if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)

          !Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual).no?
        end

        # Walks the RBS parameter type, mirroring {#rbs_type_admits_nil?}. The
        # load-bearing cases are `Alias` / `Interface` (`int` = `Integer |
        # _ToInt`), which the translator degrades to gradual — resolving them
        # here recovers the rejection. A faithfully-translated `ClassInstance`
        # is handed to the acceptance engine; everything undecidable admits.
        def rbs_type_accepts_arg?(rbs_type, arg_type, scope)
          case rbs_type
          when RBS::Types::Union then rbs_type.types.any? { |member| rbs_type_accepts_arg?(member, arg_type, scope) }
          when RBS::Types::Alias
            expanded = scope.environment&.rbs_loader&.expand_type_alias(rbs_type)
            expanded.nil? || rbs_type_accepts_arg?(expanded, arg_type, scope)
          when RBS::Types::ClassInstance then class_instance_accepts_arg?(rbs_type, arg_type, scope)
          when RBS::Types::Interface then interface_accepts_arg?(rbs_type, arg_type, scope)
          else true # bases / variable / tuple / record / proc / literal / intersection / optional → conservative admit
          end
        end

        # A `ClassInstance` param (`Integer`, `Numeric`, …) is translated
        # faithfully (no interface degradation), so the acceptance engine — the
        # canonical RBS-ancestry / generic-aware subtype check — decides it.
        # Only a proven rejection refutes; an unresolvable class is `:maybe`,
        # which admits.
        def class_instance_accepts_arg?(rbs_type, arg_type, scope)
          translated = translate_param_type(rbs_type, scope.environment)
          return true if translated.is_a?(Type::Dynamic) || translated.is_a?(Type::Top)

          !Inference::Acceptance.accepts(translated, arg_type, mode: :gradual).no?
        end

        # An interface param (`_ToInt`) accepts the arg only when the arg's
        # class implements every method it requires (`to_int`, …). The non-nil
        # mirror of {#interface_admits_nil?}: ask the arg class, not NilClass.
        # Unresolvable anywhere → conservative true (admit).
        def interface_accepts_arg?(rbs_type, arg_type, scope)
          loader = scope.environment&.rbs_loader
          return true if loader.nil?

          methods = loader.interface_method_names(rbs_type.name.to_s)
          return true if methods.nil? || methods.empty?

          class_name = ReceiverPredicates.concrete_class_name(arg_type)
          return true if class_name.nil?

          methods.all? { |method_name| arg_class_has_method?(class_name, method_name, scope) }
        end

        # The non-nil mirror of {#nil_class_has_method?}, but conservative on
        # the unknown side: an unresolvable definition returns true (the class
        # *might* implement the method — e.g. a metaprogrammed conversion), so
        # the channel never fires on uncertainty.
        def arg_class_has_method?(class_name, method_name, scope)
          definition = Rigor::Reflection.instance_definition(class_name, scope: scope)
          return true if definition.nil?

          !definition.methods[method_name.to_sym].nil?
        end

        # A readable "expected" label for a multi-overload mismatch — the RBS
        # parameter type(s) as written (`string`, or the per-overload set), since
        # the translated Rigor type degrades the interface-alias the rejection
        # hinges on. Shared by the nil and non-nil channels.
        def overload_param_expected_label(params)
          params.map { |param| param.type.to_s.delete_prefix("::") }.uniq.join(" | ")
        end

        # ADR-58 parity for the nil channel: a declaration-sourced read that
        # types as nil is the same not-diagnostic-fuel case the union path
        # gates in {#declaration_sourced_nil_only_mismatch?}; suppress it here
        # too so a ctor-seeded `@x = nil` read passed as an argument does not
        # fire on a working program's cross-method invariant. Issue #324 —
        # delegates to {DeclarationSourcedGuard}, so a local copy of the ivar
        # (`c = @count`) is excused on the same terms `possible-nil-receiver`
        # already excused it.
        def declaration_sourced_nil_argument?(arg, scope)
          DeclarationSourcedGuard.marked?(arg, scope)
        end

        def first_argument_mismatch(method_type, call_node, scope, param_overrides, scope_index)
          function = method_type.type
          return nil unless argument_check_eligible?(function)

          params = function.required_positionals + function.optional_positionals
          arguments = call_node.arguments&.arguments || []
          arguments.each_with_index do |arg, index|
            param = params[index]
            next if param.nil? # arity mismatch is the wrong-arity rule's concern.

            mismatch = single_argument_mismatch(param, arg, argument_scope(arg, scope, scope_index), param_overrides)
            return mismatch if mismatch
          end
          nil
        end

        # The scope `arg` is checked from: its own index entry ({#argument_mismatch}), else the call's.
        def argument_scope(arg, call_scope, scope_index)
          scope_index[arg] || call_scope
        end

        # The mismatch (or nil) for one positional argument against one
        # parameter. The nil channel decides a pure `nil` argument on the RBS
        # parameter type — seeing through the `string` / `int` interface-alias
        # the translator degrades to gradual (so `"a" + nil` fires), excusing a
        # declaration-sourced ivar nil (ADR-58 parity). The non-nil channel is
        # the original translated-acceptance check, with a `rigor:v1:param`
        # override taking precedence over the RBS-declared type.
        def single_argument_mismatch(param, arg, scope, param_overrides)
          return nil if stub_typed_param?(param, param_overrides, scope)

          # Issue #1362 (ADR-58 parity, ADR-117 Decision point 2) — a read of a builtin global still on its declared
          # seed, or a local copied from one, is judged by the file's writes to the global, as the argument was
          # before the join: the declared members are not diagnostic fuel.
          written = DeclarationSourcedGuard.written_type(arg, scope)
          return written_argument_mismatch(param, arg, written, scope, param_overrides) if written

          read_argument_mismatch(param, arg, scope, param_overrides)
        end

        # {#single_argument_mismatch} for an argument that reads no builtin global's seed directly.
        def read_argument_mismatch(param, arg, scope, param_overrides)
          arg_type = scope.type_of(arg)

          if ReceiverPredicates.nil_member?(arg_type)
            return nil if declaration_sourced_nil_argument?(arg, scope)
            return nil if param_admits_nil?(param, param_overrides, scope)

            return { node: arg, name: param.name, expected: overload_param_expected_label([param]), actual: arg_type }
          end

          param_type = param_overrides[param.name] || translate_param_type(param.type, scope.environment)
          return nil if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)
          return nil if arg_type.is_a?(Type::Dynamic) || arg_type.is_a?(Type::Top)
          return nil if gradual_narrowing_accepted?(arg, arg_type, param_type, scope)
          return nil unless argument_genuinely_mismatches?(arg, arg_type, param_type, scope)
          # Issue #1362 — a value that mixes such a global with something else (`c ? $stdout : StringIO.new`) is judged
          # without the declared members the file never writes, as it was before the join.
          return nil if DeclarationSourcedGuard.declared_only_rejection?(arg_type, param_type, scope) do |stripped|
            !plain_argument_rejects?(param, stripped, scope, param_overrides)
          end

          { node: arg, name: param.name, expected: param_type, actual: arg_type }
        end

        # The mismatch for an argument judged by `written`, the file's writes to the builtin globals it reads the
        # seeds of, through the channels {#single_argument_mismatch} runs, without the ADR-58 withholding: before
        # the join the global carried no mark.
        def written_argument_mismatch(param, arg, written, scope, param_overrides)
          return nil unless plain_argument_rejects?(param, written, scope, param_overrides)

          expected =
            if ReceiverPredicates.nil_member?(written)
              overload_param_expected_label([param])
            else
              param_overrides[param.name] || translate_param_type(param.type, scope.environment)
            end
          { node: arg, name: param.name, expected: expected, actual: written }
        end

        # True when `param` rejects an argument of type `type` on the terms of {#single_argument_mismatch}'s nil and
        # non-nil channels, without the ADR-58 withholding.
        def plain_argument_rejects?(param, type, scope, param_overrides)
          return !param_admits_nil?(param, param_overrides, scope) if ReceiverPredicates.nil_member?(type)

          param_type = param_overrides[param.name] || translate_param_type(param.type, scope.environment)
          return false if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)
          return false if type.is_a?(Type::Dynamic) || type.is_a?(Type::Top)

          Inference::Acceptance.accepts(param_type, type, mode: :gradual).no?
        end

        # Issue #2656 — a local a class guard narrowed from a `Dynamic` value
        # ({DeclarationSourcedGuard.gradual_narrowed?}) is judged by its class, not by the literals the parameter
        # names: `mode(x) if x.is_a?(String)` with `mode: ("r" | "w")` is accepted, as the gradual value was, while
        # `num(x) if x.is_a?(String)` with `num: (1 | 2)` still reports, since no String is ever `1` or `2`. The
        # parameter's value-pinned members are widened to their classes ({Type::Combinator.widen_value_pinned}) and
        # the narrowed type is judged against that. The overload path ({#non_nil_arg_overload_mismatch}) already
        # judges by class, so it needs no such reading.
        #
        # A literal member of the narrowed type did not come from the gradual value (`x = h[:m] || "r"` narrows to
        # `"r" | String`), so it is judged against the parameter as written.
        def gradual_narrowing_accepted?(arg, arg_type, param_type, scope)
          return false unless DeclarationSourcedGuard.gradual_narrowed?(arg, scope)

          members = arg_type.is_a?(Type::Union) ? arg_type.members : [arg_type]
          literals, rest = members.partition { |member| member.is_a?(Type::Constant) }
          if literals.any? { |member| Inference::Acceptance.accepts(param_type, member, mode: :gradual).no? }
            return false
          end
          return true if rest.empty?

          widened = Type::Combinator.widen_value_pinned(param_type)
          !Inference::Acceptance.accepts(widened, Type::Combinator.union(*rest), mode: :gradual).no?
        end

        # The parameter rejects the argument AND the rejection is not a
        # withheld declaration-sourced-nil case.
        def argument_genuinely_mismatches?(arg, arg_type, param_type, scope)
          return false unless rejects_beyond_class_objects?(param_type, arg_type)

          # ADR-58 (N2 extension) — the same declaration-sourced-nil-is-not-
          # diagnostic-fuel criterion that governs `possible-nil-receiver`
          # applies here. When the only reason the argument is rejected is a
          # *declaration-sourced* nil constituent (the class-ivar index seed
          # of a ctor `@x = nil` / a non-definitely-assigned ivar read), and
          # the argument type with that nil removed WOULD be accepted, the
          # working program's cross-method invariant is assumed and we do not
          # fire. Flow-live nil (a method-local `@x = nil` write, a failed-
          # guard narrowing) drops the provenance mark upstream and still
          # fires. The argument's type is unchanged — only the firing
          # decision is gated.
          !declaration_sourced_nil_only_mismatch?(arg, arg_type, param_type, scope)
        end

        # Issue #2855 — the parameter rejects the argument, and not only for its `Class` / `Module` members. An
        # unparameterised `Class` or `Module` nominal ({Acceptance.class_or_module_nominal?}) against a parameter
        # that admits class objects (`singleton(X)`, alone or in a union) is a class object whose identity inference
        # lost — a `const_get` result kept by `is_a?(Class)`, an `is_a?(Module)` guard — so it is withheld. The rest
        # of the argument is still judged: `Class | Integer` against `singleton(X)` reports for its `Integer`.
        # Acceptance itself keeps answering `no`, so overload selection is unchanged.
        def rejects_beyond_class_objects?(param_type, arg_type)
          return false unless Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual).no?
          return true unless admits_class_objects?(param_type)

          members = arg_type.is_a?(Type::Union) ? arg_type.members : [arg_type]
          rest = members.reject { |member| Inference::Acceptance.class_or_module_nominal?(member) }
          return true if rest.size == members.size

          Inference::Acceptance.accepts(param_type, Type::Combinator.union(*rest), mode: :gradual).no?
        end

        def admits_class_objects?(param_type)
          case param_type
          when Type::Singleton then true
          when Type::Union then param_type.members.any?(Type::Singleton)
          else false
          end
        end

        # True when `arg` is a declaration-sourced read whose rejection is
        # caused solely by its nil constituent: stripping nil from the argument
        # type yields a type the parameter accepts (gradual mode). Mirrors the
        # `possible-nil-receiver` WD1 gate — since issue #324 through the very
        # same {DeclarationSourcedGuard} predicate, so the ivar read and its
        # local copy (`c = @count`) are one case rather than two spellings that
        # can drift apart again.
        def declaration_sourced_nil_only_mismatch?(arg, arg_type, param_type, scope)
          return false unless DeclarationSourcedGuard.marked?(arg, scope)
          return false unless arg_type.is_a?(Type::Union)
          return false unless union_contains_nil?(arg_type)

          non_nil = Type::Combinator.union(*arg_type.members.reject { |m| ReceiverPredicates.nil_member?(m) })
          return false if non_nil.is_a?(Type::Bot)

          result = Inference::Acceptance.accepts(param_type, non_nil, mode: :gradual)
          # Issue #2855 — a `Class?` ivar against `singleton(X)` is withheld as its `Class` alone would be.
          # Issue #2863 — a `maybe` (a project class the host process has not loaded, so its ancestry is unresolved:
          # `singleton(Circle)` against `singleton(Shape)`) is not a rejection either: the non-nil part alone would not
          # fire, so the nil is the only reason and it is withheld.
          !result.no? || !rejects_beyond_class_objects?(param_type, non_nil)
        end

        # What this rule needs is that argument N binds to positional
        # parameter N, so the only disqualifiers are the two shapes that
        # break that mapping: a rest positional (arguments past it belong
        # to the rest, not to a later parameter) and trailing positionals
        # (the last arguments bind backwards from the end).
        #
        # Issue #673 — a keyword parameter used to disqualify the whole
        # signature, which silently unchecked the POSITIONAL arguments of
        # every keyword-bearing signature in the bundle:
        # `time.beginning_of_week("monday")` fired while
        # `time.next_week("monday")`, `(?Symbol, ?same_time: bool)`, did not,
        # though both raise the same way at runtime. Keywords cannot shift a
        # positional argument's index, and a call that PASSES keywords never
        # reaches here at all — `plain_positional_call?` rejects a
        # `KeywordHashNode` argument (`**opts` included) before the signature
        # is consulted.
        def argument_check_eligible?(function)
          # See `arity_eligible?`: `UntypedFunction` lacks
          # the per-arity accessors. Treat it as ineligible
          # for argument-type-mismatch diagnostics.
          return false unless function.respond_to?(:required_keywords)

          function.rest_positionals.nil? && function.trailing_positionals.empty?
        end

        def translate_param_type(rbs_type, environment)
          Inference::RbsTypeTranslator.translate(rbs_type, alias_expander: environment&.rbs_loader)
        rescue StandardError
          Type::Combinator.untyped
        end

        def build_argument_type_diagnostic(path, call_node, class_name, mismatch)
          method_label = "`#{call_node.name}' on #{class_name}"
          parameter_label = mismatch[:name] ? "parameter `#{mismatch[:name]}' of #{method_label}" : method_label
          expected = mismatch[:expected]
          expected_description = expected.is_a?(String) ? expected : expected.describe(:short)
          message = "argument type mismatch at #{parameter_label}: " \
                    "expected #{expected_description}, " \
                    "got #{mismatch[:actual].describe(:short)}"
          Diagnostic.from_node(
            mismatch[:node],
            rule: RULE_ARGUMENT_TYPE,
            path: path,
            message: message,
            severity: :error,
            receiver_type: class_name,
            method_name: call_node.name.to_s
          )
        end

        def build_arity_diagnostic(path, call_node, class_name, min, max, actual)
          range = min == max ? min.to_s : "#{min}..#{max}"
          method_label = "`#{call_node.name}' on #{class_name}"
          message = "wrong number of arguments to #{method_label} (given #{actual}, expected #{range})"
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_WRONG_ARITY,
            path: path,
            message: message,
            severity: :error,
            receiver_type: class_name,
            method_name: call_node.name.to_s
          )
        end

        # ADR-8 § "`def.return-type-mismatch` rule" — flags a `def m(...) ... end` whose body's last
        # expression's type cannot satisfy the RBS-declared return type. Conservative envelope (v0.1.x
        # first cut):
        #
        # - Skips methods without an RBS declaration. The rule has no contract to compare against for
        #   source-only methods.
        # - Skips a `def` whose only declaration was resolved through an ANCESTOR. `Reflection`'s lookup
        #   reads the fully resolved method table, so a signature written about a base class answers for
        #   every subclass that inherits the name; comparing an override's body against it reports the
        #   override wrong for disagreeing with a contract that was never written about it (#744, and
        #   the four redmine sites in #856). ADR-35 already specifies this rule as comparing a method's
        #   OWN declared return, and the sibling override rules gate on `defined_on?` — this one did not.
        #   The inherited-declaration signal belongs to the ADR-35 family, which requires both sides
        #   authored. Decided in ADR-110 WD3.
        # - Skips methods whose enclosing `self` names no class (top-level methods land outside the rule).
        # - Skips methods whose body's last expression is absent or types as `Dynamic[top]` (the
        #   analyzer's fail-soft fallback) — emitting on `Dynamic[top]` would be noise.
        # - Compares the inferred body type against the declared return via `accepts?`:
        #     :yes   → silent
        #     :no    → emit at :error (severity_profile may re-stamp; default `balanced` keeps the
        #              authored severity).
        #     :maybe → silent (see {#compare_return}; ADR-8's `strict` promotion is deferred).
        def return_type_mismatch_diagnostic(path, def_node, scope_index, replaced_defs = nil)
          return nil if def_node.body.nil?

          last_expr = body_last_expression(def_node.body)
          return nil if last_expr.nil?

          inner_scope = scope_index[last_expr] || scope_index[def_node.body] || scope_index[def_node]
          return nil if inner_scope.nil?

          declared = declared_return_type(def_node, scope_index, replaced_defs)
          return nil if declared.nil?

          # Issue #1362 — a body that ends on a builtin global still on its declared seed, or on a local copied from
          # one, is judged by the file's writes to the global, as for an argument ({#single_argument_mismatch}).
          inferred = DeclarationSourcedGuard.written_type(last_expr, inner_scope) || inner_scope.type_of(last_expr)
          return nil if dynamic_top?(inferred)

          severity = compare_return(declared, inferred)
          return nil if severity.nil?
          return nil if declared_only_return?(last_expr, inferred, declared, inner_scope)

          build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
        end

        # Issue #1362 — a body that ends on a value mixing a builtin global's seed with something else is judged
        # without the declared members the file never writes, as for an argument.
        def declared_only_return?(last_expr, inferred, declared, scope)
          return false unless DeclarationSourcedGuard.global_sources(last_expr, scope).empty?

          DeclarationSourcedGuard.declared_only_rejection?(inferred, declared, scope) do |stripped|
            compare_return(declared, stripped).nil?
          end
        end

        # The body of a `def` is the last `Prism::StatementsNode` child (or a single expression for
        # one-liner defs). Take the last statement; that's the implicit return.
        def body_last_expression(body)
          case body
          when Prism::StatementsNode then body.body.last
          when Prism::BeginNode then body_last_expression(body.statements)
          else body
          end
        end

        # Pulls the declared RBS return type for the def. The enclosing class name comes from the def's
        # scope's `self_type`; the method name is on the def itself. `def self.foo` is a singleton method
        # — dispatched through `Reflection.singleton_method_definition`; plain `def foo` uses
        # `instance_method_definition`. Method overloads contribute their union of declared return types
        # (any one of them satisfying the body silences the rule).
        #
        # v0.1.2 — when the RBS sig carries a `%a{rigor:v1:return: <refinement>}` annotation (recognised by
        # `RbsExtended.read_return_type_override`), the refinement carrier replaces the RBS-declared return
        # for this rule. Annotation-driven refinements — `non-empty-string`, `positive-int`,
        # `non-empty-array[Integer]`, etc. — are stricter than the underlying RBS class, so a body whose
        # inferred type the bare RBS sig would accept may still fail the refinement (e.g. `def name; "";
        # end` returns `Constant[""]`, accepted by `String` but rejected by `non-empty-string`).
        def declared_return_type(def_node, scope_index, replaced_defs = nil)
          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          side = if def_node.receiver.nil?
                   receiverless_def_side(scope, self_type.class_name, def_node)
                 else
                   receiver_def_side(scope, self_type.class_name, def_node)
                 end
          return nil if side.nil?

          method_def =
            if side == :instance
              Reflection.instance_method_definition(self_type.class_name, def_node.name, scope: scope)
            else
              Reflection.singleton_method_definition(self_type.class_name, def_node.name, scope: scope)
            end
          return nil if method_def.nil?
          return nil unless defined_on?(method_def, self_type.class_name)
          return nil if replaced_receiver_def?(def_node, replaced_defs)

          override = Rigor::RbsExtended.read_return_type_override(method_def, environment: scope.environment)
          return override if override

          declared_return_union(method_def, scope.environment)
        end

        # Which side a receiverless `def` defines, from the indexer's own record of THAT node: the instance table
        # holding it makes it an instance def, the singleton table (`class << self` bodies, and a `def` under
        # `Const.instance_eval` that the indexer attributes to the singleton) a singleton def. A node neither table
        # holds (a `def` in a block whose `self` the engine does not model, such as `E.class_eval do` inside
        # `class << self`, a redefinition a later `def` replaced) or both do is `nil`, and the caller declines: no
        # world is consulted, but the record cannot say which signature the body answers to.
        def receiverless_def_side(scope, class_name, def_node)
          instance = same_def_node?(scope.user_def_for(class_name, def_node.name), def_node)
          singleton = same_def_node?(scope.singleton_def_for(class_name, def_node.name), def_node)
          return :instance if instance && !singleton
          return :singleton if singleton && !instance

          nil
        end

        # Issue #3155 — a singleton def a later certain def replaced ({ReplacedSingletonDefs}). Asked only once the def
        # has a signature to answer to, so the file walk runs only then.
        def replaced_receiver_def?(def_node, replaced_defs)
          !def_node.receiver.nil? && replaced_defs&.replaced?(def_node)
        end

        # Issue #3155 — `def self.x`, or `def K.x` in `K`'s body, answers to K's singleton signature. A def on another
        # object (`def String.q`, `def obj.q` in a class body) or `def self.x` in a `class << self` body (a method of
        # the singleton class's own singleton) answers to none of K's: `nil`, and the caller declines.
        # {#declared_return_type} also declines, once a signature is found, a singleton def a later certain def of the
        # name in the same body replaced (`def K.w`; `def self.w`; {ReplacedSingletonDefs}). `def (self).x` reads as
        # `def self.x`; `K = self; def K.x` is not read.
        def receiver_def_side(scope, class_name, def_node)
          receiver = ReplacedSingletonDefs.unparenthesized(def_node.receiver)
          lexical_self = if receiver.is_a?(Prism::SelfNode)
                           !scope.singleton_class_body?
                         else
                           Inference::ScopeIndexer.def_receiver_targets_lexical_self?(receiver, class_name.split("::"))
                         end
          return nil unless lexical_self

          :singleton
        end

        # The tables hold the live node or one re-resolved from a `DefHandle`, so identity is the name and span.
        def same_def_node?(recorded, def_node)
          recorded.is_a?(Prism::DefNode) && recorded.name == def_node.name &&
            recorded.location.start_offset == def_node.location.start_offset &&
            recorded.location.end_offset == def_node.location.end_offset
        end

        # `type_vars:` — ADR-35 WD9 tier 1. When the caller supplies a generic-instantiation
        # substitution map (parent-side, keyed by the parent class's declared type-parameter names),
        # a `-> T` return is translated at its instantiated type (`-> Integer`) rather than degrading
        # to `Dynamic[Top]`. The default empty map is the pre-WD9 behaviour, under which any type
        # variable degrades to `Dynamic[Top]` and the rule stays silent.
        def declared_return_union(method_def, environment, type_vars: {})
          translated = method_def.method_types.filter_map do |mt|
            Inference::RbsTypeTranslator.translate(
              mt.type.return_type,
              self_type: nil, instance_type: nil, type_vars: type_vars,
              alias_expander: environment&.rbs_loader
            )
          rescue StandardError
            nil
          end
          return nil if translated.empty?

          translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
        end

        def dynamic_top?(type)
          type.is_a?(Type::Dynamic) || (type.respond_to?(:top?) && type.top?.yes?)
        end

        # Returns the severity to emit at, or nil to stay silent. The first-cut implementation only fires
        # on proven (`:no`) mismatches; `:maybe` is treated as silent until the analyzer's narrowing
        # becomes precise enough to avoid noise on common patterns (`{}` → declared `Hash[K, V]`,
        # `Set.new` → declared `Set[Symbol]`, …). ADR-8's promise to emit on `:maybe` under
        # `severity_profile: strict` is deferred to a follow-up that lands together with the narrowing
        # precision improvements.
        def compare_return(declared, inferred)
          result = declared.accepts(inferred)
          return nil unless result.no?

          :error
        end

        def build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_RETURN_TYPE,
            path: path,
            message: "return-type mismatch on `#{def_node.name}': " \
                     "declared #{declared.describe(:short)}, inferred #{inferred.describe(:short)}",
            severity: severity,
            method_name: def_node.name.to_s
          )
        end

        # ADR-35 slice 1 — `def.override-visibility-reduced`. The Liskov signature rule for visibility: an
        # instance-method override MUST NOT reduce the visibility it inherits (public → protected/private,
        # or protected → private), because a caller holding the supertype that invokes the method breaks
        # when handed the subtype.
        #
        # Slice-1 scope (ADR-35 WD1, visibility carve-out): both the override and the shadowed method must
        # have a STATICALLY OBSERVABLE visibility. The override's visibility is read from the
        # source-discovered table; the parent is resolved against the project-discovered ancestor chain
        # (user-source classes / modules only — RBS-known ancestors, whose accessibility RBS models as
        # public/private only, are a deferred follow-on). When either side is not observable the rule stays
        # silent.
        def override_visibility_diagnostic(path, def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only
          return nil if IMPLICITLY_PRIVATE_METHODS.include?(def_node.name)

          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name.to_s
          method_name = def_node.name

          override_visibility = scope.discovered_method_visibility(class_name, method_name)
          return nil if override_visibility.nil?
          # Issue #2013 — a contested slot (a later `define_method` or alias gave the name another visibility, or a
          # write the walk cannot place) proves no reduction.
          return nil if scope.discovery.contested?(:discovered_method_visibilities, [class_name, method_name])

          parent = nearest_ancestor_visibility(scope, class_name, method_name)
          return nil if parent.nil?

          parent_class, parent_visibility = parent
          # Unknown ancestor visibility (e.g. the defining file was not in the analyzed set) → cannot
          # prove a reduction, stay silent.
          return nil if parent_visibility.nil?
          return nil unless visibility_reduced?(parent_visibility, override_visibility)
          # Issue #1569 — a module function's instance copy is private because `module_function` made it so; the
          # author's intent is the public singleton copy, so that reduction is not reported.
          return nil if scope.module_function_def?(class_name, def_node)

          build_override_visibility_diagnostic(
            path, def_node, parent_class, parent_visibility, override_visibility
          )
        end

        # Returns true when `override_visibility` is strictly more restrictive than `parent_visibility`
        # under the public > protected > private ordering.
        #
        # The nil guard below is defence, not dead code. `VISIBILITY_RANK` is a closed literal hash read
        # with a dynamic key, so a symbol outside the table reads as nil at runtime. The engine folds that
        # read to the nil-free value union `0 | 1 | 2`, which `internal-spec/inference-engine.md` declares
        # OPTIMISTIC rather than proof — and since issue #313 that mark survives the `.nil?` fold and the
        # `||` composition, so no suppression directive is needed here.
        def visibility_reduced?(parent_visibility, override_visibility)
          parent_rank = VISIBILITY_RANK[parent_visibility]
          override_rank = VISIBILITY_RANK[override_visibility]
          return false if parent_rank.nil? || override_rank.nil?

          override_rank < parent_rank
        end

        # The project ancestors whose definitions `class_name`'s own `def` OVERRIDES are the entries AFTER the
        # class on its {Scope::ResolutionChain}, nearest first; {#nearest_ancestor_visibility} and
        # {#nearest_ancestor_method_def} each read the first of them that answers their question through
        # `Inference::DefinerResolution` (ADR-119 C1c), `from:` the position after the class. Both are instance
        # side only: the singleton override rules do not exist, and the singleton side's own read lands with
        # ADR-119's singleton design.
        #
        # Issue #1568 — the walk this replaced was breadth-first from the class's direct ancestors, and those
        # include the modules the class PREPENDS. A prepended module sits BEFORE the class in Ruby's order: its
        # `def` overrides the class's, not the other way round, so `prepend P` with a public `P#foo` and a
        # private `C#foo` reported `C#foo` as reducing `P#foo`'s visibility. It also reached `Base` before a
        # module included through an included module (#1567's order).
        #
        # ADR-119 WD3 — for the two override lints *absent* always counts: a chain that does not settle (a mixin
        # whose position the tables cannot vouch for, a fork whose worlds disagree, a conditional or
        # block-scoped `include`), or an external ancestor ahead of the parent that RBS does not know or knows
        # and declares the name in, is `UNKNOWN`, and the lint stays silent rather than answer from the
        # breadth-first order the walk used before (`Scope::ResolutionChain::MasterOrder`) where the order is
        # not known. The two lints read only the `[owner, value]` of a `Known`.
        #
        # ADR-46 slice 3 — an ancestor the project does not declare ends the walk's reach into it, and a class
        # defined LATER under that name would change the answer; `DefinerResolution` files the negative class
        # edge of each external entry it tests.
        def overridden_ancestors_start(scope, class_name)
          # Issue #2979 — past the entries of the names bound to the same class (`K = Struct.new("Named", …)`):
          # a `def` there redefines the class's method rather than overriding an ancestor's.
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :instance, :methods)
          chain.ancestors_start(scope, class_name.to_s)
        end

        # `[defining_class, visibility]` for the nearest user-source ancestor that defines an instance
        # method `method_name`, or nil.
        def nearest_ancestor_visibility(scope, class_name, method_name)
          from = overridden_ancestors_start(scope, class_name)
          return nil if from.nil?

          case Inference::DefinerResolution.resolve(scope, class_name, method_name, :instance,
                                                    question: :override, from: from) do |ancestor|
                 # Stop at the nearest ancestor that DEFINES the method; its visibility may be nil (unknown) —
                 # the caller treats unknown as "cannot prove a reduction" and stays silent. Never fabricate
                 # `:public` from a missing entry (that produced a large false-positive cluster on
                 # cross-file Rails concerns). The `:unrecorded` marker stands for that nil in the answer.
                 next unless scope.user_def_for(ancestor, method_name)

                 scope.discovered_method_visibility(ancestor, method_name) || :unrecorded
               end
          in Inference::DefinerResolution::Known(answer: [owner, visibility])
            [owner, visibility == :unrecorded ? nil : visibility]
          in Inference::DefinerResolution::UNKNOWN # the case/in contract needs one arm per answer
            nil
          in Inference::DefinerResolution::ABSENT # rubocop:disable Lint/DuplicateBranch -- see above
            nil
          end
        end

        def build_override_visibility_diagnostic(path, def_node, parent_class, parent_visibility, override_visibility)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_VISIBILITY_REDUCED,
            path: path,
            message: "visibility of `#{def_node.name}' reduced from #{parent_visibility} to " \
                     "#{override_visibility} (overrides #{parent_class}##{def_node.name}); " \
                     "breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end

        # The authored-override resolution shared by the Liskov override rules
        # (`def.override-return-widened` and `def.override-param-narrowed`): the def must be an instance
        # method whose own class declares it in RBS, and a project-discovered ancestor must also declare
        # it. Returns `[scope, override_method, parent_class, parent_method]`, or nil (the rule does not
        # fire) when any gate is unmet.
        def resolve_authored_override(def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only (singleton: follow-on)
          return nil if LIFECYCLE_HOOKS.include?(def_node.name) # ADR-35 WD10: outside substitutability

          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name.to_s
          method_name = def_node.name

          override_method = safe_instance_method_definition(class_name, method_name, scope)
          return nil if override_method.nil?
          return nil unless defined_on?(override_method, class_name)

          parent = nearest_ancestor_method_def(scope, class_name, method_name)
          return nil if parent.nil?

          parent_class, parent_method = parent
          [scope, override_method, parent_class, parent_method]
        end

        # ADR-35 slice 2 — `def.override-return-widened`. The Liskov signature rule for returns
        # (covariance): an override may *narrow* the return it inherits (return a more specific type) but
        # MUST NOT *widen* it. A caller holding the supertype uses the result as the parent's return type;
        # a wider override return breaks that use.
        #
        # WD1 gate (proper, type-direction): both the override and the shadowed ancestor method must carry
        # an explicitly-authored RBS signature. The override side is gated by `defined_on?` (the RBS
        # method is declared on the overriding class itself, not merely inherited); the parent side is the
        # nearest project-discovered ancestor whose RBS declares the method. Inference-only either side →
        # silent.
        #
        # Fires only on a proven (`:no`) widening; generic / `untyped` / `self` parent returns degrade to
        # `Dynamic[Top]` and accept everything, so they stay silent (FP-safe). `self`/`instance` are
        # translated with `self_type: nil` on both sides, so a parent `-> self` and an override `-> self`
        # never fire.
        def override_return_widened_diagnostic(path, def_node, scope_index)
          resolved = resolve_authored_override(def_node, scope_index)
          return nil if resolved.nil?

          scope, override_method, parent_class, parent_method = resolved
          parent_type_vars = ancestor_instantiation_type_vars(scope, parent_class)
          override_return = declared_return_union(override_method, scope.environment)
          parent_return = declared_return_union(parent_method, scope.environment, type_vars: parent_type_vars)
          return nil if override_return.nil? || parent_return.nil?
          return nil if dynamic_top?(parent_return) # untyped / unbound-generic parent contract
          return nil if void_over_nil?(override_method, parent_return)

          return nil unless parent_return.accepts(override_return).no?

          build_override_return_widened_diagnostic(
            path, def_node, parent_class, parent_return, override_return
          )
        end

        # A `-> void` override of a parent return of exactly `nil` (or `NilClass`) is exempt (#3046): both
        # say "no useful value", and callers cannot use a void return. Keyed on the declared `void` of every
        # arm (the translator reads `void` as top, so a `-> top` override still fires); any non-nil parent
        # return still fires.
        def void_over_nil?(override_method, parent_return)
          return false unless nil_type?(parent_return)

          override_method.method_types.all? { |mt| mt.type.return_type.is_a?(::RBS::Types::Bases::Void) }
        end

        # `nil`, or the nominal `NilClass`, whose only value it is.
        def nil_type?(type)
          return type.value.nil? if type.is_a?(Type::Constant)

          type.is_a?(Type::Nominal) && type.class_name == "NilClass" && type.type_args.empty?
        end

        # `[defining_class, RBS::Definition::Method]` for the nearest project-discovered ancestor whose
        # RBS declares `method_name` (not the starting class's own declaration), or nil.
        def nearest_ancestor_method_def(scope, class_name, method_name)
          from = overridden_ancestors_start(scope, class_name)
          return nil if from.nil?

          passed_owners = []
          case Inference::DefinerResolution.resolve(scope, class_name, method_name, :instance,
                                                    question: :override, from: from) do |ancestor|
                 override_parent_answer(scope, ancestor, method_name, passed_owners)
               end
          in Inference::DefinerResolution::Known(owner:, answer:)
            # The nearest declaration must be the one that answers: an ancestor asked past for a project
            # owner the walk never reached (one the Ruby chain does not hold) leaves the rule silent.
            unless answer.last == RBS_ONLY_OWNER ||
                   passed_owners.any? { |passed| passed != normalize_class_name(owner) }
              method_def = safe_instance_method_definition(owner, method_name, scope)
              method_def && [owner, method_def]
            end
          in Inference::DefinerResolution::UNKNOWN # the case/in contract needs one arm per answer
            nil
          in Inference::DefinerResolution::ABSENT # rubocop:disable Lint/DuplicateBranch -- see above
            nil
          end
        end

        # The answer an RBS-only owner gives the override walk: it ends the walk, and the rule stays silent.
        RBS_ONLY_OWNER = :rbs_only_owner
        private_constant :RBS_ONLY_OWNER

        # One project ancestor's answer to the override walk. The signature text is the answer two worlds
        # compare: an `RBS::Definition::Method` has no structural equality of its own. Only an ancestor whose
        # own RBS declares the method answers with it (#3046). One that inherits the declaration from another
        # project class or module is asked past, so that owner answers at its own entry; the owner is recorded
        # in `passed_owners`, which the answering owner must match. One that inherits it from an RBS-only owner
        # the project chain cannot see ends the walk silent ({RBS_ONLY_OWNER}): that owner is the nearest
        # declaration, and RBS-only ancestors are #130's.
        def override_parent_answer(scope, ancestor, method_name, passed_owners)
          method_def = safe_instance_method_definition(ancestor, method_name, scope)
          return nil if method_def.nil?
          return method_def.method_types.map(&:to_s) if declared_by?(method_def, ancestor)

          owner = method_def.implemented_in || method_def.defined_in
          return RBS_ONLY_OWNER unless owner && scope.discovered_classes.key?(normalize_class_name(owner))

          passed_owners << normalize_class_name(owner)
          nil
        end

        # True when `ancestor`'s own RBS declares `method_def`: on its body, or through an interface it
        # includes itself (RBS records the including class as `implemented_in`).
        def declared_by?(method_def, ancestor)
          return true if defined_on?(method_def, ancestor)
          return false unless method_def.defined_in&.interface?

          normalize_class_name(method_def.implemented_in) == normalize_class_name(ancestor)
        end

        def safe_instance_method_definition(class_name, method_name, scope)
          Reflection.instance_method_definition(class_name, method_name, scope: scope)
        rescue StandardError
          nil
        end

        # True when `method_def`'s RBS declaration lives on `class_name` itself (rather than being
        # inherited from an ancestor).
        def defined_on?(method_def, class_name)
          defined_in = method_def.defined_in
          return false if defined_in.nil?

          normalize_class_name(defined_in.to_s) == normalize_class_name(class_name)
        end

        def normalize_class_name(name)
          name.to_s.delete_prefix("::")
        end

        # ADR-35 WD9 tier 1 — generic-instantiation-aware comparison. Builds the substitution map
        # `{ parent_type_param_name => instantiated Rigor::Type }` for the parent contract as the
        # overriding subclass instantiates it (RBS `class Sub < Parent[Concrete]` / `include
        # _Iface[Concrete]`). Mirrors the ADR-4 Phase 2d dispatcher zip (`build_type_vars`): the
        # parent's declared type-parameter names zipped against the subclass-side instantiation args.
        #
        # Returns `{}` — restoring the pre-WD9 behaviour under which any parent type variable degrades
        # to `Dynamic[Top]` and the rule stays silent — whenever the subclass does not instantiate the
        # ancestor generically, the RBS definition cannot be built, arities disagree, or an argument
        # fails to translate. This is the FP-safety contract: substitution only ever *adds* precision
        # (a `-> T` compared at `-> Integer`); an unbound / unresolved generic keeps degrading to
        # silence, never a false `:no`.
        def ancestor_instantiation_type_vars(scope, parent_class)
          self_type = scope.self_type
          return {} unless self_type.respond_to?(:class_name)

          args = ancestor_instantiation_args(scope, self_type.class_name.to_s, parent_class)
          return {} if args.nil? || args.empty?

          param_names = Reflection.class_type_param_names(parent_class, scope: scope)
          return {} if param_names.empty? || param_names.size != args.size

          translated = args.map do |arg|
            Inference::RbsTypeTranslator.translate(
              arg, self_type: nil, instance_type: nil, type_vars: {},
                   alias_expander: scope.environment&.rbs_loader
            )
          rescue StandardError
            nil
          end
          return {} if translated.any?(&:nil?)

          param_names.zip(translated).to_h
        end

        # The RBS type arguments the subclass applies to `parent_class` in its ancestry, or nil when
        # the subclass has no RBS definition or does not name that ancestor. Reads the resolved
        # instance-ancestor list (`RBS::Definition#ancestors`), whose `Ancestor::Instance` entries carry
        # the instantiation `.args` for each superclass / included module. Fail-soft: any RBS build
        # error yields nil, which the caller treats as "no instantiation" and degrades to silence.
        def ancestor_instantiation_args(scope, subclass_name, parent_class)
          definition = Reflection.instance_definition(subclass_name, scope: scope)
          return nil if definition.nil?

          target = normalize_class_name(parent_class)
          ancestor = definition.ancestors.ancestors.find do |anc|
            anc.respond_to?(:args) && normalize_class_name(anc.name.to_s) == target
          end
          ancestor&.args
        rescue ::RBS::BaseError, StandardError
          nil
        end

        def build_override_return_widened_diagnostic(path, def_node, parent_class, parent_return, override_return)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_RETURN_WIDENED,
            path: path,
            message: "return type of `#{def_node.name}' widened from #{parent_return.describe(:short)} " \
                     "to #{override_return.describe(:short)} (overrides #{parent_class}##{def_node.name}); " \
                     "breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end

        # ADR-35 slice 3 — `def.override-param-narrowed`. The Liskov signature rule for parameters
        # (contravariance): an override may *widen* a parameter (accept a supertype — accepting more is
        # safe) but MUST NOT *narrow* it. A caller holding the supertype passes a parent-typed argument; a
        # narrowed override parameter cannot accept it.
        #
        # Direction (ADR-35 WD3, corrected): fire on `override_param.accepts(parent_param) == :no` — the
        # override's (narrowed) slot cannot accept the wider parent argument type. WD4: type comparison at
        # matching POSITIONAL parameter indices only; arity / keyword-requiredness divergence is out of
        # scope for v1. Same WD1 both-sides-authored gate as slice 2; `untyped` / unbound-generic /
        # interface parent params degrade to `Dynamic[Top]` and are skipped (FP-safe). To avoid
        # overload-arm ambiguity, both sides must have exactly one method type.
        def override_param_narrowed_diagnostic(path, def_node, scope_index)
          resolved = resolve_authored_override(def_node, scope_index)
          return nil if resolved.nil?

          scope, override_method, parent_class, parent_method = resolved
          parent_type_vars = ancestor_instantiation_type_vars(scope, parent_class)
          override_params = positional_param_types(override_method, environment: scope.environment)
          parent_params = positional_param_types(parent_method, type_vars: parent_type_vars,
                                                                environment: scope.environment)
          return nil if override_params.nil? || parent_params.nil?

          index = first_narrowed_param_index(override_params, parent_params)
          return nil if index.nil?

          build_override_param_narrowed_diagnostic(
            path, def_node, parent_class, index, parent_params[index], override_params[index]
          )
        end

        # Translated positional (required + optional) parameter types of a method's single method type, or
        # nil when the method is overloaded (multiple method types — arm mapping is ambiguous) or the
        # parameter list is not introspectable. Per-position translation failures yield `nil` at that slot
        # (skipped by the comparison). `self`/`instance` translate with `self_type: nil` (→
        # `Dynamic[Top]`), matching the return-side handling.
        # `type_vars:` — ADR-35 WD9 tier 1, parent side only. Substitutes the generic-instantiation
        # map (parent class's type params → the subclass's instantiation) so a parent `(T)` parameter
        # is compared at its instantiated type. Empty (the default, and the override side) keeps the
        # pre-WD9 degrade-to-`Dynamic[Top]` behaviour.
        def positional_param_types(method_def, type_vars: {}, environment: nil)
          method_types = method_def.method_types
          return nil unless method_types.size == 1

          func = method_types.first.type
          return nil unless func.respond_to?(:required_positionals)

          (func.required_positionals + func.optional_positionals).map do |param|
            Inference::RbsTypeTranslator.translate(
              param.type, self_type: nil, instance_type: nil, type_vars: type_vars,
                          alias_expander: environment&.rbs_loader
            )
          rescue StandardError
            nil
          end
        end

        # Index of the first positional parameter the override narrows relative to the parent, or nil. A
        # position is a violation when the override's slot cannot accept the parent's argument type
        # (`override_param.accepts(parent_param) == :no`). Positions where either side is
        # missing/untranslatable, or the parent type degraded to `Dynamic[Top]` (untyped / unbound generic
        # / interface), are skipped.
        def first_narrowed_param_index(override_params, parent_params)
          count = [override_params.size, parent_params.size].min
          count.times do |i|
            override_param = override_params[i]
            parent_param = parent_params[i]
            next if override_param.nil? || parent_param.nil?
            next if dynamic_top?(parent_param) || dynamic_top?(override_param)

            return i if override_param.accepts(parent_param).no?
          end
          nil
        end

        def build_override_param_narrowed_diagnostic(path, def_node, parent_class, index, parent_param, override_param)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_PARAM_NARROWED,
            path: path,
            message: "parameter #{index + 1} of `#{def_node.name}' narrowed from " \
                     "#{parent_param.describe(:short)} to #{override_param.describe(:short)} " \
                     "(overrides #{parent_class}##{def_node.name}); breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end
      end
    end
  end
end
