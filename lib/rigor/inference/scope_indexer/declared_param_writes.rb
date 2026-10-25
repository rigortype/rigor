# frozen_string_literal: true

require "prism"

require_relative "../../reflection"
require_relative "../method_parameter_binder"
require_relative "../global_write_census"
require_relative "unseen_ivar_writers"

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
      # - the write's value reads at least one parameter, and every local it reads is a parameter with a declared type.
      #   A bare read (`@x = x`) records that type; an expression over parameters (`@x = x.dup.freeze`,
      #   `@x = Array(x)`, `@x = f ? x : y`, issue #2321) records the value typed with each parameter it reads bound to
      #   its declared type, unless a parameter it reads holds `untyped` at any depth (`Array[untyped]`, #2325). A
      #   value that holds a block, a lambda or a nested `def` is not credited: their own parameters are locals the
      #   scan does not bind;
      # - the write is not inside a block or a lambda, so a block parameter of the same name and a block that runs
      #   under another `self` (`instance_eval`, `Class.new`, `define_method`) never borrow the method's parameter;
      # - the method body never writes the parameter, in any form and at any depth (`x = Integer(x)`, `x ||= …`,
      #   a `rescue => x` or pattern target);
      # - the owner is a class, not a module (a module's ivar belongs to whichever object includes it), and its
      #   RBS declares the method itself (`defined_in`), so an inherited signature never types a redefinition;
      # - the signature has exactly one overload, whose parameter lists are typed (`(?)` declines) and mention no
      #   type variable (a class `Box[T]` or a method `[T]` variable is unsolved at the write);
      # - the class's primary RBS declaration is the project's (`sig/` or rbs-inline), not core, stdlib or a gem's:
      #   a project reopening of a library class (`Thread::SizedQueue#initialize`) would otherwise borrow the
      #   library's parameter type for its own `def`;
      # - the body neither calls `binding` nor passes code as an argument to an `eval`-family call
      #   (`OPAQUE_EVAL_CALLS`), any of which can rewrite the parameter unseen;
      # - nothing outside the class's own census may write the ivar ({UnseenIvarWriters}): no project ancestor, and
      #   no other object's code (`o.instance_variable_set(:@x, v)`);
      # - the declared type is not `untyped`, which is what the write already records.
      module DeclaredParamWrites
        EMPTY = {}.compare_by_identity.freeze

        SCOPE_BARRIERS = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
        private_constant :SCOPE_BARRIERS

        BLOCK_NODES = [Prism::BlockNode, Prism::LambdaNode].freeze
        private_constant :BLOCK_NODES

        OPAQUE_EVAL_CALLS = %i[eval instance_eval class_eval module_eval instance_exec class_exec
                               module_exec].to_set.freeze
        private_constant :OPAQUE_EVAL_CALLS

        WRITER_SCOPE_KEY = :__rigor_declared_param_writer_scope__
        private_constant :WRITER_SCOPE_KEY

        module_function

        # Runs the block with `scope` as the one whose project tables the unseen-writer and single-file gates read, in
        # place of the census's own scope. `rigor sig-gen` indexes each file under a scope that carries no project
        # tables, so without it another file's writer, ancestor or reopening would go unseen.
        def with_writer_scope(scope)
          return yield if scope.nil?

          previous = Thread.current[WRITER_SCOPE_KEY]
          Thread.current[WRITER_SCOPE_KEY] = scope
          begin
            yield
          ensure
            Thread.current[WRITER_SCOPE_KEY] = previous
          end
        end

        def writer_scope(scope) = Thread.current[WRITER_SCOPE_KEY] || scope

        # `{InstanceVariableWriteNode => Rigor::Type}` for `def_node`'s creditable writes, or {EMPTY}. The caller
        # passes only an instance `def`: a singleton body's `@x` is the class object's.
        def collect(def_node, class_name, scope)
          return EMPTY if def_node.body.nil? || def_node.parameters.nil?

          written = Set.new
          writes = []
          return EMPTY if scan(def_node.body, written, writes, in_block: false) == :opaque

          reads = unwritten_reads(writes, written)
          return EMPTY if reads.empty?

          types = declared_types(def_node, class_name, scope)
          writers = writer_scope(scope)
          credited = reads.each_with_object({}.compare_by_identity) do |(write, names), acc|
            next unless names.all? { |name| types.key?(name) }

            type = value_type(write.value, names, types, scope)
            acc[write] = type if type && !UnseenIvarWriters.possible?(writers, class_name, write.name)
          end
          credited.empty? ? EMPTY : credited
        rescue StandardError
          EMPTY
        end

        # `{write => names of the locals its value reads}` for each write whose value reads at least one local and no
        # local the body writes.
        def unwritten_reads(writes, written)
          writes.each_with_object({}.compare_by_identity) do |write, acc|
            names = parameter_reads(write.value)
            next if names.nil? || names.empty? || names.any? { |name| written.include?(name) }

            acc[write] = names
          end
        end

        # The names of the locals `value` reads, or nil when it holds a block, a lambda or a scope barrier.
        def parameter_reads(value, names = Set.new)
          return names unless value.is_a?(Prism::Node)
          return nil if BLOCK_NODES.any? { |klass| value.is_a?(klass) }
          return nil if SCOPE_BARRIERS.any? { |klass| value.is_a?(klass) }

          names << value.name if value.is_a?(Prism::LocalVariableReadNode)
          value.rigor_each_child do |child|
            return nil if parameter_reads(child, names).nil?
          end
          names
        end

        # A bare read takes the declared type itself; an expression over the parameters is typed with each bound to
        # its declared type. An expression over a parameter whose declared type holds `untyped` at any depth
        # (`Array[untyped]`) is not credited (#2325): its answer would be built on the parameter the author left
        # untyped.
        def value_type(value, names, types, scope)
          return types[value.name] if value.is_a?(Prism::LocalVariableReadNode)
          return nil if names.any? { |name| carries_dynamic?(types[name]) }

          bound = names.reduce(scope) { |acc, name| acc.with_local(name, types[name]) }
          bound.type_of(value)
        rescue StandardError
          nil
        end

        # Collects the `@x = …` writes outside every block, and the name of every local the body writes in
        # any form at any depth. A read at depth zero outside a block names the method's own local, which is the
        # parameter when the body never writes the name.
        #
        # Answers `:opaque` when the body can rewrite a local through code the scan cannot read: a `binding` call, or
        # an `eval`-family call given an argument ({OPAQUE_EVAL_CALLS}).
        def scan(node, written, writes, in_block:)
          return unless node.is_a?(Prism::Node)
          return if SCOPE_BARRIERS.any? { |klass| node.is_a?(klass) }

          case node
          when Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
               Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableTargetNode
            written << node.name
          when Prism::CallNode
            return :opaque if opaque_call?(node)
          end
          writes << node if !in_block && node.is_a?(Prism::InstanceVariableWriteNode)
          inner = in_block || BLOCK_NODES.any? { |klass| node.is_a?(klass) }
          node.rigor_each_child do |child|
            return :opaque if scan(child, written, writes, in_block: inner) == :opaque
          end
          nil
        end

        # `binding` hands the frame's locals to code that may write them (`binding.eval("x = 's'")`,
        # `Helper.rw(binding)`); a string passed to an `eval`-family call is code the scan cannot read.
        def opaque_call?(node)
          return true if node.name == :binding

          OPAQUE_EVAL_CALLS.include?(node.name) && !(node.arguments&.arguments || []).empty?
        end

        def carries_dynamic?(type)
          case type
          when Type::Dynamic then true
          when Type::Union, Type::Intersection then type.members.any? { |member| carries_dynamic?(member) }
          when Type::Nominal then type.type_args.any? { |arg| carries_dynamic?(arg) }
          when Type::Tuple then type.elements.any? { |element| carries_dynamic?(element) }
          when Type::HashShape then type.pairs.each_value.any? { |pair_value| carries_dynamic?(pair_value) }
          when Type::Difference, Type::Refined then carries_dynamic?(type.base)
          else false
          end
        end

        # The declared, non-`untyped` type of each parameter, or `{}` when a gate declines the method.
        def declared_types(def_node, class_name, scope)
          environment = scope&.environment
          return {} if environment.nil?
          return {} if environment.rbs_module?(class_name)
          return {} unless Reflection.project_declared_class?(class_name, environment: environment)

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
      end
    end
  end
end
