# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "self_call_ivar_writes"

module Rigor
  module Inference
    # The intervening-call reset of instance variables. An implicit-self or `self.` call may write any instance
    # variable of `self`, so past one each instance variable whose binding is narrower than its class-ivar seed reads
    # the union of the two again; a call proven to write only some ({SelfCallIvarWrites.of}, issue #1596) widens only
    # those. A call on another receiver cannot reach `self`'s instance variables and widens nothing.
    #
    # {.widen} is the reset itself, which the statement evaluator applies past a statement call
    # (`StatementEvaluator#invalidate_ivars_for_intervening_call`). Issue #1963 — {.after_operand} applies it past
    # the calls in a condition operand, where a narrowing an earlier operand or clause made would otherwise survive
    # them: `if @x.nil? && reset!` read `@x` as `nil` in the body although `reset!` assigns it.
    module InterveningIvarReset
      # Nodes whose body does not run where it is written, or runs on another `self`: a `def`, and a class or
      # module body, where `@x` is the class's own instance variable.
      NON_RUNNING_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      private_constant :NON_RUNNING_NODES

      module_function

      # True when `node` is a call that may write `self`'s instance variables: an implicit-self or `self.` call.
      def candidate?(node)
        return false unless node.is_a?(Prism::CallNode)

        receiver = node.receiver
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      # `scope` with each instance variable narrowed below its class-ivar seed widened back over the seed. The block
      # answers the names the call may write, or nil for any; it runs at most once, and only when an instance
      # variable is narrowed, since a proof costs a read of the callee. An instance variable whose binding carries
      # the declaration mark keeps it (issue #1889). With `mark: true` every widened binding takes the mark, so a
      # `nil` the seed brings back is not fuel for `call.possible-nil-receiver` (ADR-58), as a declared one is not.
      def widen(scope, mark: false)
        seed = class_ivar_seed(scope)
        return scope if seed.nil? || seed.empty?

        computed = false
        writes = nil
        seed.reduce(scope) do |widened, (name, seed_type)|
          local_type = scope.ivar(name)
          next widened if local_type.nil? || local_type == seed_type

          unless computed
            writes = yield
            computed = true
          end
          next widened if writes && !writes.include?(name)

          joined = Type::Combinator.union(local_type, seed_type)
          widened = widened.with_ivar(name, joined)
          marked = mark || scope.declaration_sourced?(:ivar, name)
          marked ? widened.seed_declaration_sourced_ivar(name, joined) : widened
        end
      end

      # Issue #1963 — `scope` past the calls `node`, a condition operand, makes: {.widen} over the names every
      # candidate call in it may write, or every name when one of them is not proven. A call's literal block may run,
      # so its calls count; a `def`, a class or module body and (unless `run_lambdas`) a lambda literal run nothing
      # on this `self` there. A `when` test calls its value's `===`, which for a lambda literal runs the body, so
      # that caller passes `run_lambdas: true`. A write in a lambda body is not this reset's: the caller reads it.
      #
      # The widened bindings take the declaration mark ({.widen}'s `mark:`): the reset forgets the narrowing without
      # making the variable newly nil-reportable, since a call the proof cannot clear is far more often one that
      # leaves the variable alone (`if @tag && items.any?` then `t = @tag; t.upcase`) than one that assigns `nil`.
      def after_operand(node, scope, run_lambdas: false)
        return scope unless narrowed_ivars?(scope)

        calls = candidate_calls(node, run_lambdas)
        return scope if calls.empty?

        widen(scope, mark: true) { proven_writes(calls, scope) }
      end

      # Whether a candidate call in `node` (with `run_lambdas`, one in a lambda body too) may write the instance
      # variable `name`. A write to it in `node` is the caller's to check.
      def may_write?(node, name, scope, run_lambdas: false)
        calls = candidate_calls(node, run_lambdas)
        return false if calls.empty?

        proven = proven_writes(calls, scope)
        proven.nil? || proven.include?(name)
      end

      # The union of the names each call may write ({SelfCallIvarWrites.of}), or nil when one is not proven.
      def proven_writes(calls, scope)
        calls.reduce(Set.new) do |acc, call|
          writes = SelfCallIvarWrites.of(call, scope)
          break nil if writes.nil?

          acc.merge(writes)
        end
      end

      # The candidate calls under `node`, in source order.
      def candidate_calls(node, run_lambdas)
        found = []
        collect_calls(node, run_lambdas, found)
        found
      end

      def collect_calls(node, run_lambdas, found)
        return unless node.is_a?(Prism::Node)
        return if NON_RUNNING_NODES.any? { |klass| node.is_a?(klass) }
        return if !run_lambdas && node.is_a?(Prism::LambdaNode)

        found << node if candidate?(node)
        node.compact_child_nodes.each { |child| collect_calls(child, run_lambdas, found) }
      end
      private_class_method :collect_calls

      # Whether any instance variable is bound narrower than its class-ivar seed: the only state {.widen} changes.
      def narrowed_ivars?(scope)
        seed = class_ivar_seed(scope)
        return false if seed.nil? || seed.empty?

        seed.any? do |name, seed_type|
          local_type = scope.ivar(name)
          !local_type.nil? && local_type != seed_type
        end
      end
      private_class_method :narrowed_ivars?

      def class_ivar_seed(scope)
        self_type = scope.self_type
        class_name =
          case self_type
          when Type::Nominal, Type::Singleton then self_type.class_name
          end
        class_name && scope.class_ivars_for(class_name)
      end
      private_class_method :class_ivar_seed
    end
  end
end
