# frozen_string_literal: true

require "prism"

require_relative "rule_walk"
require_relative "override_visibility"
require_relative "../../scope/resolution_chain"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../inference/census_foreign_block"
require_relative "../../inference/acceptance"
require_relative "../diagnostic"
require_relative "receiver_predicates"
require_relative "rule_ids"

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
      # - Issue #2943: a write directly in a block or `class << obj` body whose `self` is provably not an instance
      #   of the class (`Other.new.instance_eval { @r = 1 }`), by the class-ivar census's rule
      #   ({Inference::CensusForeignBlock}).
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

        # Groups the writes by class qualified name, then by ivar name. Each write carries `node`, `type`,
        # `declared`, `method_name`, `visibility`, `per_invocation` and `action`. Empty when the tree has no
        # qualifying writes.
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

        # ADR-116 WD1 — the message builder for this collector's results, moved here from `CheckRules`.
        # {.diagnostics} is called by `CheckRules.diagnose` through its collector table; the rest is private to it.

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
        def self.diagnostics(path, ivar_writes)
          ivar_writes.flat_map do |class_name, writes_by_ivar|
            writes_by_ivar.flat_map do |ivar_name, writes|
              ivar_mismatch_diagnostics_for(path, class_name, ivar_name, writes)
            end
          end
        end

        def self.ivar_mismatch_diagnostics_for(path, class_name, ivar_name, writes)
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
        def self.separate_invocations?(write, write_class, writes)
          return false unless write[:action]

          writes.all? do |other|
            other_class = ivar_class_for(other[:type])
            next true if other_class.nil? || other_class == "NilClass" || other_class == write_class

            other[:action] && other[:method_name] != write[:method_name]
          end
        end

        def self.declaration_admits?(declared, *write_types)
          return false if declared.nil?

          write_types.none? { |type| Inference::Acceptance.accepts(declared, type, mode: :gradual).no? }
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
        def self.ivar_class_for(type)
          name = ReceiverPredicates.concrete_class_name(type)
          return "bool" if %w[TrueClass FalseClass].include?(name)

          name
        end

        def self.build_ivar_write_mismatch_diagnostic(path, node, class_name, ivar_name, first_class, other_class)
          Diagnostic.from_name_loc(
            node,
            rule: RULE_IVAR_WRITE_MISMATCH,
            path: path,
            message: "instance variable `#{ivar_name}' on #{class_name} was previously assigned " \
                     "#{first_class}; this write assigns #{other_class}",
            severity: :error
          )
        end

        private_class_method :ivar_mismatch_diagnostics_for, :separate_invocations?, :declaration_admits?,
                             :ivar_class_for, :build_ivar_write_mismatch_diagnostic

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

          names = (call_node.arguments&.arguments || []).filter_map { |argument| literal_method_name(argument) }
          return if names.empty?

          ((@macro_arguments[qualified_prefix.join("::")] ||= {})[call_node.name] ||= []).concat(names)
        end

        # A Symbol / String literal's name, or the name of a `def` passed inline (`helper_method def
        # current_user … end`). A literal with bytes no Symbol can hold (`before_action "\xff"`, #1821) names no
        # method, so it answers nil.
        def literal_method_name(argument)
          return argument.name if argument.is_a?(Prism::DefNode) && argument.receiver.nil?
          return nil unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

          text = argument.unescaped
          text.valid_encoding? ? text.to_sym : nil
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
          # A def with a receiver writes the ivars of another object than an instance (#3155).
          return if def_node.receiver

          class_name = qualified_prefix.join("::")
          gather_writes(def_node.body, class_name, def_node.name)
        end

        def gather_writes(node, class_name, method_name)
          return unless node.is_a?(Prism::Node)

          record_write(node, class_name, method_name) if node.is_a?(Prism::InstanceVariableWriteNode)
          return if BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          # #2943 — a block or `class <<` body whose `self` is provably another object writes that object's ivars, as
          # the class-ivar census reads it ({Inference::CensusForeignBlock}); a `define_method` block nested in it that
          # runs on an instance again still counts. A `def` it reenters stays a barrier here.
          children = Inference::CensusForeignBlock.census_children(node, class_name)
          return node.rigor_each_child { |child| gather_writes(child, class_name, method_name) } unless children

          children.each { |child| gather_writes(child, class_name, method_name) }
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
          return :private if OverrideVisibility::IMPLICITLY_PRIVATE_METHODS.include?(method_name)
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
