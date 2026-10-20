# frozen_string_literal: true

require "prism"

require_relative "../global_write_census"
require_relative "../reflective_ivar_write"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #1154 — whether code the class-ivar census of `class_name` never walks may write the instance variable
      # `ivar` on its instances, where a literal write in the same place would answer for it too. The census joins
      # only the writes in the class's own bodies in one file, so a declared-parameter write ({DeclaredParamWrites}) is
      # credited only when this answers false. The standard is parity with a literal write: what an unknown object's
      # code may do is accepted, as it is for `@x = 1` (the {IvarWriterCensus} policy), and what the class or its
      # ancestors do is not:
      #
      # - a project ancestor on the class's instance resolution chain (a superclass, or a module it or an ancestor
      #   includes or prepends) defines the writer `ivar=` (an `attr_writer` / `attr_accessor` or a `def`), or has an
      #   instance `def` whose body writes the ivar, in any form, or calls `instance_variable_set` on `self` (`super`
      #   from the class's `initialize`, or an inherited setter, runs it on the instance);
      # - an ancestor the project does not declare is reached through a superclass edge and is not a core class (a
      #   gem's or a Ruby-written stdlib class's `initialize` may write any ivar), or the chain was cut;
      # - the class or a project ancestor holds an open-world self writer in an instance body (`[:ivar_set_class, …]`,
      #   `def configure(&b) = instance_eval(&b)`);
      # - a file other than this one writes the same ivar in an instance `def` of the class (`[:own_write, …]`): the
      #   census is per file, so a reopening's write would not be joined;
      # - the project's {GlobalWriteCensus} records a named write to the ivar from outside the object
      #   (`o.instance_variable_set(:@x, v)`, `o.instance_eval { @x = v }`).
      #
      # An ancestor's `define_method` body is not read: the ancestor's own file census sees it, this file does not.
      #
      # Every read files its ADR-46 edge: each project ancestor's declaring files ({Scope::ResolutionChain.record_entry})
      # and each of its `def`s read ({Scope#user_def_for}), and the `ivar_set:`, `ivar_set_class:` and `own_write:`
      # name keys the incremental session fires when a file's entries move.
      module UnseenIvarWriters
        BARRIERS = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
        private_constant :BARRIERS

        module_function

        def possible?(scope, class_name, ivar)
          census = census(scope)
          foreign_write?(census, ivar) || class_open_world?(census, class_name) ||
            other_file_write?(census, class_name, ivar) || ancestor_write?(scope, census, class_name, ivar)
        end

        def census(scope)
          census = scope.discovered_global_write_census
          pre_eval = scope.environment&.project_patched_methods&.write_census
          pre_eval.nil? || pre_eval.empty? ? census : census | pre_eval
        end

        def foreign_write?(census, ivar)
          Analysis::DependencyRecorder.read_name(:ivar_set, ivar.to_s) if Analysis::DependencyRecorder.active?
          census.include?([:ivar_set, ivar])
        end

        def class_open_world?(census, class_name)
          # A guard: the entry comes from an instance body of the class (or an ancestor), whose declaring files the
          # class's own resolution already re-checks; kept so the read states its own dependency.
          Analysis::DependencyRecorder.read_name(:ivar_set_class, class_name) if Analysis::DependencyRecorder.active?
          census.include?([:ivar_set_class, class_name])
        end

        # More than one file records an instance-`def` write of the ivar for the class: this file's census sees its
        # own only. An entry no path tags (a census built outside the project pre-pass) counts as this file.
        def other_file_write?(census, class_name, ivar)
          if Analysis::DependencyRecorder.active?
            Analysis::DependencyRecorder.read_name(:own_write, "#{class_name}##{ivar}")
          end
          paths = census.filter_map do |entry|
            entry[3] if entry.size == 4 && entry[0] == :own_write && entry[1] == class_name && entry[2] == ivar
          end
          paths.uniq.size > 1
        end

        def ancestor_write?(scope, census, class_name, ivar)
          chain = Scope::ResolutionChain.for(scope, class_name, :instance, :constants)
          return true if chain.truncated?

          setter = :"#{ivar.to_s.delete_prefix('@')}="
          chain.entries.any? do |entry|
            next false if entry.side != :instance || entry.name == class_name

            # A guard: the class body's own `include` / `<` resolution already files this edge; kept so the read
            # states its own dependency.
            Scope::ResolutionChain.record_entry(scope, entry, :instance) if Analysis::DependencyRecorder.active?
            next foreign_superclass?(scope, entry) if entry.external?

            class_open_world?(census, entry.name) || scope.discovered_method?(entry.name, setter, :instance) ||
              defs_write?(scope, entry.name, ivar)
          end
        end

        # A superclass the project does not declare that the interpreter does not implement: a gem's class, or a
        # stdlib one written in Ruby (`Logger` sets `@level` in `initialize`), may write any ivar of its subclass's
        # instances. A module the project does not declare is left alone.
        def foreign_superclass?(scope, entry)
          return false unless entry.superclass_edge

          loader = scope.environment&.rbs_loader
          entry.candidates.empty? || entry.candidates.none? { |name| loader&.core_class?(name) }
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
