# frozen_string_literal: true

require "prism"

require_relative "rule_walk"
require_relative "../../scope/resolution_chain"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # Walks a parse tree and collects every `Prism::InstanceVariableWriteNode` inside an instance method
      # body of a `Prism::ClassNode` / `Prism::ModuleNode`, grouped by (class qualified name, ivar name).
      #
      # The collector is the read-side companion to `Inference::ScopeIndexer#build_class_ivar_index`. The
      # indexer unions the rvalue types into a single per-ivar carrier; this collector preserves the per-write
      # list so the `def.ivar-write-mismatch` rule can compare each write's concrete class against the first.
      #
      # Skipped on purpose:
      #
      # - Singleton-method bodies, in either spelling: `def self.foo`, and (issue #909) any `def` lexically
      #   inside a `class << self` body. Their ivars live on the class object, not on instances.
      # - Bodies of an anonymous-class factory block (`Class.new do … end`, `Module.new`, `Struct.new`,
      #   `Data.define`). The class they define is not the enclosing one, so its ivars are a third store
      #   again (issue #909).
      # - Class-body ivar writes outside any def — the `Module#@var` surface is a separate slice the engine
      #   doesn't yet model.
      # - Nested classes / modules / defs inside a method body are barriers, mirroring the indexer's
      #   `IVAR_BARRIER_NODES` policy.
      class IvarWriteCollector
        BARRIER_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].freeze
        private_constant :BARRIER_NODES

        # ADR-53 Track B — the node classes the shared {RuleWalk} dispatches to this collector, and the
        # context gate under which the walk suppresses it. The legacy walk descends only through class /
        # module bodies and `return`s at the first `def` it meets, so it collects ivar writes only from a
        # `def` that sits directly in a class / module body, never one nested in another `def`. On the
        # shared full DFS that prune becomes the `:inside_def` gate; the enclosing class / module name stack
        # the legacy walk threaded as `qualified_prefix` is now `context.qualified_prefix`.
        #
        # ADR-125 — the walk also visits class-body `CallNode`s (a `def` body is gated off), to record the
        # macro calls whose literal arguments name a method (`before_action :load_roles`).
        NODE_CLASSES = [Prism::DefNode, Prism::CallNode].freeze
        RULE_WALK_GATES = %i[inside_def detached_ivar_facet].freeze

        # Returns `Hash[class_name (String) => Hash[ivar_name (Symbol) => Array<{node:, type:, declared:,
        # method_name:, visibility:, per_invocation:, action:}>]]`. Empty when the tree has no qualifying writes.
        # `declared` is the translated type of the class's RBS declaration of the ivar — an `@x: T` member or
        # the slot an `attr_*` member implies, own or inherited — and nil when the RBS declares none.
        #
        # ADR-125 — `method_name` is the enclosing `def`'s name and `visibility` its instance visibility
        # (`:public` / `:protected` / `:private`, or nil when the discovery table has no settled answer).
        # `per_invocation` is whether the class is, or descends from, a class a loaded plugin declares in
        # `per_invocation_classes:`. `action` is whether the enclosing method is one of that class's entry
        # points: public, and named by none of the declaring plugin's `per_invocation_non_action_macros:` in a
        # class body of this file (`before_action :load_roles`, `helper_method :current_roles`).
        def initialize(scope_index)
          @scope_index = scope_index
          @accumulator = {}
          @per_invocation = {}
          @macro_arguments = {}
        end

        # Legacy single-collector walk — kept as the oracle the ADR-53 Track B equivalence harness compares
        # {RuleWalk} against; deleted when Track B completes.
        def collect(root)
          walk(root, [])
          results
        end

        # {RuleWalk} entry point: the legacy walk's per-`def` logic, invoked at each class-/module-body `def`
        # under the shared traversal contract. `collect_def_writes`' verbatim body reads the enclosing class
        # prefix from `context.qualified_prefix`.
        def visit(node, context)
          if node.is_a?(Prism::CallNode)
            record_macro_call(node, context.qualified_prefix)
          else
            collect_def_writes(node, context.qualified_prefix)
          end
        end

        # The accumulated result, frozen the same way `#collect` returns it — used by {RuleWalk}-driven
        # callers after the walk completes.
        def results
          @accumulator.to_h do |class_name, writes_by_ivar|
            [class_name, writes_by_ivar.transform_values { |writes| with_actions(class_name, writes) }.freeze]
          end.freeze
        end

        private

        def walk(node, qualified_prefix)
          return unless node.is_a?(Prism::Node)
          # The legacy walk's mirror of {RuleWalk}'s `detached_ivar_facet` context (issue #909); the two
          # walks share the predicate so the permanent equivalence spec keeps holding.
          return if RuleWalk.detached_ivar_facet?(node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            child_prefix = Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
            if child_prefix
              walk(node.body, child_prefix) if node.body
              return
            end
          when Prism::DefNode
            collect_def_writes(node, qualified_prefix)
            return
          when Prism::CallNode
            record_macro_call(node, qualified_prefix)
          end

          node.rigor_each_child { |child| walk(child, qualified_prefix) }
        end

        # A receiverless (or `self.`) call in a class body, with the method names its literal Symbol / String
        # arguments spell. Kept for every such call: which macro names count is the registry's answer, read
        # once per class when the writes are finalised.
        def record_macro_call(call_node, qualified_prefix)
          return if qualified_prefix.empty?
          return unless call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode)

          # A literal with bytes no Symbol can hold (`before_action "\xff"`, #1821) names no method; skip it.
          names = (call_node.arguments&.arguments || []).filter_map do |argument|
            next unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

            text = argument.unescaped
            text.to_sym if text.valid_encoding?
          end
          return if names.empty?

          ((@macro_arguments[qualified_prefix.join("::")] ||= {})[call_node.name] ||= []).concat(names)
        end

        # Each write with `action` set (see {#initialize}). A frozen copy, so `#results` stays repeatable.
        def with_actions(class_name, writes)
          macros = @per_invocation[class_name]
          excluded = macros ? non_action_names(class_name, macros) : nil
          writes.map do |write|
            action = !excluded.nil? && write[:visibility] == :public && !excluded.include?(write[:method_name])
            write.merge(action: action).freeze
          end.freeze
        end

        def non_action_names(class_name, macros)
          (@macro_arguments[class_name] || {}).each_with_object(Set.new) do |(macro, names), set|
            set.merge(names) if macros.include?(macro)
          end
        end

        def collect_def_writes(def_node, qualified_prefix)
          return if def_node.body.nil? || qualified_prefix.empty?
          return if def_node.receiver.is_a?(Prism::SelfNode)

          class_name = qualified_prefix.join("::")
          gather_writes(def_node.body, class_name, def_node.name)
        end

        def gather_writes(node, class_name, method_name)
          return unless node.is_a?(Prism::Node)

          record_write(node, class_name, method_name) if node.is_a?(Prism::InstanceVariableWriteNode)
          return if BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          node.rigor_each_child { |child| gather_writes(child, class_name, method_name) }
        end

        def record_write(node, class_name, method_name)
          scope = @scope_index[node]
          return if scope.nil?

          rvalue_type = scope.type_of(node.value)
          declared = declared_ivar(scope, class_name, node.name)
          @accumulator[class_name] ||= {}
          @accumulator[class_name][node.name] ||= []
          @accumulator[class_name][node.name] << {
            node: node, type: rvalue_type, declared: declared, method_name: method_name,
            visibility: method_visibility(scope, class_name, method_name),
            per_invocation: !per_invocation_macros(scope, class_name).nil?
          }
        end

        # The enclosing `def`'s instance visibility, or nil when it is not a settled fact: a slot the
        # discovery table does not hold, or one a later `define_method` / alias / unplaceable write contests
        # (#2013). `initialize` and the other lifecycle hooks are private whatever the table says.
        def method_visibility(scope, class_name, method_name)
          return :private if CheckRules::IMPLICITLY_PRIVATE_METHODS.include?(method_name)
          return nil if scope.discovery.contested?(:discovered_method_visibilities, [class_name, method_name])

          scope.discovered_method_visibility(class_name, method_name)
        end

        # ADR-125 — when `class_name` is, or descends from, a class a loaded plugin declares per-invocation, the
        # non-action macros its declaring manifests list (a Set, possibly empty); nil otherwise. Read off the
        # class's instance {Scope::ResolutionChain}, so a project superclass chain
        # (`UsersController < ApplicationController < ActionController::Base`) is followed as Ruby resolves it.
        # A project entry matches by name. An external superclass matches through the first of its candidate
        # spellings the environment knows, by name or by an RBS-known `:equal` / `:subclass` ordering. When the
        # environment knows none of them (rigor-actionpack leaves `ActionController::Base` undeclared on
        # purpose), a candidate that is literally a declared name matches, unless some candidate names a class
        # the project itself declares: then the spelling may resolve there instead. An ambiguous spelling (no
        # candidates) and a truncated chain answer nil: the carve-out only ever withholds a finding, so an
        # unproved descent keeps the rule firing. Memoised per class.
        def per_invocation_macros(scope, class_name)
          return @per_invocation[class_name] if @per_invocation.key?(class_name)

          @per_invocation[class_name] = matched_per_invocation_macros(scope, class_name)
        end

        def matched_per_invocation_macros(scope, class_name)
          environment = scope.environment
          registry = environment&.plugin_registry
          return nil if registry.nil? || registry.per_invocation_classes.empty?

          chain = Scope::ResolutionChain.for(scope, class_name, :instance, :methods)
          return nil if chain.truncated?

          declared = chain.search(scope) { |entry| matched_declarations(entry, registry, scope) }
          declared&.each_with_object(Set.new) { |name, set| set.merge(registry.per_invocation_non_action_macros(name)) }
        end

        # The declared per-invocation names `entry` matches, or nil (so {ResolutionChain#search} moves on).
        def matched_declarations(entry, registry, scope)
          return (registry.per_invocation_class?(entry.name.to_s) ? [entry.name.to_s] : nil) unless entry.external?
          return nil unless entry.superclass_edge

          environment = scope.environment
          names = entry.candidates.map { |name| name.to_s.delete_prefix("::") }
          known = names.find { |name| environment.class_known?(name) }
          return literal_declarations(names, registry, scope) if known.nil?

          matched = registry.per_invocation_classes.select do |declared|
            %i[equal subclass].include?(environment.class_ordering(known, declared))
          end
          matched.empty? ? nil : matched
        end

        def literal_declarations(names, registry, scope)
          return nil if names.any? { |name| scope.discovered_classes.key?(name) }

          matched = names.select { |name| registry.per_invocation_class?(name) }
          matched.empty? ? nil : matched
        end

        def declared_ivar(scope, class_name, ivar_name)
          loader = scope.environment&.rbs_loader
          return nil if loader.nil?

          variable = loader.instance_definition(class_name)&.instance_variables&.[](ivar_name)
          return nil if variable.nil?

          translate_declared(variable.type, loader, class_name)
        end

        # `self` / `instance` in a class's declaration is that class; a module's stays untyped, since its
        # instances belong to includers no RBS type names. A translation failure reads as untyped, which only
        # ever withholds a finding.
        def translate_declared(rbs_type, loader, class_name)
          owner = Type::Combinator.nominal_of(class_name) unless loader.rbs_module?(class_name)
          Inference::RbsTypeTranslator.translate(rbs_type, self_type: owner, instance_type: owner,
                                                           alias_expander: loader)
        rescue StandardError
          Type::Combinator.untyped
        end
      end
    end
  end
end
