# frozen_string_literal: true

require "prism"

require_relative "../element_read_widening"
require_relative "../mutation_widening"
require_relative "../receiver_alias"
require_relative "../remover_holder_scan"
require_relative "../set_mutation"
require_relative "foreign_locals"

module Rigor
  module Inference
    module AliasMutationFloor
      ALWAYS = -1
      LOOPS = [Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode, Prism::LambdaNode].freeze
      KEEPING_CALLS = (MutationWidening::SHAPE_MUTATORS | SetMutation::MUTATORS |
                       %i[new add add? send public_send __send__ instance_variable_set instance_exec instance_eval
                          class_exec module_exec define_method define_singleton_method]).freeze
      private_constant :ALWAYS, :LOOPS, :KEEPING_CALLS

      module_function

      IMMUTABLE_CLASSES = %w[Integer Float Rational Complex Symbol NilClass TrueClass FalseClass].to_set.freeze
      private_constant :IMMUTABLE_CLASSES

      # Whether `type` is a container that may hold a mutable element, which a write through an element read (`x =
      # a[0]; x << 1`) can change: `[[1]]` and `Array[String]` may, `[1, :a]` may not.
      def mutable_parts?(type)
        case type
        when Type::Tuple then type.elements.any? { |element| mutable_value?(element) }
        when Type::HashShape then type.pairs.values.any? { |value| mutable_value?(value) }
        when Type::Nominal then type.type_args.any? { |arg| mutable_value?(arg) }
        when Type::Difference then mutable_parts?(type.base)
        when Type::Union then type.members.any? { |member| mutable_parts?(member) }
        else true
        end
      end

      def mutable_value?(type)
        case type
        when Type::Constant then type.value.is_a?(String) || type.value.is_a?(::Set)
        when Type::Nominal then !IMMUTABLE_CLASSES.include?(type.class_name)
        when Type::Union then type.members.any? { |member| mutable_value?(member) }
        else true
        end
      end

      # Each local or ivar read `node` may evaluate to: through the branches of an `if` / `unless` / ternary, `case`,
      # `case`/`in`, `begin` (its body, rescue and else clauses), `rescue` modifier and `||` / `&&`, the last statement
      # of a body, and a call that answers its receiver (`a.tap { }`, `a.itself`, `a.freeze`, `a.to_a`); anything else
      # as {ReceiverAlias.candidates} reads it. A nest deeper than {SELECTION_DEPTH} reads as no local.
      def each_may_be(node, depth = 0, &)
        node = RemoverHolderScan.unparenthesised(node)
        return if node.nil? || depth > SELECTION_DEPTH
        return each_may_be(node.receiver, depth + 1, &) if self_returning_call?(node)

        branches = selection_branches(node)
        return ReceiverAlias.candidates(node).each(&) if branches.nil?

        branches.each { |branch| each_may_be(branch, depth + 1, &) }
      end

      SELECTION_DEPTH = 6

      def self_returning_call?(node) = node.is_a?(Prism::CallNode) && SELF_RETURNERS.include?(node.name)

      # The sub-expressions a selection's value is one of, or nil for a node that selects nothing.
      def selection_branches(node)
        case node
        when Prism::StatementsNode then [node.body.last]
        when Prism::ParenthesesNode, Prism::ElseNode then [node.respond_to?(:statements) ? node.statements : node.body]
        when Prism::IfNode then [node.statements, node.subsequent]
        when Prism::UnlessNode then [node.statements, node.else_clause]
        when Prism::OrNode, Prism::AndNode then [node.left, node.right]
        when Prism::CaseNode, Prism::CaseMatchNode
          node.conditions.map(&:statements) << node.else_clause
        when Prism::BeginNode then begin_branches(node)
        when Prism::RescueModifierNode then [node.expression, node.rescue_expression]
        end
      end

      def begin_branches(node)
        branches = [node.statements, node.else_clause]
        clause = node.rescue_clause
        while clause
          branches << clause.statements
          clause = clause.subsequent
        end
        branches
      end

      def local_name(read) = ReceiverAlias.read_name(read)

      # `[base, depth]` for an element read (`a[i]`, `a.first`, `h.fetch(:k)`, `a.dig(:k, 0)`, a chain of them): what
      # it reads from and how many levels inside it, `[node, 0]` for anything else.
      def element_path(node)
        node = RemoverHolderScan.unparenthesised(node)
        depth = 0
        while node.is_a?(Prism::CallNode) && node.receiver && node.block.nil? && ELEMENT_READS.include?(node.name)
          depth += node.name == :dig ? [node.arguments&.arguments&.size.to_i, 1].max : 1
          node = RemoverHolderScan.unparenthesised(node.receiver)
        end
        [node, depth]
      end

      # `[root, depth]` for an element read rooted at a local, or nil.
      def element_root(node)
        root, depth = element_path(node)
        [root, depth] if depth.positive? && root.is_a?(Prism::LocalVariableReadNode)
      end

      # The {RemoverHolderScan} collector, which reads every fact {.scan} needs in that one walk: for each local the
      # least key of the sites that hand it on ({.handed_by}), the ranges of the closures that may run later, and the
      # body's foreign and written locals ({ForeignLocals.visit}).
      class SiteCollector
        # Non-local reads: a local bound to one, or to an element read rooted at one (`a = @rows[0]`), is held by that
        # variable. ({ReceiverAlias.candidates} answers a bare ivar read itself.)
        NON_LOCAL_READS = [Prism::InstanceVariableReadNode, Prism::GlobalVariableReadNode,
                           Prism::ClassVariableReadNode].to_set.freeze
        LOCAL_BINDS = [Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode,
                       Prism::LocalVariableAndWriteNode].to_set.freeze

        attr_writer :site
        attr_reader :held, :held_part, :links, :deferred, :foreign, :written

        def initialize
          @held = {}
          @held_part = {}
          @links = []
          @site = nil
          @outer = nil
          @outer_owner = nil
          @deferred = []
          @foreign = Set.new
          @written = Set.new
          @literal_blocks = Set.new.compare_by_identity
          @def_depth = 0
        end

        # A local handed on whole: a capture by a closure that may run later, a reflective receiver, a zero-argument
        # `super`'s parameter.
        def <<(name)
          note(@held, name)
          self
        end

        # A value position another holder keeps (an element, an argument of a keeping call, an index or attribute
        # write's value): each local the value may be is handed on, and the root of an element read hands on a part.
        def value_held(node)
          AliasMutationFloor.each_may_be(node) do |read|
            note(@held, AliasMutationFloor.local_name(read)) if local?(read)
          end
          root, = AliasMutationFloor.element_root(node)
          note(@held_part, root.name) if root
        end

        # A write: a local bound to a value that may be another local's object links the two (`b = a`), an element read
        # links them as a part (`x = a[i]`), and a local bound to a non-local holder's object is held by that holder
        # (`a = @q`). A non-local write hands the value on as {#value_held} does.
        def value_written(node)
          return if node.is_a?(Prism::LocalVariableOperatorWriteNode)
          return value_held(node.value) unless LOCAL_BINDS.include?(node.class)

          bind(node.name, node.value)
        end

        # A multiple assignment or a pattern: each local target is bound as {#value_written} binds one, to each element
        # of an Array literal value or to the value whole.
        def value_bound(value, target_nodes)
          names = []
          RemoverHolderScan.local_targets(target_nodes, names)
          return if names.empty?

          values = value.is_a?(Prism::ArrayNode) ? value.elements : [value]
          names.each { |name| values.each { |part| bind(name, part) } }
        end

        def enter(node, parent)
          if @outer.nil? && LOOPS.any? { |klass| node.is_a?(klass) }
            @outer = node.location.start_offset
            @outer_owner = node
          end
          note_deferred(node, parent)
          if node.is_a?(Prism::DefNode)
            @def_depth += 1
          elsif @def_depth.zero?
            ForeignLocals.visit(node, @foreign, @written, @literal_blocks)
          end
        end

        def leave(node)
          if node.equal?(@outer_owner)
            @outer = nil
            @outer_owner = nil
          end
          @def_depth -= 1 if node.is_a?(Prism::DefNode)
        end

        # Only a call that may keep its argument hands it to another holder: a constructor, an in-place mutator (a
        # container adder), and a reflective or `define_method` call. Any other call's arguments are passed, not kept.
        def keeps_arguments?(call_node) = KEEPING_CALLS.include?(call_node.name)

        private

        def local?(read) = read.is_a?(Prism::LocalVariableReadNode) || read.is_a?(Prism::ItLocalVariableReadNode)

        def key = @site ? @outer || AliasMutationFloor.handed_by(@site) : ALWAYS

        def note(table, name)
          site_key = key
          current = table[name]
          table[name] = site_key if current.nil? || site_key < current
        end

        def bind(name, value)
          AliasMutationFloor.each_may_be(value) do |read|
            next unless local?(read)

            other = AliasMutationFloor.local_name(read)
            @links << [name, other, key, 0] unless other == name
          end
          note(@held, name) if NON_LOCAL_READS.include?(AliasMutationFloor.element_path(value).first.class)
          root, depth = AliasMutationFloor.element_root(value)
          @links << [name, root.name, key, depth] if root && root.name != name
          link_elements(name, value)
        end

        # A container literal's elements are the local's elements (`c = [inner]`): each local an element may be is
        # linked to it as a part.
        def link_elements(name, value)
          value = RemoverHolderScan.unparenthesised(value)
          elements = value.elements if value.is_a?(Prism::ArrayNode)
          elements = value.elements.grep(Prism::AssocNode).map(&:value) if value.is_a?(Prism::HashNode)
          elements&.each do |element|
            AliasMutationFloor.each_may_be(element) do |read|
              @links << [AliasMutationFloor.local_name(read), name, key, 1] if local?(read)
            end
          end
        end

        def note_deferred(node, parent)
          return unless node.is_a?(Prism::LambdaNode) ||
                        (node.is_a?(Prism::BlockNode) && RemoverHolderScan.deferred_block?(parent))

          start = node.location.start_offset
          @deferred << [start, start + node.location.length]
        end
      end
    end
  end
end
