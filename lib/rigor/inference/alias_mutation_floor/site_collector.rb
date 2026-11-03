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

      # Each local or ivar read `node` may evaluate to ({ReceiverAlias.candidates}), seeing through a call that
      # answers its receiver (`a.tap { }`, `a.itself`, `a.freeze`, `a.to_a`).
      def each_may_be(node, &)
        node = RemoverHolderScan.unparenthesised(node)
        return if node.nil?
        return each_may_be(node.receiver, &) if node.is_a?(Prism::CallNode) && SELF_RETURNERS.include?(node.name)

        ReceiverAlias.candidates(node).each(&)
      end

      def local_name(read) = ReceiverAlias.read_name(read)

      # The local an element read is rooted at (`a[i]`, `a.first`, `a.dig(:k, 0)`), or nil.
      def element_root(node)
        root = ElementReadWidening.element_read_path(RemoverHolderScan.unparenthesised(node))&.first
        root if root.is_a?(Prism::LocalVariableReadNode)
      end

      # The {RemoverHolderScan} collector, which reads every fact {.scan} needs in that one walk: for each local the
      # least key of the sites that hand it on ({.handed_by}), the ranges of the closures that may run later, and the
      # body's foreign and written locals ({ForeignLocals.visit}).
      class SiteCollector
        # Reads {ReceiverAlias.candidates} leaves out: a local bound to one is held by that variable all the same.
        NON_LOCAL_READS = [Prism::GlobalVariableReadNode, Prism::ClassVariableReadNode].to_set.freeze
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
          root = AliasMutationFloor.element_root(node)
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
            if local?(read)
              other = AliasMutationFloor.local_name(read)
              @links << [name, other, key, false] unless other == name
            else
              note(@held, name)
            end
          end
          note(@held, name) if NON_LOCAL_READS.include?(RemoverHolderScan.unparenthesised(value).class)
          root = AliasMutationFloor.element_root(value)
          @links << [name, root.name, key, true] if root && root.name != name
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
