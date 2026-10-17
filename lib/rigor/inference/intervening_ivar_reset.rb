# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "reflective_ivar_write"
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
      # Issue #1402 — the nodes that run code the program does not show on `self`'s behalf: `yield` runs the
      # method's block, and `super` the superclass's method on `self`.
      UNKNOWN_CODE_NODES = [Prism::YieldNode, Prism::SuperNode, Prism::ForwardingSuperNode].freeze
      # Issue #1402 — the names of a proc's call (`blk.call`, `blk.()`, `blk.yield`), which runs the block the method
      # was given as `yield` does.
      PROC_CALL_NAMES = Set[:call, :yield].freeze
      # Issue #1402 — the calls whose block runs with `self` bound to the receiver: on a receiver other than `self`,
      # an instance variable the block writes, and a method it calls without a receiver, are that object's.
      SELF_REBINDING_BLOCK_CALLS = Set[
        :instance_eval, :instance_exec, :class_eval, :class_exec, :module_eval, :module_exec, :define_method,
        :define_singleton_method
      ].freeze
      private_constant :NON_RUNNING_NODES, :UNKNOWN_CODE_NODES, :PROC_CALL_NAMES, :SELF_REBINDING_BLOCK_CALLS

      module_function

      # True when `node` is a call that may write `self`'s instance variables: an implicit-self or `self.` call
      # ({.self_call?}). Issue #1402 — and a `yield`, a `super`, or a proc's call on a local ({.proc_call?}), which
      # run code the program does not show; {SelfCallIvarWrites.of} proves no write set for any of them.
      def candidate?(node)
        return true if UNKNOWN_CODE_NODES.any? { |klass| node.is_a?(klass) }
        return false unless node.is_a?(Prism::CallNode)

        self_call?(node) || proc_call?(node)
      end

      # Whether `node`, a call, has no receiver or `self` as its receiver.
      def self_call?(node)
        receiver = node.receiver
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      # Issue #1402 — `blk.call` / `blk.()` / `blk.yield` on a local: the method's own `&blk`, or a proc it was
      # handed, runs code that may call back into `self`, as `yield` does. Read by name, since an unannotated
      # `&blk` binds `Dynamic`.
      def proc_call?(node)
        PROC_CALL_NAMES.include?(node.name) && node.receiver.is_a?(Prism::LocalVariableReadNode)
      end

      # Issue #1402 — whether `call_node`'s block runs on another object: a {SELF_REBINDING_BLOCK_CALLS} call on an
      # explicit receiver other than `self`.
      def foreign_self_block?(call_node)
        return false unless call_node.is_a?(Prism::CallNode) && SELF_REBINDING_BLOCK_CALLS.include?(call_node.name)

        !self_call?(call_node)
      end

      # Issue #1402 — `scope` past a call on another receiver whose literal block may make a {.candidate?} call
      # (`[1].each { reset }`, `items.each { yield }`): {.widen} over the names those calls may write, as
      # {.after_operand} widens past the calls in a condition. A block that runs on another object
      # ({.foreign_self_block?}) calls that object's methods and widens nothing. A literal-name
      # `instance_variable_set` on `self` ({ReflectiveIvarWrite.literal_name}) writes the one ivar it names, which
      # the block's captured-binding write-back already joins, so it is not counted.
      def after_block(call_node, scope)
        block = call_node.block
        return scope unless block.is_a?(Prism::BlockNode) && !foreign_self_block?(call_node)
        return scope unless narrowed_ivars?(scope)

        calls = candidate_calls(block, false).reject { |call| ReflectiveIvarWrite.literal_name(call) }
        return scope if calls.empty?

        widen(scope, mark: true) { proven_writes(calls, scope) }
      end

      # `scope` with each instance variable narrowed below its class-ivar seed widened back over the seed. The block
      # answers the names the call may write, or nil for any; it runs at most once, and only when an instance
      # variable is narrowed, since a proof costs a read of the callee. An instance variable whose binding carries
      # the declaration mark keeps it (issue #1889). With `mark: true` a binding whose narrowing had ruled `nil` out
      # takes the mark when widened, so a `nil` only the seed brings back is not fuel for
      # `call.possible-nil-receiver` (ADR-58), as a declared one is not. A narrowing that kept `nil`
      # (`return if @tag`, `@tag.nil?`) widens unmarked, so a read the program really makes on `nil` still reports.
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
          marked = (mark && nil_free?(local_type)) || scope.declaration_sourced?(:ivar, name)
          marked ? widened.seed_declaration_sourced_ivar(name, joined) : widened
        end
      end

      # Issue #1963 — `scope` past the calls `node`, a condition operand, makes: {.widen} over the names every
      # candidate call in it may write, or every name when one of them is not proven. A call's literal block may run,
      # so its calls count; a `def`, a class or module body and (unless `run_lambdas`) a lambda literal run nothing
      # on this `self` there.
      #
      # A binding whose narrowing ruled `nil` out takes the declaration mark when widened ({.widen}'s `mark:`): the
      # reset forgets the narrowing without making the variable newly nil-reportable, since a call the proof cannot
      # clear is far more often one that leaves the variable alone (`if @tag && items.any?` then `t = @tag;
      # t.upcase`) than one that assigns `nil`. A `when` test passes `run_lambdas: true`, since its `===` runs a
      # lambda literal's body.
      def after_operand(node, scope, run_lambdas: false)
        return scope unless narrowed_ivars?(scope)

        calls = candidate_calls(node, run_lambdas)
        return scope if calls.empty?

        widen(scope, mark: true) { proven_writes(calls, scope) }
      end

      # Whether a candidate call in `node` may write the instance variable `name`. A `when` test passes
      # `run_lambdas: true`, since its `===` runs a lambda literal's body. A write to it in `node` is the caller's
      # to check.
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
        node.compact_child_nodes.each do |child|
          next if child.is_a?(Prism::BlockNode) && foreign_self_block?(node)

          collect_calls(child, run_lambdas, found)
        end
      end
      private_class_method :collect_calls

      def nil_free?(type)
        Narrowing.narrow_non_nil(type) == type
      end
      private_class_method :nil_free?

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
