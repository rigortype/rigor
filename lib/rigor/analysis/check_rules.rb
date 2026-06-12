# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../source/node_walker"
require_relative "../type"
require_relative "diagnostic"
require_relative "dependency_recorder"
require_relative "check_rules/rule_walk"
require_relative "check_rules/always_truthy_condition_collector"
require_relative "check_rules/unreachable_clause_collector"
require_relative "check_rules/dead_assignment_collector"
require_relative "check_rules/ivar_write_collector"
require_relative "check_rules/self_closedness_scanner"

module Rigor
  module Analysis
    # First-preview catalogue of `rigor check` diagnostic rules.
    #
    # The rules are intentionally narrow: they fire ONLY when the
    # engine is confident enough to make a useful claim, and they
    # MUST NOT raise on unrecognised AST shapes, RBS gaps, or
    # missing scope information. Each rule consumes the per-node
    # scope index produced by
    # `Rigor::Inference::ScopeIndexer.index` and yields zero or
    # more `Rigor::Analysis::Diagnostic` values.
    #
    # The first shipped rule, `UndefinedMethodOnTypedReceiver`,
    # flags an explicit-receiver `Prism::CallNode` whose receiver
    # statically resolves to a `Type::Nominal` or `Type::Singleton`
    # known to the analyzer's RBS environment AND whose method
    # name does not appear on that class's instance / singleton
    # method table. This is the canonical "type check" signal
    # ("Foo has no method bar"), but it explicitly does NOT fire
    # for:
    #
    # - implicit-self calls (no `node.receiver`) — too noisy
    #   without per-method RBS for every helper in the class.
    # - dynamic / unknown receivers (`Dynamic[T]`, `Top`, `Union`)
    #   — by definition we cannot enumerate the method set.
    # - shape carriers (`Tuple`, `HashShape`, `Constant`) — their
    #   dispatch goes through `ShapeDispatch` / `ConstantFolding`
    #   which the rule does not yet model.
    # - receivers whose class name is NOT registered in the
    #   loader (RBS-blind environments, unknown stdlib).
    #
    # The above list is the deliberate conservative envelope of
    # the first preview; later slices broaden it.
    # rubocop:disable Metrics/ModuleLength
    module CheckRules
      # Canonical identifiers for each rule. Per ADR-8 §
      # "Diagnostic ID family hierarchy", rule names are
      # `family.rule-name` two-segment strings; the families
      # group diagnostics by where they originate
      # (`call.*` for call-site rules, `flow.*` for flow-analysis
      # proofs, `assert.*` for runtime-assertion rules,
      # `dump.*` for debug helpers, `def.*` for method-definition
      # rules). Used by the configuration `disable:` list and the
      # in-source `# rigor:disable <rule>` suppression comment
      # system; new rules MUST register here so user configuration
      # can refer to them.
      RULE_UNDEFINED_METHOD = "call.undefined-method"
      RULE_SELF_UNDEFINED_METHOD = "call.self-undefined-method"
      RULE_UNRESOLVED_TOPLEVEL = "call.unresolved-toplevel"
      RULE_WRONG_ARITY = "call.wrong-arity"
      RULE_ARGUMENT_TYPE = "call.argument-type-mismatch"
      RULE_NIL_RECEIVER = "call.possible-nil-receiver"
      RULE_DUMP_TYPE = "dump.type"
      RULE_ASSERT_TYPE = "assert.type-mismatch"
      RULE_ALWAYS_RAISES = "flow.always-raises"
      RULE_UNREACHABLE_BRANCH = "flow.unreachable-branch"
      RULE_RETURN_TYPE = "def.return-type-mismatch"
      RULE_VISIBILITY_MISMATCH = "def.method-visibility-mismatch"
      RULE_OVERRIDE_VISIBILITY_REDUCED = "def.override-visibility-reduced"
      RULE_OVERRIDE_RETURN_WIDENED = "def.override-return-widened"
      RULE_OVERRIDE_PARAM_NARROWED = "def.override-param-narrowed"
      RULE_IVAR_WRITE_MISMATCH = "def.ivar-write-mismatch"
      RULE_DEAD_ASSIGNMENT = "flow.dead-assignment"
      RULE_ALWAYS_TRUTHY_CONDITION = "flow.always-truthy-condition"
      RULE_UNREACHABLE_CLAUSE = "flow.unreachable-clause"

      ALL_RULES = [
        RULE_UNDEFINED_METHOD,
        RULE_SELF_UNDEFINED_METHOD,
        RULE_UNRESOLVED_TOPLEVEL,
        RULE_WRONG_ARITY,
        RULE_ARGUMENT_TYPE,
        RULE_NIL_RECEIVER,
        RULE_DUMP_TYPE,
        RULE_ASSERT_TYPE,
        RULE_ALWAYS_RAISES,
        RULE_UNREACHABLE_BRANCH,
        RULE_DEAD_ASSIGNMENT,
        RULE_ALWAYS_TRUTHY_CONDITION,
        RULE_UNREACHABLE_CLAUSE,
        RULE_RETURN_TYPE,
        RULE_VISIBILITY_MISMATCH,
        RULE_OVERRIDE_VISIBILITY_REDUCED,
        RULE_OVERRIDE_RETURN_WIDENED,
        RULE_OVERRIDE_PARAM_NARROWED,
        RULE_IVAR_WRITE_MISMATCH
      ].freeze

      # Backward-compat alias table (ADR-8 § "Backward
      # compatibility"). Existing user code with
      # `# rigor:disable undefined-method` /
      # `disable: [undefined-method]` keeps working — the
      # legacy unprefixed identifiers map to their canonical
      # `family.rule-name` form here. Removing the aliases is
      # a future ADR once user code has migrated; until then,
      # both spellings resolve identically.
      LEGACY_RULE_ALIASES = {
        "undefined-method" => RULE_UNDEFINED_METHOD,
        "self-undefined-method" => RULE_SELF_UNDEFINED_METHOD,
        "wrong-arity" => RULE_WRONG_ARITY,
        "argument-type-mismatch" => RULE_ARGUMENT_TYPE,
        "possible-nil-receiver" => RULE_NIL_RECEIVER,
        "dump-type" => RULE_DUMP_TYPE,
        "assert-type" => RULE_ASSERT_TYPE,
        "always-raises" => RULE_ALWAYS_RAISES,
        "unreachable-branch" => RULE_UNREACHABLE_BRANCH,
        "method-visibility-mismatch" => RULE_VISIBILITY_MISMATCH,
        "ivar-write-mismatch" => RULE_IVAR_WRITE_MISMATCH,
        "dead-assignment" => RULE_DEAD_ASSIGNMENT,
        "always-truthy-condition" => RULE_ALWAYS_TRUTHY_CONDITION,
        "unreachable-clause" => RULE_UNREACHABLE_CLAUSE
      }.freeze

      # Family wildcard — a `<family>` token in a suppression
      # comment or `disable:` list disables every rule whose
      # canonical id starts with `<family>.`. Per ADR-8 § "1".
      RULE_FAMILIES = %w[call flow assert dump def].freeze

      # ADR-35 slice 1 — bound for the `def.override-visibility-reduced`
      # ancestor walk, and the public > protected > private ordering
      # used to decide whether an override reduces visibility.
      OVERRIDE_ANCESTOR_WALK_LIMIT = 100
      VISIBILITY_RANK = { public: 2, protected: 1, private: 0 }.freeze

      # Resolves a user-supplied rule token (`undefined-method`,
      # `call.undefined-method`, or the family wildcard `call`)
      # to the set of canonical rule identifiers it disables.
      # Returns `nil` for `"all"` (the existing wildcard meaning
      # "every rule"), or for unknown tokens.
      def self.resolve_rule_token(token)
        return nil if token == "all"
        return [LEGACY_RULE_ALIASES.fetch(token)] if LEGACY_RULE_ALIASES.key?(token)
        return ALL_RULES.select { |r| r.start_with?("#{token}.") } if RULE_FAMILIES.include?(token)

        ALL_RULES.include?(token) ? [token] : []
      end

      module_function

      # Yields diagnostics for every unrecognised method call on
      # a typed receiver in `root`'s subtree. The caller MUST
      # have already produced `scope_index` through
      # `Rigor::Inference::ScopeIndexer.index(root, default_scope:)`.
      #
      # @param path [String] used to populate
      #   `Diagnostic#path`; the rule does not open files.
      # @param root [Prism::Node]
      # @param scope_index [Hash{Prism::Node => Rigor::Scope}]
      # @return [Array<Rigor::Analysis::Diagnostic>]
      def diagnose(path:, root:, scope_index:, self_call_misses: [], comments: [], disabled_rules: [])
        diagnostics = []
        Source::NodeWalker.each(root) do |node|
          case node
          when Prism::CallNode
            diagnostics.concat(call_node_diagnostics(path, node, scope_index))
          when Prism::DefNode
            return_diagnostic = return_type_mismatch_diagnostic(path, node, scope_index)
            diagnostics << return_diagnostic if return_diagnostic
            override_vis = override_visibility_diagnostic(path, node, scope_index)
            diagnostics << override_vis if override_vis
            override_return = override_return_widened_diagnostic(path, node, scope_index)
            diagnostics << override_return if override_return
            override_param = override_param_narrowed_diagnostic(path, node, scope_index)
            diagnostics << override_param if override_param
          when Prism::IfNode, Prism::UnlessNode
            unreachable = unreachable_branch_diagnostic(path, node, scope_index)
            diagnostics << unreachable if unreachable
          end
        end
        diagnostics.concat(self_undefined_method_diagnostics(path, self_call_misses, root, scope_index))
        always_truthy_results, unreachable_clause_results = flow_collector_results(root, scope_index)
        diagnostics.concat(always_truthy_condition_diagnostics(path, always_truthy_results))
        diagnostics.concat(unreachable_clause_diagnostics(path, unreachable_clause_results))
        diagnostics.concat(ivar_write_mismatch_diagnostics(path, root, scope_index))
        diagnostics.concat(dead_assignment_diagnostics(path, root, scope_index))
        filter_suppressed(diagnostics, comments: comments, disabled_rules: disabled_rules)
      end

      # ADR-53 Track B (slice B2) — both flow collectors ride one
      # {RuleWalk} traversal instead of walking the file once each.
      # Under `RIGOR_SHADOW_RULE_WALK=1` the legacy per-collector walks
      # also run as the oracle and any divergence aborts the run — the
      # corpus-scale half of the equivalence harness (the curated half
      # is `rule_walk_equivalence_spec`).
      def flow_collector_results(root, scope_index)
        always_truthy = AlwaysTruthyConditionCollector.new(scope_index)
        unreachable_clauses = UnreachableClauseCollector.new(scope_index)
        RuleWalk.run(root, [always_truthy, unreachable_clauses])
        if ENV["RIGOR_SHADOW_RULE_WALK"]
          shadow_verify_flow_collectors(root, scope_index, always_truthy.results, unreachable_clauses.results)
        end
        [always_truthy.results, unreachable_clauses.results]
      end

      def shadow_verify_flow_collectors(root, scope_index, always_truthy_results, unreachable_clause_results)
        legacy_always = AlwaysTruthyConditionCollector.new(scope_index).collect(root)
        legacy_clauses = UnreachableClauseCollector.new(scope_index).collect(root)
        return if legacy_always == always_truthy_results && legacy_clauses == unreachable_clause_results

        raise "RIGOR_SHADOW_RULE_WALK divergence: always-truthy legacy=#{legacy_always.size} " \
              "walk=#{always_truthy_results.size}; unreachable-clause legacy=#{legacy_clauses.size} " \
              "walk=#{unreachable_clause_results.size}"
      end

      def call_node_diagnostics(path, node, scope_index)
        [
          undefined_method_diagnostic(path, node, scope_index),
          unresolved_toplevel_diagnostic(path, node, scope_index),
          wrong_arity_diagnostic(path, node, scope_index),
          argument_type_diagnostic(path, node, scope_index),
          nil_receiver_diagnostic(path, node, scope_index),
          dump_type_diagnostic(path, node, scope_index),
          assert_type_diagnostic(path, node, scope_index),
          always_raises_diagnostic(path, node, scope_index),
          visibility_mismatch_diagnostic(path, node, scope_index)
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
      def ivar_write_mismatch_diagnostics(path, root, scope_index)
        IvarWriteCollector.new(scope_index).collect(root).flat_map do |class_name, writes_by_ivar|
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
      def dead_assignment_diagnostics(path, root, scope_index)
        DeadAssignmentCollector.new(scope_index).collect(root).map do |result|
          build_dead_assignment_diagnostic(path, result[:write_node], result[:def_node])
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

      # ADR-47 — `flow.unreachable-clause`. One diagnostic per `when` clause
      # the flow engine's narrowing proves can never match (its narrowed
      # subject is `bot`). The squiggle lands on the dead clause's body,
      # mirroring `flow.unreachable-branch`.
      def unreachable_clause_diagnostics(path, results)
        results.map do |result|
          build_unreachable_clause_diagnostic(path, result)
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

          build_ivar_write_mismatch_diagnostic(path, write[:node], class_name, ivar_name, first_class, other_class)
        end
      end

      # v0.0.2 #6 — diagnostic suppression. Three kinds of
      # suppression compose:
      #
      # - **Project-level**: `disabled_rules` is the
      #   project's `.rigor.yml` `disable:` list. Any
      #   diagnostic whose `rule` is in the list is dropped.
      # - **File-level** (v0.1.2): `# rigor:disable-file <rule1>,
      #   <rule2>` anywhere in the file suppresses the matching
      #   diagnostic for every line. `# rigor:disable-file all`
      #   suppresses every rule across the file. Convention is
      #   to put the comment near the top, but Rigor accepts it
      #   anywhere — the comment scope is "this file" regardless
      #   of position.
      # - **In-source line**: `# rigor:disable <rule1>, <rule2>`
      #   on the same line as the offending expression
      #   suppresses the matching diagnostic for that line
      #   only. `# rigor:disable all` on a line suppresses
      #   every rule on that line.
      #
      # Diagnostics with `rule == nil` (parse errors, path
      # errors, internal analyzer errors) are NEVER
      # suppressed — they represent failures the user cannot
      # silence away.
      def filter_suppressed(diagnostics, comments:, disabled_rules:)
        line_suppressions, file_suppressions = parse_suppression_comments(comments)
        disabled = expand_rule_tokens(disabled_rules)

        diagnostics.reject do |diagnostic|
          rule = diagnostic.rule
          next false if rule.nil?
          next true if disabled.include?(rule)
          next true if file_suppressions.include?("all") || file_suppressions.include?(rule)

          line_rules = line_suppressions[diagnostic.line]
          line_rules && (line_rules.include?("all") || line_rules.include?(rule))
        end
      end

      LINE_SUPPRESSION_PATTERN = /#\s*rigor:disable(?!-file)\s+(?<rules>[\w.,\s-]+)/
      private_constant :LINE_SUPPRESSION_PATTERN

      FILE_SUPPRESSION_PATTERN = /#\s*rigor:disable-file\s+(?<rules>[\w.,\s-]+)/
      private_constant :FILE_SUPPRESSION_PATTERN

      # @return [Array<(Hash{Integer => Set}, Set)>] pair of
      #   `(line_suppressions, file_suppressions)`. Line
      #   suppressions are keyed by source line number; file
      #   suppressions apply to every line.
      def parse_suppression_comments(comments)
        line_suppressions = Hash.new { |h, k| h[k] = Set.new }
        file_suppressions = Set.new
        comments.each do |comment|
          source = comment.location.slice
          if (match = FILE_SUPPRESSION_PATTERN.match(source))
            absorb_suppression_tokens(match[:rules], file_suppressions)
          elsif (match = LINE_SUPPRESSION_PATTERN.match(source))
            absorb_suppression_tokens(match[:rules], line_suppressions[comment.location.start_line])
          end
        end
        [line_suppressions, file_suppressions]
      end

      def absorb_suppression_tokens(raw, target)
        raw.to_s.split(/[\s,]+/).reject(&:empty?).each do |token|
          target.merge(expand_token(token))
        end
      end

      # Expands a list of user-supplied rule tokens into the
      # canonical-id set per ADR-8 § "Backward compatibility".
      # `disabled_rules` accepts unprefixed legacy names
      # (`undefined-method`), canonical names
      # (`call.undefined-method`), and family wildcards (`call`).
      def expand_rule_tokens(tokens)
        Array(tokens).each_with_object(Set.new) do |token, set|
          set.merge(expand_token(token.to_s))
        end
      end

      def expand_token(token)
        return ["all"] if token == "all"

        resolved = resolve_rule_token(token)
        resolved.nil? || resolved.empty? ? [token] : resolved
      end

      # rubocop:disable Metrics/ClassLength
      class << self
        private

        def undefined_method_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?

          scope = scope_index[call_node]
          return nil if scope.nil?

          # N3 — a safe-navigation call (`recv&.m`) never dispatches on the
          # nil edge of its receiver: at runtime it short-circuits to nil.
          # A receiver that types as exactly `nil` yields nil with no call at
          # all, so it is silent (no dead-code diagnostic — `&.` is the
          # nil-skip operator by design, and frightening working
          # `@x = nil; @x&.m` code would breach FP discipline). A nil-bearing
          # *union* receiver is left to flow through unchanged: a `T | nil`
          # union has no single concrete class, so the rule already bails
          # below — preserving that keeps `&.` from newly firing on the
          # non-nil constituent (which, for a cross-file project def, would
          # be a working-code false positive).
          receiver_type = safe_navigation_receiver(call_node, scope)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # ADR-26 — a plugin may declare a class "open": one
          # known to respond beyond its RBS-declared method
          # surface (e.g. `ActiveRecord::Relation`, which
          # delegates an unbounded set of user-defined scopes to
          # its model). Flagging an undefined method on a class
          # with an open dynamic surface is unsound, so the rule
          # skips it.
          # An unbounded receiver surface: either a plugin-declared
          # open receiver (ADR-26 — e.g. `ActiveRecord::Relation`), or
          # a type Rigor synthesized (a missing-namespace module / a
          # stub for a referenced-but-undeclared type) to keep a
          # malformed project signature buildable. A synthesized stub's
          # method table is empty only because Rigor invented it, not
          # because the real type is empty (the real `DRb` has
          # `start_service`), so enumerating it to prove a call
          # "undefined" would be a false positive.
          return nil if unbounded_receiver_surface?(class_name, scope)

          # Slice 7 phase 12 — suppress when the user has
          # declared the method in source (`def` /
          # `define_method`) OR in a `pre_eval:` monkey-patch
          # file (ADR-17). Both paths are project-side method
          # contributions the dispatcher already resolved; the
          # rule must not surface a false `undefined-method`
          # for them.
          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          return nil if source_declared_method?(scope, class_name, call_node.name, kind)

          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          # When the loader cannot build a class definition for a
          # name it nominally knows (constant-decl aliases such
          # as `YAML` → `Psych`, or RBS-build failures for
          # malformed signatures), we cannot enumerate methods
          # so we MUST NOT emit a false positive. Skip the rule
          # in that case.
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def

          # Module-mixin fallback (mirror of
          # `MethodDispatcher#user_class_fallback_receiver`'s module
          # path): an instance method on a module-mixin like
          # `PP::ObjectMixin` observes Kernel / Object methods
          # through every concrete includer's ancestor chain, so an
          # unresolved `self.inspect` / `self.respond_to?` /
          # `self.class` MUST NOT fire `undefined-method`. Retry
          # against Object before the rule fires.
          return nil if module_mixin_receiver?(receiver_type, scope) &&
                        lookup_method(receiver_type, "Object", call_node.name, scope)

          definition_site = project_definition_site(scope, class_name, call_node.name, kind)
          build_undefined_method_diagnostic(path, call_node, receiver_type, definition_site, class_name)
        end

        # ADR-17 — when the project itself defines this method on the
        # receiver class somewhere in the analyzed file set (a reopened
        # core/stdlib/gem class the dispatcher does not apply cross-
        # file), return that `"path:line"` site so the diagnostic points
        # at `pre_eval:` instead of reading as a bare unresolved call.
        # Instance-side only (the cross-file def-source index tracks
        # `def` instance methods); the diagnostic still fires — Rigor
        # does not auto-apply project monkey-patches (the full-project
        # pre-pass is deferred per ADR-17 slice 5) — but it is now
        # actionable rather than mistakable for a typo.
        def project_definition_site(scope, class_name, method_name, kind)
          return nil unless kind == :instance

          scope.user_def_site_for(class_name, method_name)
        end

        def module_mixin_receiver?(receiver_type, scope)
          return false unless receiver_type.is_a?(Type::Nominal)
          return false if scope.environment.nil?

          scope.environment.rbs_module?(receiver_type.class_name)
        end

        # Combined suppression probe for `undefined-method` /
        # `unresolved-toplevel`. Returns true when the method is
        # declared by any project-side contributor the dispatcher
        # already resolves: an in-source `def` / `define_method`
        # (`scope.discovered_method?`) OR an ADR-17 `pre_eval:`
        # monkey-patch (`Environment#project_patched_methods`).
        # Both paths sit at the same dispatcher precedence; the
        # check must hold them together so neither rule fires a
        # false positive.
        def source_declared_method?(scope, class_name, method_name, kind)
          return true if scope.discovered_method?(class_name, method_name, kind)

          project_patched_method?(scope, class_name, method_name, kind)
        end

        # ADR-17 § "Inference contract" — consults
        # `Environment#project_patched_methods` so a `def` declared
        # in a `pre_eval:` file suppresses the diagnostic at the
        # same dispatcher precedence the registry holds for type
        # inference (between plugins and dependency-source).
        # Returns false when the environment carries no registry
        # (legacy path) or the lookup misses.
        def project_patched_method?(scope, class_name, method_name, kind)
          environment = scope.environment
          registry = environment&.project_patched_methods
          return false if registry.nil? || registry.empty?

          !registry.lookup(class_name: class_name.to_s, method_name: method_name.to_sym, kind: kind).nil?
        end

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
        def unresolved_toplevel_diagnostic(path, call_node, scope_index)
          return nil unless call_node.receiver.nil?

          scope = scope_index[call_node]
          return nil if scope.nil?
          return nil unless scope.toplevel?

          name = call_node.name
          return nil if scope.top_level_def_for(name)
          return nil if source_declared_method?(scope, "Object", name, :instance)
          return nil if Rigor::Reflection.instance_method_definition("Object", name, scope: scope)

          build_unresolved_toplevel_diagnostic(path, call_node)
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

        # Returns a qualified class name for the in-scope check.
        # Nominal / Singleton carry a single-class identity
        # directly. Constant projects to its value's class.
        # Tuple projects to "Array" and HashShape to "Hash" so
        # arity / dispatch checks against the underlying class
        # still apply. Dynamic / Top / Union / Bot do not name a
        # single class and return nil to skip the rule.
        def concrete_class_name(type)
          case type
          when Type::Nominal, Type::Singleton then type.class_name
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
          when Type::Constant then constant_class_name(type.value)
          end
        end

        CONSTANT_CLASSES = {
          Integer => "Integer", Float => "Float", String => "String",
          Symbol => "Symbol", Range => "Range",
          TrueClass => "TrueClass", FalseClass => "FalseClass",
          NilClass => "NilClass"
        }.freeze
        private_constant :CONSTANT_CLASSES

        def constant_class_name(value)
          CONSTANT_CLASSES.each { |klass, name| return name if value.is_a?(klass) }
          nil
        end

        # ADR-26 — whether `class_name` is declared "open" by a
        # loaded plugin (manifest `open_receivers:`). An open
        # class responds beyond its RBS surface, so the
        # `call.undefined-method` rule must not fire for it.
        # True when the receiver class responds beyond an enumerable
        # RBS method table, so proving a call "undefined" against it is
        # unsound: a plugin-declared open receiver, or a Rigor-
        # synthesized stub type (see `RbsLoader#synthesized_type_names`).
        def unbounded_receiver_surface?(class_name, scope)
          open_receiver?(class_name, scope) || synthesized_stub_receiver?(class_name, scope)
        end

        def open_receiver?(class_name, scope)
          registry = scope.environment&.plugin_registry
          return false if registry.nil?

          registry.open_receiver?(class_name)
        end

        def synthesized_stub_receiver?(class_name, scope)
          loader = scope.environment&.rbs_loader
          return false if loader.nil? || !loader.respond_to?(:synthesized_type_names)

          loader.synthesized_type_names.include?(class_name.to_s.sub(/\A::/, ""))
        end

        def definition_available?(receiver_type, class_name, scope)
          if receiver_type.is_a?(Type::Singleton)
            !Rigor::Reflection.singleton_definition(class_name, scope: scope).nil?
          else
            !Rigor::Reflection.instance_definition(class_name, scope: scope).nil?
          end
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

            build_self_undefined_method_diagnostic(path, miss)
          end
        end

        def confidently_closed_self_class?(class_name, scope)
          return false if unbounded_receiver_surface?(class_name, scope)
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

        def lookup_method(receiver_type, class_name, method_name, scope)
          if receiver_type.is_a?(Type::Singleton)
            Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: scope)
          else
            Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
          end
        rescue StandardError
          # The Reflection facade catches loader exceptions and
          # returns nil. The wrapper here treats failures as
          # "method exists" so we do NOT emit a false positive
          # when our knowledge of the receiver class is
          # structurally incomplete (Reflection's own rescue
          # already returns nil; this catch is a defensive
          # double-net for any future call shape that might
          # raise).
          true
        end

        # Slice 7 phase 11 — wrong-arity diagnostic. Fires when
        # an explicit-receiver `Prism::CallNode` resolves to a
        # method whose declared overloads do not admit the
        # supplied positional argument count. The rule applies
        # ONLY to the simplest overload shape (single overload,
        # no `rest_positionals`, no keyword parameters, no
        # block-required positionals); calls with `*splat`
        # arguments, keyword arguments, or block-pass arguments
        # are silently skipped to avoid false positives. The
        # check piggybacks on the same scope-index lookup used
        # by `undefined_method_diagnostic`; it returns nil
        # when the call's receiver / RBS coverage / call shape
        # disqualifies the rule.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
        def wrong_arity_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?
          return nil unless plain_positional_call?(call_node)

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

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
          return nil if scope.discovered_method?(class_name, call_node.name, kind)

          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def.nil? || method_def == true

          arity_envelope = compute_arity_envelope(method_def)
          return nil if arity_envelope.nil?

          actual = (call_node.arguments&.arguments || []).size
          min, max = arity_envelope
          return nil if actual.between?(min, max)

          build_arity_diagnostic(path, call_node, class_name, min, max, actual)
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize

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
        def nil_receiver_diagnostic(path, call_node, scope_index)
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

          scope = scope_index[call_node]
          return nil if scope.nil?

          # ADR-58 WD1 — a receiver whose `nil` constituent is purely
          # declaration-sourced (the class-ivar index seed of a ctor
          # `@x = nil` written in another method, possibly copied into a
          # local via `r = @right`) does not fire by default: the working
          # program's cross-method invariant is assumed per the robustness
          # principle. The nil stays in the displayed type; only its use as
          # diagnostic fuel is withheld. Any flow-live touch (method-local
          # nil write, failed-guard narrowing) drops the mark upstream, so
          # flow-observed nil keeps firing exactly as before.
          return nil if scope.declaration_sourced?(:local, call_node.receiver.name)

          receiver_type = scope.type_of(call_node.receiver)
          return nil unless receiver_type.is_a?(Type::Union)

          # The rule only fires when the analyzer has access to
          # an RBS loader; without it, the per-member method-
          # presence checks below cannot rule out a sound call.
          return nil unless Rigor::Reflection.rbs_class_known?("NilClass", scope: scope)

          return nil unless union_contains_nil?(receiver_type)
          return nil unless union_method_present_on_non_nil?(receiver_type, call_node.name, scope)
          return nil if nil_class_has_method?(call_node.name, scope)

          build_nil_receiver_diagnostic(path, call_node)
        end

        def union_contains_nil?(union)
          union.members.any? { |member| nil_member?(member) }
        end

        # The receiver type the `call.undefined-method` existence check
        # should reason about. For a safe-navigation call whose receiver
        # types as exactly `nil`, this is `Type::Bot` — the call is
        # statically skipped at runtime, and `concrete_class_name(Bot)` is
        # nil so the rule bails (silent). Every other receiver (including a
        # `T | nil` union, which already has no single concrete class) flows
        # through unchanged.
        def safe_navigation_receiver(call_node, scope)
          receiver_type = scope.type_of(call_node.receiver)
          return receiver_type unless call_node.safe_navigation?
          return receiver_type unless nil_member?(receiver_type)

          Type::Combinator.bot
        end

        def nil_member?(member)
          (member.is_a?(Type::Constant) && member.value.nil?) ||
            (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
        end

        # The non-nil members must collectively support the
        # method (i.e. for every non-nil member, the method
        # exists on its class via RBS or in-source discovery).
        # Without this guard, the rule would also fire on calls
        # that are unsound on the non-nil branch — that is the
        # `undefined_method_diagnostic` rule's job, and we want
        # exactly one diagnostic per offending call site.
        def union_method_present_on_non_nil?(union, method_name, scope)
          non_nil_members = union.members.reject { |m| nil_member?(m) }
          return false if non_nil_members.empty?

          non_nil_members.all? { |m| method_present_anywhere?(m, method_name, scope) }
        end

        def method_present_anywhere?(member, method_name, scope)
          class_name = concrete_class_name(member)
          return true if class_name.nil? # Dynamic / Top / Bot — be permissive.
          return true if scope.discovered_method?(class_name, method_name, :instance)
          return true unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return true unless definition_available?(member, class_name, scope)

          !lookup_method(member, class_name, method_name, scope).nil?
        end

        def nil_class_has_method?(method_name, scope)
          definition = Rigor::Reflection.instance_definition("NilClass", scope: scope)
          return false if definition.nil?

          !definition.methods[method_name.to_sym].nil?
        end

        # Slice 7 phase 19 — PHPStan-style `dump_type(value)`.
        # When the engine recognises a call to `dump_type` (with
        # any of the supported receiver shapes — implicit self
        # after `include Rigor::Testing`, `Rigor::Testing.dump_type`,
        # or `Rigor.dump_type`), it emits an `:info` diagnostic
        # showing the inferred type of the argument expression.
        # The diagnostic does NOT count toward `Result#error_count`
        # so a fixture peppered with `dump_type` calls still
        # passes `rigor check`.
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

        # Slice 7 phase 19 — PHPStan-style `assert_type("...", value)`.
        # The first argument MUST be a string literal containing
        # the expected `Type#describe(:short)` rendering. When
        # the inferred type's short description does not equal
        # the expected literal, an `:error`-severity diagnostic
        # is emitted; matching calls produce no output. This
        # lets a fixture document its expected types inline:
        # subsequent `rigor check` runs flag any drift.
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
        # The receiver check is purely structural — we do not
        # consult RBS — because the helpers are no-op stubs the
        # user MAY shadow with their own definition; a name
        # clash is the deliberate trade-off for ergonomic
        # invocation.
        RIGOR_TESTING_RECEIVERS = ["Rigor", "Rigor::Testing", "Testing"].freeze
        private_constant :RIGOR_TESTING_RECEIVERS

        # The dump/assert helpers' own implementation methods
        # call back into `Testing.dump_type` / `assert_type` to
        # share the no-op runtime stub. We do NOT want those
        # internal calls to surface diagnostics — they are
        # reflexive plumbing, not user assertions. This filter
        # skips diagnostics when the call site's `self_type` is
        # the `Rigor` or `Rigor::Testing` module itself.
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

          name = constant_name_of(receiver)
          return false if name.nil?

          RIGOR_TESTING_RECEIVERS.include?(name)
        end

        def constant_name_of(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then render_constant_path(node)
          end
        end

        def render_constant_path(node)
          parent = node.parent
          base = constant_name_of(parent)
          return nil if parent && base.nil?

          parent ? "#{base}::#{node.name}" : node.name.to_s
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
            severity: :error
          )
        end

        # Diagnoses calls that the analyzer can prove will always
        # raise. Today the only triggering shape is integer
        # division/modulo by a literal zero divisor:
        #
        #   5 / 0          # => ZeroDivisionError
        #   x.modulo(0)    # => ZeroDivisionError when x: Integer
        #   xs.size % 0    # same — non_negative_int / Constant[0]
        #
        # Float divmod by zero returns Infinity/NaN at runtime, so
        # the rule restricts to Integer-rooted receivers (`Constant`,
        # `IntegerRange`, `Nominal[Integer]`). The argument MUST be a
        # `Constant<Integer>` whose value is exactly zero — a
        # `Union[Constant[0], Constant[2]]` divisor "may" raise,
        # which we surface separately (future slice).
        INTEGER_RAISING_OPERATORS = %i[/ % div modulo divmod].freeze
        private_constant :INTEGER_RAISING_OPERATORS

        def always_raises_diagnostic(path, call_node, scope_index)
          return nil unless integer_zero_division?(call_node, scope_index)

          build_always_raises_diagnostic(path, call_node)
        end

        def integer_zero_division?(call_node, scope_index)
          return false unless raising_call_shape?(call_node)

          scope = scope_index[call_node]
          return false if scope.nil?
          return false unless integer_rooted_for_diagnostic?(scope.type_of(call_node.receiver))

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

        # v0.1.2 — `flow.unreachable-branch`. Fires when an
        # `IfNode` / `UnlessNode` whose predicate is a literal
        # `true` / `false` / `nil` (or a literal numeric /
        # string / symbol whose Ruby truthiness is known
        # at-a-glance) has an observable dead branch. The
        # diagnostic points at the dead branch (not the
        # predicate) so the squiggle lands on the code that
        # never runs.
        #
        # Conservative envelope — by deliberate v0.1.2 design:
        # - Only **literal-shaped** predicates fire. Inferred-
        #   constant predicates (`x.method?` that happens to
        #   fold to `Constant<bool>`) are intentionally
        #   skipped — Rigor's loop / mutation / RBS-strictness
        #   modelling is incomplete enough that an inferred
        #   constant can be a false positive (e.g. accumulator
        #   `arr << x` doesn't widen the carrier; defensive
        #   `module.name.nil?` checks against anonymous-class
        #   nil that the RBS `Module#name -> String` sig hides).
        #   The literal-only envelope captures the clear
        #   "user wrote `if false`" case without false alarms.
        # - Empty dead branches (e.g. `if false; end` with no
        #   body) are skipped — there is no useful location to
        #   point at.
        # - Postfix-`if` / `unless` modifiers with a literal
        #   predicate ARE flagged (`expr if false` body never
        #   runs, exactly like the block form).
        # - Elsif chains (`subsequent` is itself an `IfNode`)
        #   ARE flagged — the entire downstream chain is
        #   unreachable when the outer predicate is a constant
        #   literal.
        #
        # Broadening to inferred-constant predicates is queued
        # for a later v0.1.x release once the loop / mutation
        # gaps named above are closed.
        def unreachable_branch_diagnostic(path, node, scope_index)
          scope = scope_index[node]
          return nil if scope.nil?

          polarity = literal_predicate_polarity(node.predicate)
          return nil if polarity.nil?

          dead_branch = unreachable_branch_for(node, polarity == :truthy)
          return nil if dead_branch.nil?

          build_unreachable_branch_diagnostic(path, dead_branch, polarity)
        end

        # Returns `:truthy` / `:falsey` for a syntactically-
        # literal predicate, or nil for anything else.
        # `TrueNode`, `FalseNode`, `NilNode` are the
        # unambiguous cases. Numeric / string / symbol literals
        # are always truthy in Ruby (any non-`false` / non-`nil`
        # value is truthy, including `0` and `""`).
        TRUTHY_LITERAL_NODES = [
          Prism::TrueNode, Prism::IntegerNode, Prism::FloatNode,
          Prism::StringNode, Prism::SymbolNode, Prism::RegularExpressionNode
        ].freeze
        private_constant :TRUTHY_LITERAL_NODES

        FALSEY_LITERAL_NODES = [Prism::FalseNode, Prism::NilNode].freeze
        private_constant :FALSEY_LITERAL_NODES

        def literal_predicate_polarity(predicate)
          return :truthy if TRUTHY_LITERAL_NODES.any? { |klass| predicate.is_a?(klass) }
          return :falsey if FALSEY_LITERAL_NODES.any? { |klass| predicate.is_a?(klass) }

          nil
        end

        # v0.1.2 — `def.method-visibility-mismatch`. Fires when
        # an explicit-receiver `Prism::CallNode` targets a
        # user-class method whose `discovered_method_visibilities`
        # entry is `:private`. The rule is intentionally narrow:
        #
        # - Only `:private`. `:protected` access depends on
        #   subclass tracking the engine does not yet model;
        #   broadening waits for that surface.
        # - Only user classes whose visibility table the indexer
        #   built. RBS-known classes (stdlib, gems) are NOT
        #   consulted yet — RBS visibility is reliable but
        #   surfacing it would broaden the rule to a level the
        #   per-rule false-positive triage hasn't covered.
        # - Implicit-self calls are skipped (always allowed for
        #   private). Calls whose receiver is `Prism::SelfNode`
        #   are also skipped — Ruby 2.7+ permits `self.foo` for
        #   private methods.
        # - Receiver MUST resolve to a `Type::Nominal` so the
        #   rule has a single class identity to query. Unions /
        #   Dynamic / shape carriers are skipped.
        def visibility_mismatch_diagnostic(path, call_node, scope_index)
          return nil unless explicit_non_self_receiver?(call_node.receiver)

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          return nil unless receiver_type.is_a?(Type::Nominal)

          visibility = scope.discovered_method_visibility(receiver_type.class_name, call_node.name)
          return nil unless visibility == :private

          build_visibility_mismatch_diagnostic(path, call_node, receiver_type)
        end

        def explicit_non_self_receiver?(receiver)
          return false if receiver.nil?
          return false if receiver.is_a?(Prism::SelfNode)

          true
        end

        def build_visibility_mismatch_diagnostic(path, call_node, receiver_type)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_VISIBILITY_MISMATCH,
            path: path,
            message: "private method `#{call_node.name}' called on #{receiver_type.class_name} receiver",
            severity: :error
          )
        end

        # Pulls a single concrete class name from an ivar write's
        # rvalue type. Returns nil when the type is too unstable
        # to compare (Union / Dynamic / IntegerRange / etc.).
        # `concrete_class_name` already covers Nominal / Singleton
        # / Constant / Tuple / HashShape; the wrapper exists so
        # the ivar rule can extend the envelope (or apply
        # different filters) without disturbing the call rules.
        #
        # `TrueClass` / `FalseClass` are both normalised to
        # `"bool"` here so the common boolean-flag idiom
        # (`@loaded = false` in `initialize` then `@loaded = true`
        # on first work) doesn't fire the mismatch rule. A real
        # `bool → String` drift still trips because the second
        # write's `ivar_class_for` returns `"String"`.
        def ivar_class_for(type)
          name = concrete_class_name(type)
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

        def build_dead_assignment_diagnostic(path, write_node, def_node)
          Diagnostic.from_name_loc(
            write_node,
            rule: RULE_DEAD_ASSIGNMENT,
            path: path,
            message: "local `#{write_node.name}' assigned in `#{def_node.name}' but never read",
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

        # Returns the dead-branch node for a literal-predicate
        # if/unless, or nil when no observable branch is dead.
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
        # - Method must have exactly ONE method type
        #   (overload). Multi-overload checking is left for
        #   a follow-up because picking the "intended"
        #   overload requires the dispatcher's full
        #   acceptance plumbing.
        # - The selected overload must have NO
        #   rest_positionals, NO required keywords, NO
        #   trailing positionals.
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

        def argument_type_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?
          return nil if UNIVERSAL_EQUALITY_METHODS.include?(call_node.name)
          return nil unless plain_positional_call?(call_node)

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # NOTE: unlike the undefined-method / wrong-arity
          # rules, we deliberately do NOT skip when
          # `discovered_method?` matches. When the user
          # supplies BOTH a `def` and an RBS sig, the sig is
          # the authoritative parameter contract and we
          # should validate calls against it.
          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def.nil? || method_def == true
          return nil unless method_def.method_types.size == 1

          param_overrides = Rigor::RbsExtended.param_type_override_map(method_def, environment: scope.environment)
          mismatch = first_argument_mismatch(method_def.method_types.first, call_node, scope, param_overrides)
          return nil if mismatch.nil?

          build_argument_type_diagnostic(path, call_node, class_name, mismatch)
        end

        def first_argument_mismatch(method_type, call_node, scope, param_overrides)
          function = method_type.type
          return nil unless argument_check_eligible?(function)

          params = function.required_positionals + function.optional_positionals
          arguments = call_node.arguments&.arguments || []
          arguments.each_with_index do |arg, index|
            param = params[index]
            next if param.nil? # arity mismatch is the wrong-arity rule's concern.

            # `rigor:v1:param: <name> <refinement>` annotations
            # tighten the RBS-declared parameter type. The
            # override is the authoritative contract when
            # present; otherwise we translate the RBS type as
            # before.
            param_type = param_overrides[param.name] || translate_param_type(param.type, scope.environment)
            next if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)

            arg_type = scope.type_of(arg)
            next if arg_type.is_a?(Type::Dynamic) || arg_type.is_a?(Type::Top)

            result = Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual)
            return { node: arg, name: param.name, expected: param_type, actual: arg_type } if result.no?
          end
          nil
        end

        def argument_check_eligible?(function)
          # See `arity_eligible?`: `UntypedFunction` lacks
          # the per-arity accessors. Treat it as ineligible
          # for argument-type-mismatch diagnostics.
          return false unless function.respond_to?(:required_keywords)

          function.rest_positionals.nil? &&
            function.required_keywords.empty? &&
            function.optional_keywords.empty? &&
            function.rest_keywords.nil? &&
            function.trailing_positionals.empty?
        end

        def translate_param_type(rbs_type, _environment)
          Inference::RbsTypeTranslator.translate(rbs_type)
        rescue StandardError
          Type::Combinator.untyped
        end

        def build_argument_type_diagnostic(path, call_node, class_name, mismatch)
          method_label = "`#{call_node.name}' on #{class_name}"
          parameter_label = mismatch[:name] ? "parameter `#{mismatch[:name]}' of #{method_label}" : method_label
          message = "argument type mismatch at #{parameter_label}: " \
                    "expected #{mismatch[:expected].describe(:short)}, " \
                    "got #{mismatch[:actual].describe(:short)}"
          Diagnostic.from_node(
            mismatch[:node],
            rule: RULE_ARGUMENT_TYPE,
            path: path,
            message: message,
            severity: :error
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
            severity: :error
          )
        end

        def build_undefined_method_diagnostic(path, call_node, receiver_type, definition_site = nil, class_name = nil)
          rendered_receiver = receiver_type.describe
          message = "undefined method `#{call_node.name}' for #{rendered_receiver}"
          # ADR-17 — when the project itself defines this method on the
          # receiver class somewhere in the file set, name the site and
          # point at `pre_eval:`. Rigor does not apply project monkey-
          # patches cross-file automatically, so the diagnostic still
          # fires, but the enriched message makes it actionable (and
          # `rigor triage` keys on the structured `project_definition_site`
          # field to recommend `pre_eval:` with high confidence).
          if definition_site
            def_owner = class_name || rendered_receiver
            message += "; the project defines `#{def_owner}##{call_node.name}' at " \
                       "#{definition_site} — Rigor does not apply project monkey-patches " \
                       "cross-file; list that file in `.rigor.yml`'s `pre_eval:` (ADR-17)"
          end
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_UNDEFINED_METHOD,
            path: path,
            message: message,
            severity: :error,
            receiver_type: rendered_receiver,
            method_name: call_node.name.to_s,
            project_definition_site: definition_site
          )
        end

        # ADR-8 § "`def.return-type-mismatch` rule" — flags a
        # `def m(...) ... end` whose body's last expression's
        # type cannot satisfy the RBS-declared return type.
        # Conservative envelope (v0.1.x first cut):
        #
        # - Skips methods without an RBS declaration. The rule
        #   has no contract to compare against for source-only
        #   methods.
        # - Skips methods whose enclosing class isn't a
        #   `Type::Singleton` self_type that we can name (top-
        #   level / module-level methods land outside the rule).
        # - Skips methods whose body's last expression is
        #   absent or types as `Dynamic[top]` (the analyzer's
        #   fail-soft fallback) — emitting on `Dynamic[top]`
        #   would be noise.
        # - Compares the inferred body type against the
        #   declared return via `accepts?`:
        #     :yes   → silent
        #     :no    → emit at :error (severity_profile may
        #              re-stamp; default `balanced` keeps the
        #              authored severity).
        #     :maybe → emit at :warning. Promoted to :error
        #              under `severity_profile: strict` per
        #              ADR-8 § "Severity profile".
        def return_type_mismatch_diagnostic(path, def_node, scope_index)
          return nil if def_node.body.nil?

          last_expr = body_last_expression(def_node.body)
          return nil if last_expr.nil?

          inner_scope = scope_index[last_expr] || scope_index[def_node.body] || scope_index[def_node]
          return nil if inner_scope.nil?

          declared = declared_return_type(def_node, scope_index)
          return nil if declared.nil?

          inferred = inner_scope.type_of(last_expr)
          return nil if dynamic_top?(inferred)

          severity = compare_return(declared, inferred)
          return nil if severity.nil?

          build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
        end

        # The body of a `def` is the last `Prism::StatementsNode`
        # child (or a single expression for one-liner defs).
        # Take the last statement; that's the implicit return.
        def body_last_expression(body)
          case body
          when Prism::StatementsNode then body.body.last
          when Prism::BeginNode then body_last_expression(body.statements)
          else body
          end
        end

        # Pulls the declared RBS return type for the def. The
        # enclosing class name comes from the def's scope's
        # `self_type`; the method name is on the def itself.
        # `def self.foo` is a singleton method — dispatched
        # through `Reflection.singleton_method_definition`;
        # plain `def foo` uses `instance_method_definition`.
        # Method overloads contribute their union of declared
        # return types (any one of them satisfying the body
        # silences the rule).
        #
        # v0.1.2 — when the RBS sig carries a
        # `%a{rigor:v1:return: <refinement>}` annotation
        # (recognised by `RbsExtended.read_return_type_override`),
        # the refinement carrier replaces the RBS-declared
        # return for this rule. Annotation-driven refinements
        # — `non-empty-string`, `positive-int`, `non-empty-
        # array[Integer]`, etc. — are stricter than the
        # underlying RBS class, so a body whose inferred type
        # the bare RBS sig would accept may still fail the
        # refinement (e.g. `def name; ""; end` returns
        # `Constant[""]`, accepted by `String` but rejected by
        # `non-empty-string`).
        def declared_return_type(def_node, scope_index)
          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          method_def =
            if def_node.receiver.nil?
              Reflection.instance_method_definition(self_type.class_name, def_node.name, scope: scope)
            else
              Reflection.singleton_method_definition(self_type.class_name, def_node.name, scope: scope)
            end
          return nil if method_def.nil?

          override = Rigor::RbsExtended.read_return_type_override(method_def, environment: scope.environment)
          return override if override

          declared_return_union(method_def, scope.environment)
        end

        def declared_return_union(method_def, _environment)
          translated = method_def.method_types.filter_map do |mt|
            Inference::RbsTypeTranslator.translate(
              mt.type.return_type,
              self_type: nil, instance_type: nil, type_vars: {}
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

        # Returns the severity to emit at, or nil to stay
        # silent. The first-cut implementation only fires on
        # proven (`:no`) mismatches; `:maybe` is treated as
        # silent until the analyzer's narrowing becomes precise
        # enough to avoid noise on common patterns (`{}` →
        # declared `Hash[K, V]`, `Set.new` → declared
        # `Set[Symbol]`, …). ADR-8's promise to emit on
        # `:maybe` under `severity_profile: strict` is
        # deferred to a follow-up that lands together with the
        # narrowing precision improvements.
        def compare_return(declared, inferred)
          result = declared.accepts(inferred)
          return :error if result.no?

          nil
        end

        def build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_RETURN_TYPE,
            path: path,
            message: "return-type mismatch on `#{def_node.name}': " \
                     "declared #{declared.describe(:short)}, inferred #{inferred.describe(:short)}",
            severity: severity
          )
        end

        # ADR-35 slice 1 — `def.override-visibility-reduced`. The
        # Liskov signature rule for visibility: an instance-method
        # override MUST NOT reduce the visibility it inherits
        # (public → protected/private, or protected → private),
        # because a caller holding the supertype that invokes the
        # method breaks when handed the subtype.
        #
        # Slice-1 scope (ADR-35 WD1, visibility carve-out): both the
        # override and the shadowed method must have a STATICALLY
        # OBSERVABLE visibility. The override's visibility is read
        # from the source-discovered table; the parent is resolved
        # against the project-discovered ancestor chain (user-source
        # classes / modules only — RBS-known ancestors, whose
        # accessibility RBS models as public/private only, are a
        # deferred follow-on). When either side is not observable
        # the rule stays silent.
        def override_visibility_diagnostic(path, def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only

          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name.to_s
          method_name = def_node.name

          override_visibility = scope.discovered_method_visibility(class_name, method_name)
          return nil if override_visibility.nil?

          parent = nearest_ancestor_visibility(scope, class_name, method_name)
          return nil if parent.nil?

          parent_class, parent_visibility = parent
          # Unknown ancestor visibility (e.g. the defining file was not
          # in the analyzed set) → cannot prove a reduction, stay silent.
          return nil if parent_visibility.nil?
          return nil unless visibility_reduced?(parent_visibility, override_visibility)

          build_override_visibility_diagnostic(
            path, def_node, parent_class, parent_visibility, override_visibility
          )
        end

        # Returns true when `override_visibility` is strictly more
        # restrictive than `parent_visibility` under the
        # public > protected > private ordering.
        def visibility_reduced?(parent_visibility, override_visibility)
          parent_rank = VISIBILITY_RANK[parent_visibility]
          override_rank = VISIBILITY_RANK[override_visibility]
          return false if parent_rank.nil? || override_rank.nil?

          override_rank < parent_rank
        end

        # Breadth-first walk of the project-discovered ancestor chain
        # (included / prepended modules first, then the superclass —
        # Ruby's MRO ordering), yielding each resolved ancestor class
        # name nearest-first. Returns the first truthy value the block
        # produces, or nil. Cross-file: the chain is followed through
        # the scope tables the runner seeds from the project pre-pass
        # (ADR-24 WD1). Cycle-guarded and node-count-capped. Mirrors
        # `ExpressionTyper#resolve_user_def_through_ancestors`.
        def each_project_ancestor(scope, class_name)
          queue = ancestor_class_names(scope, class_name)
          seen = { class_name.to_s => true }
          visited = 0
          until queue.empty?
            current = queue.shift
            next if current.nil? || seen[current]

            seen[current] = true
            visited += 1
            return nil if visited > OVERRIDE_ANCESTOR_WALK_LIMIT

            result = yield current
            return result if result

            ancestor_class_names(scope, current).each { |name| queue.push(name) }
          end
          nil
        end

        # `[defining_class, visibility]` for the nearest user-source
        # ancestor that defines an instance method `method_name`, or nil.
        def nearest_ancestor_visibility(scope, class_name, method_name)
          each_project_ancestor(scope, class_name) do |ancestor|
            # Stop at the nearest ancestor that DEFINES the method; its
            # visibility may be nil (unknown) — the caller treats unknown
            # as "cannot prove a reduction" and stays silent. Never
            # fabricate `:public` from a missing entry (that produced a
            # large false-positive cluster on cross-file Rails concerns).
            [ancestor, scope.discovered_method_visibility(ancestor, method_name)] if scope.user_def_for(ancestor,
                                                                                                        method_name)
          end
        end

        # Direct ancestors of `class_name` as project-discovered,
        # qualified names: included / prepended modules first, then
        # the superclass. As-written names are resolved against the
        # subclass's lexical nesting; names that resolve to no
        # project class/module (RBS-known / third-party) are dropped.
        def ancestor_class_names(scope, class_name)
          names = []
          scope.includes_of(class_name).each do |raw|
            resolved = resolve_override_ancestor_name(scope, class_name, raw)
            names << resolved if resolved
          end
          raw_super = scope.superclass_of(class_name)
          if raw_super
            resolved_super = resolve_override_ancestor_name(scope, class_name, raw_super)
            names << resolved_super if resolved_super
          end
          names
        end

        def resolve_override_ancestor_name(scope, subclass_qualified, raw_ancestor)
          segments = subclass_qualified.to_s.split("::")
          (segments.length - 1).downto(0) do |i|
            candidate = (segments[0, i] + [raw_ancestor]).join("::")
            return candidate if known_user_class?(scope, candidate)
          end
          # ADR-46 slice 3 — the override checker reads the class graph
          # directly (not through the recorder's `Scope` choke points), and
          # short-circuits when the ancestor resolves to no project class, so
          # an incremental re-check has no edge telling it to re-check this
          # subclass when that ancestor is later defined. Record a negative
          # class edge (keyed on the unqualified name) so the appeared-class
          # widening picks it up.
          DependencyRecorder.read_missing(:class, raw_ancestor.to_s.split("::").last) if DependencyRecorder.active?
          nil
        end

        def known_user_class?(scope, name)
          scope.discovered_superclasses.key?(name) ||
            scope.discovered_def_nodes.key?(name) ||
            scope.discovered_includes.key?(name)
        end

        def build_override_visibility_diagnostic(path, def_node, parent_class, parent_visibility, override_visibility)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_VISIBILITY_REDUCED,
            path: path,
            message: "visibility of `#{def_node.name}' reduced from #{parent_visibility} to " \
                     "#{override_visibility} (overrides #{parent_class}##{def_node.name}); " \
                     "breaks substitutability",
            severity: :warning
          )
        end

        # ADR-35 slice 2 — `def.override-return-widened`. The Liskov
        # signature rule for returns (covariance): an override may
        # *narrow* the return it inherits (return a more specific type)
        # but MUST NOT *widen* it. A caller holding the supertype uses
        # the result as the parent's return type; a wider override
        # return breaks that use.
        #
        # WD1 gate (proper, type-direction): both the override and the
        # shadowed ancestor method must carry an explicitly-authored
        # RBS signature. The override side is gated by
        # `defined_on?` (the RBS method is declared on the overriding
        # class itself, not merely inherited); the parent side is the
        # nearest project-discovered ancestor whose RBS declares the
        # method. Inference-only either side → silent.
        #
        # Fires only on a proven (`:no`) widening; generic / `untyped`
        # / `self` parent returns degrade to `Dynamic[Top]` and accept
        # everything, so they stay silent (FP-safe). `self`/`instance`
        # are translated with `self_type: nil` on both sides, so a
        # parent `-> self` and an override `-> self` never fire.
        def override_return_widened_diagnostic(path, def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only (singleton: follow-on)

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
          override_return = declared_return_union(override_method, scope.environment)
          parent_return = declared_return_union(parent_method, scope.environment)
          return nil if override_return.nil? || parent_return.nil?
          return nil if dynamic_top?(parent_return) # untyped / unbound-generic parent contract

          return nil unless parent_return.accepts(override_return).no?

          build_override_return_widened_diagnostic(
            path, def_node, parent_class, parent_return, override_return
          )
        end

        # `[defining_class, RBS::Definition::Method]` for the nearest
        # project-discovered ancestor whose RBS declares `method_name`
        # (not the starting class's own declaration), or nil.
        def nearest_ancestor_method_def(scope, class_name, method_name)
          each_project_ancestor(scope, class_name) do |ancestor|
            method_def = safe_instance_method_definition(ancestor, method_name, scope)
            [ancestor, method_def] if method_def && !defined_on?(method_def, class_name)
          end
        end

        def safe_instance_method_definition(class_name, method_name, scope)
          Reflection.instance_method_definition(class_name, method_name, scope: scope)
        rescue StandardError
          nil
        end

        # True when `method_def`'s RBS declaration lives on `class_name`
        # itself (rather than being inherited from an ancestor).
        def defined_on?(method_def, class_name)
          defined_in = method_def.defined_in
          return false if defined_in.nil?

          normalize_class_name(defined_in.to_s) == normalize_class_name(class_name)
        end

        def normalize_class_name(name)
          name.to_s.delete_prefix("::")
        end

        def build_override_return_widened_diagnostic(path, def_node, parent_class, parent_return, override_return)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_RETURN_WIDENED,
            path: path,
            message: "return type of `#{def_node.name}' widened from #{parent_return.describe(:short)} " \
                     "to #{override_return.describe(:short)} (overrides #{parent_class}##{def_node.name}); " \
                     "breaks substitutability",
            severity: :warning
          )
        end

        # ADR-35 slice 3 — `def.override-param-narrowed`. The Liskov
        # signature rule for parameters (contravariance): an override
        # may *widen* a parameter (accept a supertype — accepting more
        # is safe) but MUST NOT *narrow* it. A caller holding the
        # supertype passes a parent-typed argument; a narrowed override
        # parameter cannot accept it.
        #
        # Direction (ADR-35 WD3, corrected): fire on
        # `override_param.accepts(parent_param) == :no` — the override's
        # (narrowed) slot cannot accept the wider parent argument type.
        # WD4: type comparison at matching POSITIONAL parameter indices
        # only; arity / keyword-requiredness divergence is out of scope
        # for v1. Same WD1 both-sides-authored gate as slice 2;
        # `untyped` / unbound-generic / interface parent params degrade
        # to `Dynamic[Top]` and are skipped (FP-safe). To avoid
        # overload-arm ambiguity, both sides must have exactly one
        # method type.
        def override_param_narrowed_diagnostic(path, def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only

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
          override_params = positional_param_types(override_method)
          parent_params = positional_param_types(parent_method)
          return nil if override_params.nil? || parent_params.nil?

          index = first_narrowed_param_index(override_params, parent_params)
          return nil if index.nil?

          build_override_param_narrowed_diagnostic(
            path, def_node, parent_class, index, parent_params[index], override_params[index]
          )
        end

        # Translated positional (required + optional) parameter types of
        # a method's single method type, or nil when the method is
        # overloaded (multiple method types — arm mapping is ambiguous)
        # or the parameter list is not introspectable. Per-position
        # translation failures yield `nil` at that slot (skipped by the
        # comparison). `self`/`instance` translate with `self_type: nil`
        # (→ `Dynamic[Top]`), matching the return-side handling.
        def positional_param_types(method_def)
          method_types = method_def.method_types
          return nil unless method_types.size == 1

          func = method_types.first.type
          return nil unless func.respond_to?(:required_positionals)

          (func.required_positionals + func.optional_positionals).map do |param|
            Inference::RbsTypeTranslator.translate(
              param.type, self_type: nil, instance_type: nil, type_vars: {}
            )
          rescue StandardError
            nil
          end
        end

        # Index of the first positional parameter the override narrows
        # relative to the parent, or nil. A position is a violation when
        # the override's slot cannot accept the parent's argument type
        # (`override_param.accepts(parent_param) == :no`). Positions
        # where either side is missing/untranslatable, or the parent
        # type degraded to `Dynamic[Top]` (untyped / unbound generic /
        # interface), are skipped.
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
            severity: :warning
          )
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
