# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "captured_locals"
require_relative "jump_targets"

module Rigor
  module Inference
    # Whether an expression `StatementEvaluator` would otherwise type as a pure value — a call's receiver or
    # argument, a literal, an interpolation, a `rescue` modifier — holds something the scope after it must see:
    # a variable write whose binding outlives the expression, or a `next` / `break` whose path a jump join
    # reads. Issue #1223: `out << (n += 1)` left `n` on its pre-write binding, straight-line and through
    # ADR-56's block write-back, and `puts(x && next)` never reached the block's `next` join.
    #
    # A local write counts only when it binds past every block and lambda it is nested in within the
    # expression (its `depth` reaches the expression's own scope): `puts(xs.map { |x| y = x })` binds `y` in
    # the block alone, while `puts(xs.each { t = 1 })` rebinds the outer `t`. Every instance-variable,
    # class-variable and global write counts wherever it is, and so does an index `||=` / `&&=` / `op=`,
    # whose store widens its receiver. A jump counts only where it targets the construct around the
    # expression ({JumpTargets}). A `def`, class or module body is a scope of its own, and `defined?`
    # evaluates nothing, so neither is looked into.
    #
    # Allocation-free and short-circuiting: the evaluator asks it of every call's operands, and asks it
    # again of each operand it threads. A found effect stops the recursion without a `return` out of the
    # child block, which would allocate once per frame it unwinds and make a deep literal quadratic.
    module OperandEffects
      LOCAL_WRITE_NODES = CapturedLocals::LOCAL_WRITE_NODES
      OUTLIVING_WRITE_NODES = (
        CapturedLocals::NON_LOCAL_WRITE_NODES |
        Set[Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode]
      ).freeze
      INSTANCE_WRITE_NODES = Set[
        Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableTargetNode
      ].freeze
      GLOBAL_WRITE_NODES = Set[
        Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode,
        Prism::GlobalVariableAndWriteNode, Prism::GlobalVariableTargetNode
      ].freeze
      COMPOUND_LOCAL_WRITES = Set[
        Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
      ].freeze
      COMPOUND_INSTANCE_WRITES = Set[
        Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode
      ].freeze
      JUMP_NODES = Set[Prism::NextNode, Prism::BreakNode].freeze
      SCOPE_NODES = Set[Prism::BlockNode, Prism::LambdaNode].freeze
      OPAQUE_NODES = Set[
        Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::DefinedNode
      ].freeze
      private_constant :LOCAL_WRITE_NODES, :OUTLIVING_WRITE_NODES, :INSTANCE_WRITE_NODES, :GLOBAL_WRITE_NODES,
                       :COMPOUND_LOCAL_WRITES,
                       :COMPOUND_INSTANCE_WRITES, :JUMP_NODES, :SCOPE_NODES, :OPAQUE_NODES

      module_function

      def any?(node)
        node.is_a?(Prism::Node) && effect?(node, 0, true)
      end

      # `nesting` counts the blocks and lambdas between `node` and the expression's root; `jumps` is false once
      # the walk has crossed a construct that retargets a jump.
      def effect?(node, nesting, jumps)
        klass = node.class
        return true if LOCAL_WRITE_NODES.include?(klass) && node.depth >= nesting
        return true if OUTLIVING_WRITE_NODES.include?(klass)
        return true if jumps && JUMP_NODES.include?(klass)
        return false if OPAQUE_NODES.include?(klass)

        nesting += 1 if SCOPE_NODES.include?(klass)
        jumps &&= !JumpTargets.boundary?(node)
        found = false
        node.rigor_each_child { |child| found ||= effect?(child, nesting, jumps) }
        found
      end
      private_class_method :effect?

      # The locals (bare names), instance variables and globals (sigil-prefixed names, as {CapturedLocals.bind}
      # reads them) `node` writes on the terms {.any?} counts a write, in first-write order.
      def written_variables(node)
        names = []
        collect_written(node, 0, names) if node.is_a?(Prism::Node)
        names.uniq
      end

      # The locals and instance variables `node` reads, named as {.written_variables} names them. A compound write
      # (`x += 1`, `x ||= v`) reads the variable it writes.
      def read_variables(node)
        names = []
        collect_read(node, 0, names) if node.is_a?(Prism::Node)
        names.uniq
      end

      def collect_read(node, nesting, names)
        klass = node.class
        if klass == Prism::LocalVariableReadNode || COMPOUND_LOCAL_WRITES.include?(klass)
          names << node.name if node.depth >= nesting
        elsif klass == Prism::InstanceVariableReadNode || COMPOUND_INSTANCE_WRITES.include?(klass)
          names << node.name
        end
        return if OPAQUE_NODES.include?(klass)

        nesting += 1 if SCOPE_NODES.include?(klass)
        node.rigor_each_child { |child| collect_read(child, nesting, names) }
      end
      private_class_method :collect_read

      def collect_written(node, nesting, names)
        klass = node.class
        if LOCAL_WRITE_NODES.include?(klass)
          names << node.name if node.depth >= nesting
        elsif INSTANCE_WRITE_NODES.include?(klass) || GLOBAL_WRITE_NODES.include?(klass)
          names << node.name
        end
        return if OPAQUE_NODES.include?(klass)

        nesting += 1 if SCOPE_NODES.include?(klass)
        node.rigor_each_child { |child| collect_written(child, nesting, names) }
      end
      private_class_method :collect_written
    end
  end
end
