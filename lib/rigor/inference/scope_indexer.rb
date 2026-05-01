# frozen_string_literal: true

require "prism"

require_relative "../scope"
require_relative "../type"
require_relative "statement_evaluator"

module Rigor
  module Inference
    # Builds a per-node scope index for a Prism program by running
    # `Rigor::Inference::StatementEvaluator` over the root and recording
    # the entry scope visible at every node. Expression-interior nodes
    # the evaluator does not specialise (call receivers, arguments,
    # array/hash elements, ...) inherit their nearest statement-y
    # ancestor's recorded scope, so a downstream caller that looks up
    # the scope for any Prism node in the tree always gets the scope
    # that was effectively visible at that point.
    #
    # The CLI commands `rigor type-of` and `rigor type-scan` consume
    # the index so that local-variable bindings established earlier in
    # the program are visible to the typer when probing later nodes.
    # Without the index, both commands would type every node under an
    # empty scope and miss the constant-folding / dispatch precision
    # that Slice 3 phase 2's StatementEvaluator unlocks.
    #
    # The returned object is an identity-comparing Hash:
    #
    # ```ruby
    # index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Scope.empty)
    # index[some_prism_node] #=> the Rigor::Scope visible at that node
    # ```
    #
    # Nodes that are not part of the program subtree (e.g. synthesised
    # virtual nodes that the caller looks up after the fact) yield the
    # `default_scope`. The returned Hash is mutable in principle but
    # callers MUST treat it as read-only; the indexer itself never
    # exposes a way to update it past construction.
    # rubocop:disable Metrics/ModuleLength
    module ScopeIndexer
      module_function

      # Build the scope index for a Prism program subtree.
      #
      # @param root [Prism::Node] usually a `Prism::ProgramNode`, but any
      #   subtree the caller wants the indexer to walk works.
      # @param default_scope [Rigor::Scope] the scope used for the root,
      #   and the fallback returned for any Prism node not contained in
      #   `root`'s subtree.
      # @return [Hash{Prism::Node => Rigor::Scope}] identity-comparing
      #   table whose default value is `default_scope`.
      def index(root, default_scope:) # rubocop:disable Metrics/AbcSize
        # Slice A-declarations. Build the declaration overrides
        # first so every scope handed to the StatementEvaluator
        # already carries the table; structural sharing through
        # `Scope#with_local` / `#with_fact` / `#with_self_type`
        # propagates it across every derived scope.
        declared_types, discovered_classes = build_declaration_artifacts(root)
        seeded_scope = default_scope
                       .with_declared_types(declared_types)
                       .with_discovered_classes(discovered_classes)

        # Slice 7 phase 2. Pre-pass over every class/module body
        # to collect the per-class ivar accumulator. Seeded after
        # declared_types so the rvalue typer in the pre-pass can
        # see declaration overrides.
        class_ivars = build_class_ivar_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_class_ivars(class_ivars)

        # Slice 7 phase 6. Same pre-pass shape for cvars (per
        # class) and globals (program-wide). Globals are also
        # materialised into the top-level scope's `globals` map
        # so reads at the top level (and in CLI probes that do
        # not enter a method body) observe the precise type
        # without consulting the accumulator on every lookup.
        class_cvars = build_class_cvar_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_class_cvars(class_cvars)
        program_globals = build_program_global_index(root, seeded_scope)
        seeded_scope = seeded_scope.with_program_globals(program_globals)
        program_globals.each { |name, type| seeded_scope = seeded_scope.with_global(name, type) }

        # Slice 7 phase 9. In-source constant value tracking.
        # Walks every ConstantWriteNode/ConstantPathWriteNode in
        # the program and types its rvalue under a scope that
        # carries the surrounding qualified prefix as
        # `self_type`, so the rvalue typer sees in-class
        # references resolve correctly. Multiple writes to the
        # same qualified name union via `Type::Combinator.union`.
        in_source_constants = build_in_source_constants(root, seeded_scope)
        seeded_scope = seeded_scope.with_in_source_constants(in_source_constants)

        # Slice 7 phase 12. In-source method discovery. Walks
        # every class/module body for `Prism::DefNode` and
        # recognised `define_method` calls and records the
        # introduced method names. `rigor check` consults the
        # table to suppress false positives for methods the
        # user has defined but no RBS sig describes.
        discovered_methods = build_discovered_methods(root)
        seeded_scope = seeded_scope.with_discovered_methods(discovered_methods)

        # v0.0.2 #5 — also record the def node itself for
        # instance methods so the engine can re-type the body
        # when a call site dispatches against a user-defined
        # method without an RBS sig.
        discovered_def_nodes = build_discovered_def_nodes(root)
        seeded_scope = seeded_scope.with_discovered_def_nodes(discovered_def_nodes)

        table = {}.compare_by_identity
        table.default = seeded_scope

        on_enter = ->(node, scope) { table[node] = scope unless table.key?(node) }
        StatementEvaluator.new(scope: seeded_scope, on_enter: on_enter).evaluate(root)

        propagate(root, table, seeded_scope)
        table
      end

      # Slice 7 phase 2. Builds the class-level ivar accumulator
      # by walking every `Prism::ClassNode` / `Prism::ModuleNode`
      # body, descending into each nested `Prism::DefNode`, and
      # typing every `Prism::InstanceVariableWriteNode` rvalue
      # under a scope that carries the appropriate `self_type`
      # for that def (singleton vs instance). The rvalue is
      # typed with NO local bindings — the pre-pass lacks
      # statement-level threading — so `@x = 1` records
      # `Constant[1]` but `@x = some_local + 1` records
      # `Dynamic[Top]` (since `some_local` is unbound at
      # pre-pass time). Multiple writes to the same ivar union
      # via `Type::Combinator.union`.
      def build_class_ivar_index(root, default_scope)
        accumulator = {}
        walk_class_ivars(root, [], default_scope, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      def walk_class_ivars(node, qualified_prefix, default_scope, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_class_ivars(node.body, child_prefix, default_scope, accumulator) if node.body
            return
          end
        when Prism::DefNode
          collect_def_ivar_writes(node, qualified_prefix, default_scope, accumulator)
          return
        end

        node.compact_child_nodes.each do |child|
          walk_class_ivars(child, qualified_prefix, default_scope, accumulator)
        end
      end

      def collect_def_ivar_writes(def_node, qualified_prefix, default_scope, accumulator)
        return if def_node.body.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        self_type =
          if def_node.receiver.is_a?(Prism::SelfNode)
            Type::Combinator.singleton_of(class_name)
          else
            Type::Combinator.nominal_of(class_name)
          end
        body_scope = default_scope.with_self_type(self_type)

        gather_ivar_writes(def_node.body, body_scope, class_name, accumulator)
      end

      IVAR_BARRIER_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].freeze
      private_constant :IVAR_BARRIER_NODES

      def gather_ivar_writes(node, scope, class_name, accumulator)
        return unless node.is_a?(Prism::Node)

        record_ivar_write(node, scope, class_name, accumulator) if node.is_a?(Prism::InstanceVariableWriteNode)

        # Don't recurse into nested defs, classes, or modules; their
        # ivars belong to their own enclosing class.
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        node.compact_child_nodes.each { |c| gather_ivar_writes(c, scope, class_name, accumulator) }
      end

      def record_ivar_write(node, scope, class_name, accumulator)
        rvalue_type = scope.type_of(node.value)
        accumulator[class_name] ||= {}
        existing = accumulator[class_name][node.name]
        accumulator[class_name][node.name] =
          existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Slice 7 phase 6 — class-cvar pre-pass. Same shape as the
      # ivar pre-pass but collects `Prism::ClassVariableWriteNode`
      # writes inside ANY def body (instance or singleton) of the
      # enclosing class, because Ruby cvars are shared across both
      # facets. The resulting table is seeded into both instance
      # and singleton method bodies through
      # `Scope#class_cvars_for`.
      def build_class_cvar_index(root, default_scope)
        accumulator = {}
        walk_class_cvars(root, [], default_scope, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      def walk_class_cvars(node, qualified_prefix, default_scope, accumulator)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_class_cvars(node.body, child_prefix, default_scope, accumulator) if node.body
            return
          end
        when Prism::DefNode
          collect_def_cvar_writes(node, qualified_prefix, default_scope, accumulator)
          return
        end

        node.compact_child_nodes.each do |child|
          walk_class_cvars(child, qualified_prefix, default_scope, accumulator)
        end
      end

      def collect_def_cvar_writes(def_node, qualified_prefix, default_scope, accumulator)
        return if def_node.body.nil? || qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        body_scope = default_scope.with_self_type(Type::Combinator.nominal_of(class_name))
        gather_cvar_writes(def_node.body, body_scope, class_name, accumulator)
      end

      def gather_cvar_writes(node, scope, class_name, accumulator)
        return unless node.is_a?(Prism::Node)

        record_cvar_write(node, scope, class_name, accumulator) if node.is_a?(Prism::ClassVariableWriteNode)
        return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

        node.compact_child_nodes.each { |c| gather_cvar_writes(c, scope, class_name, accumulator) }
      end

      def record_cvar_write(node, scope, class_name, accumulator)
        rvalue_type = scope.type_of(node.value)
        accumulator[class_name] ||= {}
        existing = accumulator[class_name][node.name]
        accumulator[class_name][node.name] =
          existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Slice 7 phase 6 — program-global pre-pass. Globals are
      # process-wide so the accumulator is a flat
      # `Hash[Symbol, Type::t]` populated from every
      # `Prism::GlobalVariableWriteNode` in the program (top-level
      # AND inside method bodies). The same accumulator is
      # seeded into every method body and the top-level scope.
      def build_program_global_index(root, default_scope)
        accumulator = {}
        gather_global_writes(root, default_scope, accumulator)
        accumulator.freeze
      end

      def gather_global_writes(node, scope, accumulator)
        return unless node.is_a?(Prism::Node)

        record_global_write(node, scope, accumulator) if node.is_a?(Prism::GlobalVariableWriteNode)
        node.compact_child_nodes.each { |c| gather_global_writes(c, scope, accumulator) }
      end

      def record_global_write(node, scope, accumulator)
        rvalue_type = scope.type_of(node.value)
        existing = accumulator[node.name]
        accumulator[node.name] =
          existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Slice 7 phase 9 — in-source constant value pre-pass.
      # Walks the entire program (top-level AND inside class /
      # module / def bodies) for `Prism::ConstantWriteNode` and
      # `Prism::ConstantPathWriteNode`, types each rvalue, and
      # accumulates by qualified name. Constants defined inside
      # a class body are qualified with the surrounding class
      # path; constants written via a path (`Foo::BAR = ...`)
      # use the rendered path as-is.
      def build_in_source_constants(root, default_scope)
        accumulator = {}
        walk_constant_writes(root, [], default_scope, accumulator)
        accumulator.freeze
      end

      def walk_constant_writes(node, qualified_prefix, default_scope, accumulator) # rubocop:disable Metrics/CyclomaticComplexity
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_constant_writes(node.body, child_prefix, default_scope, accumulator) if node.body
            return
          end
        when Prism::ConstantWriteNode
          record_constant_write(node, qualified_prefix, default_scope, accumulator, node.name.to_s)
          return
        when Prism::ConstantPathWriteNode
          full = qualified_name_for(node.target)
          record_constant_write(node, [], default_scope, accumulator, full) if full
          return
        end

        node.compact_child_nodes.each do |child|
          walk_constant_writes(child, qualified_prefix, default_scope, accumulator)
        end
      end

      def record_constant_write(node, qualified_prefix, default_scope, accumulator, base_name)
        full = qualified_prefix.empty? ? base_name : "#{qualified_prefix.join('::')}::#{base_name}"
        body_scope = default_scope
        unless qualified_prefix.empty?
          body_scope = body_scope.with_self_type(Type::Combinator.singleton_of(qualified_prefix.join("::")))
        end
        rvalue_type = body_scope.type_of(node.value)
        existing = accumulator[full]
        accumulator[full] = existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
      end

      # Slice 7 phase 12 — in-source method discovery pre-pass.
      # Walks every class/module body and records the methods
      # introduced via `Prism::DefNode` (instance + singleton)
      # and via recognised `define_method(:name) { ... }` calls.
      # The returned table maps qualified class name to a
      # `Hash[Symbol, :instance | :singleton]`.
      def build_discovered_methods(root)
        accumulator = {}
        walk_methods(root, [], false, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      def walk_methods(node, qualified_prefix, in_singleton_class, accumulator) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_methods(node.body, child_prefix, false, accumulator) if node.body
            return
          end
        when Prism::SingletonClassNode
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_methods(node.body, qualified_prefix, true, accumulator)
            return
          end
        when Prism::DefNode
          record_def_method(node, qualified_prefix, in_singleton_class, accumulator)
          return
        when Prism::CallNode
          record_define_method(node, qualified_prefix, in_singleton_class, accumulator) if node.name == :define_method
        end

        node.compact_child_nodes.each do |child|
          walk_methods(child, qualified_prefix, in_singleton_class, accumulator)
        end
      end

      def record_def_method(def_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        kind = def_node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
        accumulator[class_name] ||= {}
        accumulator[class_name][def_node.name] = kind
      end

      # v0.0.2 #5 — instance-side def-node recording. Walks
      # class bodies the same way as `build_discovered_methods`
      # but records the actual `Prism::DefNode` for each
      # **instance** method so `ExpressionTyper` can re-type
      # the body at the call site for inter-procedural return
      # inference. Singleton methods and `define_method` calls
      # are intentionally skipped: the inference path needs a
      # statically introspectable body, and singleton dispatch
      # has its own complications (Class / Module ancestry)
      # the first-iteration rule does not yet model.
      def build_discovered_def_nodes(root)
        accumulator = {}
        walk_def_nodes(root, [], false, accumulator)
        accumulator.transform_values(&:freeze).freeze
      end

      def walk_def_nodes(node, qualified_prefix, in_singleton_class, accumulator) # rubocop:disable Metrics/CyclomaticComplexity
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_name_for(node.constant_path)
          if name
            child_prefix = qualified_prefix + [name]
            walk_def_nodes(node.body, child_prefix, false, accumulator) if node.body
            return
          end
        when Prism::SingletonClassNode
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_def_nodes(node.body, qualified_prefix, true, accumulator)
            return
          end
        when Prism::DefNode
          record_def_node(node, qualified_prefix, in_singleton_class, accumulator)
          return
        end

        node.compact_child_nodes.each do |child|
          walk_def_nodes(child, qualified_prefix, in_singleton_class, accumulator)
        end
      end

      # v0.0.3 A — sentinel key under which `record_def_node`
      # files DefNodes that live outside any class / module
      # body (top-level helpers, `def`s nested inside DSL
      # blocks like `RSpec.describe ... do; def helper; end`).
      # Looked up by `Scope#top_level_def_for` to give
      # implicit-self calls priority over RBS dispatch when
      # the file defines a same-named local method.
      TOP_LEVEL_DEF_KEY = "<toplevel>"

      def record_def_node(def_node, qualified_prefix, in_singleton_class, accumulator)
        return if def_node.receiver.is_a?(Prism::SelfNode) || in_singleton_class

        class_name = qualified_prefix.empty? ? TOP_LEVEL_DEF_KEY : qualified_prefix.join("::")
        accumulator[class_name] ||= {}
        accumulator[class_name][def_node.name] = def_node
      end

      def record_define_method(call_node, qualified_prefix, in_singleton_class, accumulator)
        return if qualified_prefix.empty?
        return if call_node.arguments.nil? || call_node.arguments.arguments.empty?

        first_arg = call_node.arguments.arguments.first
        method_name = literal_method_name(first_arg)
        return if method_name.nil?

        class_name = qualified_prefix.join("::")
        accumulator[class_name] ||= {}
        accumulator[class_name][method_name] = in_singleton_class ? :singleton : :instance
      end

      def literal_method_name(node)
        return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        node.unescaped&.to_sym
      end

      # Walks the program once for `Prism::ModuleNode` and
      # `Prism::ClassNode`, recording the `Singleton[<qualified>]`
      # type for the outermost `constant_path` node of each
      # declaration. Inner segments of a `class Foo::Bar::Baz`
      # path remain real references (resolved through the
      # ordinary lexical walk), so we annotate ONLY the topmost
      # path node. Nested declarations contribute their fully
      # qualified path: `class A::B; class C; ...` produces
      # `A::B` for the outer and `A::B::C` for the inner.
      def build_declaration_artifacts(root)
        identity_table = {}.compare_by_identity
        discovered = {}
        record_declarations(root, [], identity_table, discovered)
        [identity_table.freeze, discovered.freeze]
      end

      def record_declarations(node, qualified_prefix, identity_table, discovered)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ModuleNode, Prism::ClassNode
          name = qualified_name_for(node.constant_path)
          if name
            full = (qualified_prefix + [name]).join("::")
            singleton = Type::Combinator.singleton_of(full)
            identity_table[node.constant_path] = singleton
            discovered[full] = singleton
            child_prefix = qualified_prefix + [name]
            record_declarations(node.body, child_prefix, identity_table, discovered) if node.body
            return
          end
        end

        node.compact_child_nodes.each do |child|
          record_declarations(child, qualified_prefix, identity_table, discovered)
        end
      end

      def qualified_name_for(constant_path_node)
        case constant_path_node
        when Prism::ConstantReadNode
          constant_path_node.name.to_s
        when Prism::ConstantPathNode
          render_constant_path(constant_path_node)
        end
      end

      def render_constant_path(node)
        prefix =
          case node.parent
          when Prism::ConstantReadNode then "#{node.parent.name}::"
          when Prism::ConstantPathNode then "#{render_constant_path(node.parent)}::"
          else ""
          end
        "#{prefix}#{node.name}"
      end

      # Walks `node`'s subtree DFS and fills in scope entries for every
      # Prism node the StatementEvaluator did not visit (i.e. expression-
      # interior nodes like the receiver/args of a CallNode). Those
      # nodes inherit their nearest recorded ancestor's scope.
      def propagate(node, table, parent_scope)
        return unless node.is_a?(Prism::Node)

        current_scope =
          if table.key?(node)
            table[node]
          else
            table[node] = parent_scope
            parent_scope
          end

        node.compact_child_nodes.each { |child| propagate(child, table, current_scope) }
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
