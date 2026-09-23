# frozen_string_literal: true

require "prism"

require_relative "../source/node_walker"
require_relative "captured_locals"

module Rigor
  module Inference
    # The names of a {CapturedLocals.writes} set that a block body rebinds somewhere `StatementEvaluator` does
    # not carry into the body's exit scope.
    #
    # The per-element fold's issue #587 (b) fixpoint reads each pass's exit binding out of that evaluator, so a
    # rebind the exit never sees leaves the fixpoint on a binding the program has already moved past, and every
    # position of the fold re-reads it. Issue #617's unmoved-pin floor caught such a name only while nothing else
    # moved its binding: `seen = nil; [1, 2].find { |e| seen ||= 0; (seen += 1) == 2 }` threads the `||=`, so the
    # fixpoint left the seed, and every predicate read `0 + 1 == 2`. A name this scan returns takes the floor
    # whatever the fixpoint converged to.
    #
    # The evaluator threads a write from these positions only, measured against it rather than read off it:
    #
    # - a statement, and the body of `(…)`, `begin` / `rescue` / `else` / `ensure`;
    # - an assignment's value — every variable-write form, and an index `||=` / `&&=` / `op=`, but not its
    #   receiver or index arguments;
    # - an `if` / `unless` / `case` predicate and every branch, but not a `when` condition or an `in` guard;
    # - both operands of `&&` / `||`;
    # - a `while` / `until` predicate and body, a `for` index, collection and body;
    # - a multi-assign value and its local and instance-variable targets, and the LOCAL a `rescue => e`
    #   reference, a `for` index, a pattern capture or `=~`'s named captures binds — the evaluator binds no
    #   class variable or global through any of them, and no instance variable outside a multi-assign;
    # - a nested block or lambda body, for a local only: the call's write-back fixpoint or escaping-block floor
    #   covers captured locals, and nothing covers an instance variable, class variable or global there.
    #
    # Every other position is unthreaded: a call's receiver and arguments, an array or hash literal, an
    # interpolation, a `return` / `next` / `break` value, `rescue` modifier, `self.w =` (which rebinds `@w` with
    # no write node at all), a `def` or class body. The list is a whitelist, so a position the evaluator gains
    # later floors a name needlessly rather than letting a pin through.
    #
    # A threaded rebind can still miss the exit binding when a jump leaves after it. The evaluator's exit scope
    # is the fall-through path's, and a branch that ends in `next` is dropped from it — the rebind the branch made
    # and the narrowing its guard applied both. So is a nested block's `next` / `break` from its own write-back,
    # and a loop's `next` or `break` from the loop's own join. A rebind that textually precedes such a jump is therefore
    # unthreaded too; the block body runs forward-only, so a rebind after every jump cannot be on a jump's path,
    # and a jump that is its construct's final statement leaves with the exit scope itself. A rebind in an
    # `ensure` runs after any jump in its `begin`, so under any jump it counts as preceding one. `redo` and
    # `retry` re-enter code with the bindings they carry, and count as jumps.
    module UnthreadedRebinds
      VARIABLE_WRITE_NODES = (CapturedLocals::LOCAL_WRITE_NODES | CapturedLocals::NON_LOCAL_WRITE_NODES).freeze
      private_constant :VARIABLE_WRITE_NODES

      TARGET_NODES = Set[
        Prism::LocalVariableTargetNode, Prism::InstanceVariableTargetNode,
        Prism::ClassVariableTargetNode, Prism::GlobalVariableTargetNode
      ].freeze
      private_constant :TARGET_NODES

      VALUE_ONLY = { value: :code }.freeze
      private_constant :VALUE_ONLY

      # Parent class => the child fields the evaluator threads, each with how it is entered: `:code` threads
      # writes, `:binding` threads only the targets the construct binds ({#binding_target_threaded?}),
      # `:ensure` is an `ensure` body, `:loop` a loop body, `:nested` a call's block and `:lambda` a lambda's
      # body.
      THREADED_FIELDS = {
        Prism::StatementsNode => { body: :code },
        Prism::ParenthesesNode => { body: :code },
        Prism::BeginNode => { statements: :code, rescue_clause: :code, else_clause: :code, ensure_clause: :code },
        Prism::RescueNode => { reference: :binding, statements: :code, subsequent: :code },
        Prism::EnsureNode => { statements: :ensure },
        Prism::ElseNode => { statements: :code },
        Prism::IfNode => { predicate: :code, statements: :code, subsequent: :code },
        Prism::UnlessNode => { predicate: :code, statements: :code, else_clause: :code },
        Prism::CaseNode => { predicate: :code, conditions: :code, else_clause: :code },
        Prism::WhenNode => { statements: :code },
        Prism::CaseMatchNode => { predicate: :code, conditions: :code, else_clause: :code },
        Prism::InNode => { pattern: :binding, statements: :code },
        Prism::AndNode => { left: :code, right: :code },
        Prism::OrNode => { left: :code, right: :code },
        Prism::MatchPredicateNode => { value: :code, pattern: :binding },
        Prism::MatchRequiredNode => { value: :code, pattern: :binding },
        Prism::MatchWriteNode => { targets: :binding },
        Prism::MultiWriteNode => { lefts: :binding, rest: :binding, rights: :binding, value: :code },
        Prism::WhileNode => { predicate: :code, statements: :loop },
        Prism::UntilNode => { predicate: :code, statements: :loop },
        Prism::ForNode => { index: :binding, collection: :code, statements: :loop },
        Prism::CallNode => { block: :nested },
        Prism::BlockNode => { body: :code },
        Prism::LambdaNode => { body: :lambda },
        Prism::IndexOrWriteNode => VALUE_ONLY,
        Prism::IndexAndWriteNode => VALUE_ONLY,
        Prism::IndexOperatorWriteNode => VALUE_ONLY,
        **(VARIABLE_WRITE_NODES - TARGET_NODES).to_h { |klass| [klass, VALUE_ONLY] }
      }.transform_values(&:freeze).freeze
      private_constant :THREADED_FIELDS

      # The jumps that leave, or re-enter, an iteration of the construct they belong to. A `break` leaves the
      # fold's call outright, so no later iteration reads what it carried; a nested block's or loop's `break`
      # returns to this body, which then reads it. A `while` / `until` loop's continuation does not join the
      # scope its `break` left with, so a loop's `break` counts as a nested block's does.
      FOLD_JUMPS = Set[Prism::NextNode, Prism::RedoNode, Prism::RetryNode].freeze
      NESTED_JUMPS = (FOLD_JUMPS | [Prism::BreakNode]).freeze
      private_constant :FOLD_JUMPS, :NESTED_JUMPS

      # The constructs that own the jumps inside them.
      JUMP_BOUNDARY_NODES = Set[
        Prism::BlockNode, Prism::LambdaNode, Prism::DefNode,
        Prism::WhileNode, Prism::UntilNode, Prism::ForNode
      ].freeze
      private_constant :JUMP_BOUNDARY_NODES

      NO_JUMP = -1
      private_constant :NO_JUMP

      EMPTY = Set.new.freeze
      private_constant :EMPTY

      # How a walk position reaches the exit scope: whether a local rebind there is threaded, whether an
      # instance variable, class variable or global rebind is, the offset below which a rebind precedes a jump,
      # whether the position binds targets only (`:multi_assign` under a multi-assign, `:capture` under any
      # other binding construct, false otherwise), and the locals a nested block shadows.
      Position = Data.define(:local, :non_local, :horizon, :binding, :shadowed)
      private_constant :Position

      module_function

      # @param names — the rebound names from {CapturedLocals.writes}, sigil and all.
      # @return the subset of `names` the body rebinds somewhere the exit scope misses.
      def names(block_node, names)
        body = block_node.body
        return EMPTY if body.nil? || names.empty?

        wanted = names.to_set
        found = Set.new
        horizon = last_jump_offset(body, FOLD_JUMPS)
        visit(body, Position.new(local: true, non_local: true, horizon: horizon, binding: false, shadowed: EMPTY),
              wanted, found)
        found
      end

      def visit(node, position, wanted, found)
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::DefinedNode)

        check(node, position, wanted, found)
        return node.rigor_each_child { |child| visit(child, position, wanted, found) } if position.binding

        fields = THREADED_FIELDS[node.class]
        return node.rigor_each_child { |child| visit_unthreaded(child, wanted, found) } if fields.nil?

        threaded = threaded_children(node, fields)
        node.rigor_each_child do |child|
          mode = threaded[child]
          if mode
            visit(child, enter(node, child, mode, position), wanted, found)
          else
            visit_unthreaded(child, wanted, found)
          end
        end
      end

      def threaded_children(node, fields)
        threaded = {}.compare_by_identity
        fields.each do |field, mode|
          value = node.public_send(field)
          if value.is_a?(Array)
            value.each { |child| threaded[child] = mode }
          elsif value
            threaded[value] = mode
          end
        end
        threaded
      end

      # Every rebind under an unthreaded position misses the exit scope, whatever the position beneath it.
      def visit_unthreaded(node, wanted, found)
        Source::NodeWalker.each(node) do |descendant|
          name = rebound_name(descendant)
          found << name if name && wanted.include?(name)
        end
      end

      def enter(parent, child, mode, position)
        case mode
        when :binding then position.with(binding: parent.is_a?(Prism::MultiWriteNode) ? :multi_assign : :capture)
        when :ensure then position.with(horizon: position.horizon == NO_JUMP ? NO_JUMP : Float::INFINITY)
        when :loop then extend_horizon(position, child, NESTED_JUMPS)
        when :nested then nested_block(child, position)
        when :lambda then nested_body(parent, child, position)
        else position
        end
      end

      def extend_horizon(position, body, kinds)
        position.with(horizon: [position.horizon, last_jump_offset(body, kinds)].max)
      end

      # A call's block. A block-pass argument (`&blk`) carries no body the call's write-back reads.
      def nested_block(child, position)
        return position.with(local: false, non_local: false) unless child.is_a?(Prism::BlockNode)

        nested_body(child, child.body, position)
      end

      # A block or lambda body: its parameters and block-locals shadow, its own jumps join the horizon, and only a
      # local's rebind is still carried out.
      def nested_body(owner, body, position)
        extend_horizon(position, body, NESTED_JUMPS).with(
          non_local: false, shadowed: position.shadowed | CapturedLocals.introduced_locals(owner)
        )
      end

      def check(node, position, wanted, found)
        name = rebound_name(node)
        return if name.nil? || !wanted.include?(name)
        return if position.shadowed.include?(name)

        found << name unless threaded_rebind?(node, name, position)
      end

      def threaded_rebind?(node, name, position)
        return false unless VARIABLE_WRITE_NODES.include?(node.class)
        return false unless TARGET_NODES.include?(node.class) == (position.binding ? true : false)

        kind = CapturedLocals.variable_kind(name)
        return false if position.binding && !binding_target_threaded?(kind, position.binding)
        return false unless kind == :local ? position.local : position.non_local

        node.location.start_offset >= position.horizon
      end

      # A binding construct's target reaches the exit scope only for the kinds the evaluator binds there: a
      # multi-assign binds locals and instance variables, and a `rescue =>` reference, a `for` index, a pattern
      # capture or a named capture binds locals only. `a, $g = 1, :z` leaves `$g` where it was.
      def binding_target_threaded?(kind, binding)
        kind == :local || (kind == :ivar && binding == :multi_assign)
      end

      def rebound_name(node)
        return node.name if VARIABLE_WRITE_NODES.include?(node.class)

        CapturedLocals.setter_ivar_name(node)
      end

      # The start offset of the last `kinds` jump that belongs to the construct whose body is `body`, or
      # {NO_JUMP}. A jump that is the body's final statement is skipped: it leaves with the exit scope itself.
      def last_jump_offset(body, kinds)
        return NO_JUMP if body.nil?

        final = body.body.last if body.is_a?(Prism::StatementsNode)
        offset = NO_JUMP
        each_owned_jump(body, kinds) do |jump|
          offset = [offset, jump.location.start_offset].max unless jump.equal?(final)
        end
        offset
      end

      def each_owned_jump(node, kinds, &)
        yield node if kinds.include?(node.class)
        return if node.is_a?(Prism::DefinedNode)

        node.rigor_each_child do |child|
          each_owned_jump(child, kinds, &) unless JUMP_BOUNDARY_NODES.include?(child.class)
        end
      end
    end
  end
end
