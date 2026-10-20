# frozen_string_literal: true

require "prism"

require_relative "../../reflection"
require_relative "../method_parameter_binder"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #1154 — the class-ivar census types an `@x = x` write whose right-hand side reads a parameter of the
      # enclosing instance `def` as that parameter's DECLARED type: the method's RBS signature, from `sig/` or from
      # an rbs-inline `# @rbs` / `#:` annotation, read through {MethodParameterBinder}, the binder the method body's
      # own entry scope uses. Without it the census typed the rvalue with no local bindings, so a constructor field
      # read `Dynamic[top]` in every sibling method even where `sig/` declared `initialize: (String x) -> void`.
      #
      # The census is flow-free, so a write is credited only where the parameter can hold nothing but its
      # argument. {.collect} answers `{write node => declared type}` (an identity Hash) for the writes that pass
      # every gate, and {EMPTY} otherwise; an absent write keeps the census's ordinary rvalue typing, so a declined
      # case reads exactly what it read before:
      #
      # - the write's value is a bare read of the parameter (`@x = x`), not an expression over it;
      # - the write is not inside a block or a lambda, so a block parameter of the same name and a block that runs
      #   under another `self` (`instance_eval`, `Class.new`, `define_method`) never borrow the method's parameter;
      # - the method body never writes the parameter, in any form and at any depth (`x = Integer(x)`, `x ||= …`,
      #   a `rescue => x` or pattern target);
      # - the owner is a class, not a module (a module's ivar belongs to whichever object includes it), and its
      #   RBS declares the method itself (`defined_in`), so an inherited signature never types a redefinition;
      # - the signature has exactly one overload, whose parameter lists are typed (`(?)` declines) and mention no
      #   type variable (a class `Box[T]` or a method `[T]` variable is unsolved at the write);
      # - the class is declared in one file: the census is per file, so a second `initialize` in a reopening
      #   elsewhere could not be joined, and the type is not taken from one of them;
      # - the declared type is not `untyped`, which is what the write already records.
      module DeclaredParamWrites
        EMPTY = {}.compare_by_identity.freeze

        LOCAL_WRITE_NODES = [
          Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
          Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableTargetNode
        ].freeze
        private_constant :LOCAL_WRITE_NODES

        SCOPE_BARRIERS = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
        private_constant :SCOPE_BARRIERS

        BLOCK_NODES = [Prism::BlockNode, Prism::LambdaNode].freeze
        private_constant :BLOCK_NODES

        module_function

        # `{InstanceVariableWriteNode => Rigor::Type}` for `def_node`'s creditable writes, or {EMPTY}. The caller
        # passes only an instance `def`: a singleton body's `@x` is the class object's.
        def collect(def_node, class_name, scope)
          return EMPTY if def_node.body.nil? || def_node.parameters.nil?

          written = Set.new
          writes = []
          scan(def_node.body, written, writes, in_block: false)
          writes.reject! { |write| written.include?(write.value.name) }
          return EMPTY if writes.empty?

          types = declared_types(def_node, class_name, scope)
          credited = writes.each_with_object({}.compare_by_identity) do |write, acc|
            type = types[write.value.name]
            acc[write] = type if type
          end
          credited.empty? ? EMPTY : credited
        rescue StandardError
          EMPTY
        end

        # Collects the `@x = local` writes outside every block, and the name of every local the body writes in
        # any form at any depth. A read at depth zero outside a block names the method's own local, which is the
        # parameter when the body never writes the name.
        def scan(node, written, writes, in_block:)
          return unless node.is_a?(Prism::Node)
          return if SCOPE_BARRIERS.any? { |klass| node.is_a?(klass) }

          written << node.name if LOCAL_WRITE_NODES.any? { |klass| node.is_a?(klass) }
          writes << node if !in_block && local_read_write?(node)
          inner = in_block || BLOCK_NODES.any? { |klass| node.is_a?(klass) }
          node.rigor_each_child { |child| scan(child, written, writes, in_block: inner) }
        end

        def local_read_write?(node)
          node.is_a?(Prism::InstanceVariableWriteNode) && node.value.is_a?(Prism::LocalVariableReadNode) &&
            node.value.depth.zero?
        end

        # The declared, non-`untyped` type of each parameter, or `{}` when a gate declines the method.
        def declared_types(def_node, class_name, scope)
          environment = scope&.environment
          return {} if environment.nil? || !single_declaring_file?(scope, class_name)
          return {} if environment.rbs_module?(class_name)

          rbs_method = Reflection.instance_method_definition(class_name, def_node.name, environment: environment)
          return {} unless sole_typed_overload?(rbs_method, class_name)

          binder = MethodParameterBinder.new(environment: environment, class_path: class_name, singleton: false)
          binder.bind(def_node).reject { |_name, type| type.is_a?(Type::Dynamic) }
        end

        def sole_typed_overload?(rbs_method, class_name)
          return false if rbs_method.nil? || rbs_method.defined_in.to_s.delete_prefix("::") != class_name

          method_types = rbs_method.method_types
          return false unless method_types.size == 1

          function = method_types.first.type
          function.respond_to?(:required_positionals) && function.free_variables.empty?
        end

        # Files the ADR-46 edges the answer reads: every file declaring the class (so removing a reopening
        # re-checks), and the `class:` name key a class-declaration diff fires (so adding one does).
        def single_declaring_file?(scope, class_name)
          if Analysis::DependencyRecorder.active?
            Scope::ResolutionChain.record_class(scope, class_name)
            Analysis::DependencyRecorder.read_last_segment(:class, class_name)
          end
          (scope.discovered_class_sources[class_name]&.size || 0) <= 1
        end
      end
    end
  end
end
