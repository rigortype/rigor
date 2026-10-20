# frozen_string_literal: true

require "prism"

require_relative "../global_write_census"
require_relative "../reflective_ivar_write"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #1154 — whether code the class-ivar census of `class_name` never walks may write the instance variable
      # `ivar` on its instances. The census joins only the writes in the class's own bodies in this file, so a
      # declared-parameter write ({DeclaredParamWrites}) is credited only when this answers false:
      #
      # - a project ancestor on the class's instance resolution chain (a superclass, or a module it or an ancestor
      #   includes or prepends) defines the writer `ivar=` (an `attr_writer` / `attr_accessor` or a `def`), or has an
      #   instance `def` whose body writes the ivar, in any form, or calls `instance_variable_set` on `self` (`super`
      #   from the class's `initialize`, or an inherited setter, runs it on the instance);
      # - an ancestor the project does not declare is reached through a superclass edge and is not Ruby's own (a
      #   gem's `initialize` may write any ivar), or the chain was cut;
      # - the project's {GlobalWriteCensus} records a write to the ivar from outside the object
      #   (`o.instance_variable_set(:@x, v)`, `o.instance_eval { @x = v }`), or one whose name it cannot read.
      #
      # An ancestor's `define_method` body is not read: the ancestor's own file census sees it, this file does not.
      #
      # Every read files its ADR-46 edge: each project ancestor's declaring files ({Scope::ResolutionChain.record_entry})
      # and each of its `def`s read ({Scope#user_def_for}), and the `ivar_set:` name key the incremental session fires
      # when a file starts or stops writing the ivar from outside.
      module UnseenIvarWriters
        BARRIERS = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
        private_constant :BARRIERS

        module_function

        def possible?(scope, class_name, ivar)
          foreign_write?(scope, ivar) || ancestor_write?(scope, class_name, ivar)
        end

        def foreign_write?(scope, ivar)
          if Analysis::DependencyRecorder.active?
            Analysis::DependencyRecorder.read_name(:ivar_set, ivar.to_s)
            Analysis::DependencyRecorder.read_name(:ivar_set, "*")
          end
          census = scope.discovered_global_write_census
          pre_eval = scope.environment&.project_patched_methods&.write_census
          GlobalWriteCensus.foreign_ivar_write?(census, ivar) ||
            (!pre_eval.nil? && GlobalWriteCensus.foreign_ivar_write?(pre_eval, ivar))
        end

        def ancestor_write?(scope, class_name, ivar)
          chain = Scope::ResolutionChain.for(scope, class_name, :instance, :constants)
          return true if chain.truncated?

          setter = :"#{ivar.to_s.delete_prefix('@')}="
          chain.entries.any? do |entry|
            next false if entry.side != :instance || entry.name == class_name

            Scope::ResolutionChain.record_entry(scope, entry, :instance) if Analysis::DependencyRecorder.active?
            next foreign_superclass?(scope, entry) if entry.external?

            scope.discovered_method?(entry.name, setter, :instance) || defs_write?(scope, entry.name, ivar)
          end
        end

        # A superclass the project does not declare whose initializer Ruby does not ship: a gem's class may write
        # any ivar of its subclass's instances. A module the project does not declare is left alone.
        def foreign_superclass?(scope, entry)
          return false unless entry.superclass_edge

          loader = scope.environment&.rbs_loader
          entry.candidates.empty? || entry.candidates.none? { |name| loader&.core_or_stdlib_class?(name) }
        end

        def defs_write?(scope, owner, ivar)
          (scope.discovered_def_nodes[owner] || {}).each_key.any? do |method_name|
            node = scope.user_def_for(owner, method_name)
            node.is_a?(Prism::DefNode) && writes?(node.body, ivar)
          end
        end

        def reflective_name(node) = ReflectiveIvarWrite.literal_name(node)

        def writes?(node, ivar)
          return false unless node.is_a?(Prism::Node)
          return false if BARRIERS.any? { |klass| node.is_a?(klass) }

          case node
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
               Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableTargetNode
            return true if node.name == ivar
          end
          # A literal `instance_variable_set` of the ivar, or one whose name no literal spells.
          return true if ReflectiveIvarWrite.self_write?(node) && [ivar, nil].include?(reflective_name(node))

          node.rigor_each_child { |child| return true if writes?(child, ivar) }
          false
        end
      end
    end
  end
end
