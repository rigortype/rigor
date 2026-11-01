# frozen_string_literal: true

require "prism"
require_relative "../source/node_walker"
require_relative "../source/node_children"

module Rigor
  module Inference
    # Issue #2555 L3 — which locals of a body may have ESCAPED, so a write to them never carries the `:synthesised`
    # construction fact ({Scope#construction_fact?}).
    #
    # The fact lets the mutation seams re-grow a carrier without the `Dynamic[top]` floor, and the floor existed
    # because a store the seam does not see leaves the carrier stale. A store reaches a local's object unseen only
    # through another holder of it, and almost any position can make one: an alias, a container, an argument (a
    # constructor or an attribute writer keeps it, `Array(a)` and `ident(a)` return it), a call that returns the
    # receiver for some class (`Set#merge`, `a.each`), or a method the project defines. So every reference escapes
    # unless it is in one of these positions:
    #
    # - the receiver of a call on the per-class {READERS} list, which neither returns, keeps nor mutates its receiver;
    # - the receiver of an {ITERATORS} call or of a mutator the seams model ({.mutators_for}), with the call's value
    #   discarded;
    # - the body's value position (its last statement, or `return a`), after which nothing in the body runs;
    # - a bare read whose value is discarded.
    #
    # A listed name the project defines on the class itself (`class Array; def first …`) escapes all the same
    # ({.escaped?} asks the scope). Every argument position escapes, and so does any reference inside a block or
    # lambda, a write whose value is used (`a = b = …`), and every local of a body that calls `binding`, `eval`,
    # `local_variable_set`, `instance_variable_set` or a string-form `instance_eval` / `class_eval` / `module_eval`.
    # The scan is flow insensitive and runs once per body, so an escape anywhere drops the fact for the whole body:
    # the conservative direction, since without the fact the seams answer as before. A nested `def` or class body is
    # scanned too, though its locals are its own; a same-named local there can only over-report an escape.
    module ConstructionEscape
      CLASSES = %w[Array Hash Set].freeze

      # The calls that answer a value other than the receiver, keep no reference to it, and change nothing in it.
      READERS = Ractor.make_shareable(
        {
          "Array" => %i[
            size length count empty? any? none? all? include? first last [] dig fetch index find_index sum min max
            join dup map select filter reject sort sort_by uniq compact flatten reverse take drop to_h to_set ==
          ].to_set,
          "Hash" => %i[
            size length count empty? any? include? key? has_key? member? value? has_value? [] dig fetch keys values
            dup map select filter reject to_a ==
          ].to_set,
          "Set" => %i[size length count empty? any? include? member? first dup map select filter reject to_a ==].to_set
        }
      )

      # The calls that answer the receiver itself and yield only its members: safe with their value discarded.
      ITERATORS = Ractor.make_shareable(
        {
          "Array" => %i[each each_with_index each_index reverse_each].to_set,
          "Hash" => %i[each each_pair each_key each_value each_with_index].to_set,
          "Set" => %i[each].to_set
        }
      )

      # Calls that read or rebind the frame's locals by name: one anywhere in a body escapes every local in it.
      FRAME_CALLS = %i[binding eval local_variable_set instance_variable_set].to_set.freeze
      STRING_EVAL_CALLS = %i[instance_eval class_eval module_eval].to_set.freeze

      CLOSURES = [Prism::BlockNode, Prism::LambdaNode].freeze
      LOCAL_REFERENCES = [
        Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode
      ].freeze
      LOCAL_WRITES = [
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode
      ].freeze
      ALL = :all
      EMPTY_CALLS = Set.new.freeze
      CACHE_KEY = :__rigor_construction_escape
      private_constant :CLOSURES, :LOCAL_REFERENCES, :LOCAL_WRITES, :ALL, :EMPTY_CALLS, :CACHE_KEY,
                       :STRING_EVAL_CALLS

      # One body's answer: per name, ALL or the classes it escapes as, and the calls the scan admitted on it.
      Result = Data.define(:escapes, :calls)
      private_constant :Result

      module_function

      # True when the local `name`, bound to a carrier of `class_name`, may escape somewhere in `body`, or when
      # `body` is unknown. `scope` answers whether the project defines one of the admitted calls on the class
      # ({.project_defines?}).
      def escaped?(body, name, class_name, scope)
        return true if body.nil? || class_name.nil?

        table = (Thread.current[CACHE_KEY] ||= ObjectSpace::WeakKeyMap.new)
        result = table[body] ||= scan(body)
        return true if result.equal?(ALL)

        reason = result.escapes[name]
        return true if !reason.nil? && (reason.equal?(ALL) || reason.include?(class_name))

        result.calls.fetch(name, EMPTY_CALLS).any? { |call| project_defines?(scope, class_name, call) }
      end

      # Whether the project writes `def call` in a body of `class_name` itself, in any file. `discovered_methods` is not
      # enough: it withholds a plain cross-file `def` on an RBS-declared class (ADR-17), which is exactly a reopen of
      # Array, Hash or Set. The def-node table holds it (a `DefHandle` on a bundle-rebuilt index; the lookup records the
      # cross-file dependency for incremental runs). A `def` in a module the class includes is not read here.
      def project_defines?(scope, class_name, call)
        scope.discovered_method?(class_name, call, :instance) || !scope.user_def_for(class_name, call).nil?
      end

      # The receiver mutators the seams model for `class_name` ({MutationWidening}, {HashLookupMutation},
      # {SetMutation}).
      def mutators_for(class_name)
        case class_name
        when "Array" then MutationWidening::ARRAY_MUTATORS
        when "Hash" then MutationWidening::HASH_MUTATORS | HashLookupMutation::MUTATORS
        else SetMutation::MUTATORS
        end
      end

      def scan(body)
        escapes = {}
        calls = {}
        Source::NodeWalker.each_with_ancestors(body) do |node, ancestors|
          return ALL if frame_call?(node)
          next unless LOCAL_REFERENCES.any? { |k| node.is_a?(k) }

          record(escapes, calls, node, ancestors)
        end
        Result.new(escapes: escapes.freeze, calls: calls.freeze)
      end

      def record(escapes, calls, node, ancestors)
        name = node.name
        call = receiver_call(node, ancestors)
        unsafe =
          if call
            unsafe_classes(call, ancestors).tap { |u| (calls[name] ||= Set.new) << call.name if u.size < CLASSES.size }
          else
            escape_reference?(node, ancestors) ? CLASSES : []
          end
        return if unsafe.empty? || escapes[name].equal?(ALL)

        escapes[name] = unsafe.size == CLASSES.size ? ALL : (escapes[name] || Set.new).merge(unsafe)
      end

      def frame_call?(node)
        return false unless node.is_a?(Prism::CallNode)

        FRAME_CALLS.include?(node.name) || (STRING_EVAL_CALLS.include?(node.name) && !node.arguments.nil?)
      end

      # The call a read outside any closure is the receiver of, or nil.
      def receiver_call(node, ancestors)
        return nil unless node.is_a?(Prism::LocalVariableReadNode) && !in_closure?(ancestors)

        parent = ancestors.last
        parent if parent.is_a?(Prism::CallNode) && parent.receiver.equal?(node)
      end

      # The classes for which `call` on the local may hand it on.
      def unsafe_classes(call, ancestors)
        discarded = !value_used?(ancestors, ancestors.size - 2, call)
        CLASSES.reject do |class_name|
          READERS.fetch(class_name).include?(call.name) ||
            (discarded && (ITERATORS.fetch(class_name).include?(call.name) ||
                           mutators_for(class_name).include?(call.name)))
        end
      end

      def in_closure?(ancestors)
        ancestors.any? { |a| CLOSURES.any? { |k| a.is_a?(k) } }
      end

      # Whether a reference that is no call's receiver may hand the object on.
      def escape_reference?(node, ancestors)
        return true if in_closure?(ancestors)
        return value_used?(ancestors, ancestors.size - 1, node) if LOCAL_WRITES.any? { |k| node.is_a?(k) }
        return false unless node.is_a?(Prism::LocalVariableReadNode)

        parent = ancestors.last
        return false if parent.is_a?(Prism::ArgumentsNode) && ancestors[-2].is_a?(Prism::ReturnNode)

        !(parent.is_a?(Prism::StatementsNode) && !value_used?(ancestors, ancestors.size - 1, node))
      end

      # Whether the value of `node`, whose parent is `ancestors[index]`, reaches anything. The body's own value (its
      # last statement) is the return position, after which nothing in the body runs, so it reads as unused.
      def value_used?(ancestors, index, node)
        while index >= 0
          parent = ancestors[index]
          case parent
          when Prism::StatementsNode
            return false unless parent.body.last.equal?(node)
          when Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::CaseMatchNode
            return true if parent.predicate.equal?(node)
          when Prism::WhenNode, Prism::InNode
            return true unless parent.statements.equal?(node)
          when Prism::WhileNode, Prism::UntilNode, Prism::EnsureNode
            return !parent.statements.equal?(node)
          when Prism::ElseNode, Prism::BeginNode, Prism::ParenthesesNode, Prism::ProgramNode, Prism::RescueNode
            nil
          else
            return true
          end
          node = parent
          index -= 1
        end
        false
      end
    end
  end
end
