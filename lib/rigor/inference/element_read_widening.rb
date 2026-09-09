# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "mutation_widening"

module Rigor
  module Inference
    # Widens the element a mutator call reaches THROUGH a read, when the container is a local's
    # literal-shape carrier. {MutationWidening} widens the bindings a receiver expression NAMES;
    # this module covers the case where it names none because the receiver is an rvalue temp.
    module ElementReadWidening
      # Element reads that name ONE element of a container: the only receiver shapes whose mutation
      # is attributable to a single position inside a local's literal-shape carrier. `first` / `last`
      # with an argument return a sub-ARRAY, not an element, so they are excluded by arity below.
      ELEMENT_READERS = %i[[] first last dig].to_set.freeze

      module_function

      # Widens an element read through an index / `first` / `last` / `dig` chain rooted at a LOCAL,
      # when that read is the RECEIVER of a content mutator (issue #643).
      #
      # `c = [flag ? [1] : [2]]; c[0] << 5` mutates the rvalue temp `c[0]`, so
      # {MutationWidening.widen_after_call} — which widens exactly the bindings the receiver expression NAMES —
      # sees no variable and records nothing. `c` keeps `Tuple[[1] | [2]]`, and the later
      # `c[0].last == 5` folds always-falsey on a value the program does hold. The nested plain
      # literal (`b = [[[]]]; b[0][0] << 1`) reads `b[0][0].first` as `nil` for the same reason.
      #
      # The fix widens the element's pin ONE STEP INSIDE the container and writes the rebuilt
      # container back to the local: `Tuple[[1] | [2]]` becomes `Tuple[Array[Integer]]`. The outer
      # arity survives — mutating an element cannot change how many elements the container has —
      # so `c.size == 1` keeps folding. A non-literal index widens every position instead, since
      # which one was mutated is not decidable.
      #
      # Rooted at a local only: a mutation through a method call's result (`foo[0] << 5`) has no
      # binding to write back to, and inventing one would be unsound.
      def widen_element_read(call_node:, current_scope:, arg_types: MutationWidening::NO_ARG_TYPES)
        return current_scope if MutationWidening.pure_self_returner?(call_node.name)

        path = element_read_path(call_node.receiver)
        return current_scope if path.nil?

        read, steps = path
        widened = widen_through_path(current_scope.local(read.name), steps, call_node.name, arg_types)
        return current_scope if widened.nil?

        current_scope.with_local(read.name, widened)
      end

      # True when `receiver` is an element read whose target element is a literal-shape carrier —
      # the {#joinable_receiver?} counterpart for the element path, gating whether the caller types
      # the mutator's arguments at all.
      def joinable_element_read?(receiver, scope)
        path = element_read_path(receiver)
        return false if path.nil?

        read, steps = path
        !element_at_path(scope.local(read.name), steps).nil?
      end

      # `[<local read>, [step, …]]` for a chain of element reads rooted at a local variable, or
      # `nil` when the expression is anything else. A step is an Integer position (negative counts
      # from the end, as Ruby's own indexing does) or `:all` when the index is not a literal.
      def element_read_path(node)
        steps = []
        cursor = node
        while cursor.is_a?(Prism::CallNode)
          step = element_read_step(cursor)
          return nil if step.nil?

          steps.unshift(*step)
          cursor = cursor.receiver
        end
        return nil unless cursor.is_a?(Prism::LocalVariableReadNode) && !steps.empty?

        [cursor, steps]
      end

      # The positions one element-read call selects, or `nil` when the call is not an element read.
      # A block makes the call something other than a plain read (`arr.first { … }` is not one), and
      # `[]` with anything but a single argument is a slice.
      def element_read_step(call_node)
        return nil unless ELEMENT_READERS.include?(call_node.name)
        return nil if call_node.receiver.nil? || call_node.block

        positional_steps(call_node.name, call_node.arguments&.arguments || [])
      end

      def positional_steps(name, args)
        case name
        when :[] then args.size == 1 ? [index_step(args.first)] : nil
        when :first then args.empty? ? [0] : nil
        when :last then args.empty? ? [-1] : nil
        when :dig then args.empty? ? nil : args.map { |arg| index_step(arg) }
        end
      end

      # `:all` stands for "some position, not statically known" — every position is widened, which
      # is the only answer that cannot under-approximate.
      def index_step(node)
        node.is_a?(Prism::IntegerNode) ? node.value : :all
      end

      # The type at `steps` inside `type`, or `nil` when the path does not resolve to a widenable
      # literal-shape carrier.
      def element_at_path(type, steps)
        return MutationWidening.shape_carrier?(type) ? type : nil if steps.empty?

        case type
        when Type::Tuple
          tuple_positions(type, steps.first).lazy
                                            .filter_map { |i| element_at_path(type.elements[i], steps.drop(1)) }
                                            .first
        when Type::Union
          type.members.lazy.filter_map { |member| element_at_path(member, steps) }.first
        end
      end

      # Rebuilds `type` with the element at `steps` widened against `method_name`, or `nil` when
      # nothing along the path widened.
      def widen_through_path(type, steps, method_name, arg_types)
        return MutationWidening.widen_for_mutator(type, method_name, arg_types: arg_types) if steps.empty?

        case type
        when Type::Tuple then widen_tuple_path(type, steps, method_name, arg_types)
        when Type::Union then widen_union_path(type, steps, method_name, arg_types)
        end
      end

      def widen_tuple_path(tuple, steps, method_name, arg_types)
        elements = tuple.elements.dup
        rest = steps.drop(1)
        widened_any = false
        tuple_positions(tuple, steps.first).each do |position|
          inner = widen_through_path(elements[position], rest, method_name, arg_types)
          next if inner.nil?

          elements[position] = inner
          widened_any = true
        end
        widened_any ? Type::Tuple.new(elements) : nil
      end

      def widen_union_path(union, steps, method_name, arg_types)
        widened_any = false
        members = union.members.map do |member|
          widened = widen_through_path(member, steps, method_name, arg_types)
          next member if widened.nil?

          widened_any = true
          widened
        end
        widened_any ? Type::Combinator.union(*members) : nil
      end

      # An out-of-range literal index selects nothing: the mutation cannot be attributed to any
      # position of THIS tuple, so no widening is justified.
      def tuple_positions(tuple, step)
        size = tuple.elements.size
        return (0...size).to_a if step == :all

        position = step.negative? ? step + size : step
        position.between?(0, size - 1) ? [position] : []
      end
    end
  end
end
