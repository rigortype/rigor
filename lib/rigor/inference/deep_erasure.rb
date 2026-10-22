# frozen_string_literal: true

module Rigor
  module Inference
    # A loop hands its collection's own elements to its body (issue #2262), so a body that mutates one in place
    # changes a shape that the collection's binding still carries one level down. This module is the two halves of
    # dropping that shape: whether the body mutates an element, and the type with every shape dropped at every depth.
    module DeepErasure
      module_function

      # {MutationWidening.widen_tuple} / {MutationWidening.widen_hash_shape} applied at every depth: each `Tuple` /
      # `HashShape` the type holds, as a union member or a type argument, drops to its nominal, so `[[1]]` reads
      # `Array[Array[Integer]]`. A loop's element is the collection's own object, so a body that mutates it in place
      # (`x << 2`) changes a shape one level down that the collection's binding still carries.
      def widen(type)
        case type
        when Type::Tuple then widen_args(MutationWidening.widen_tuple(type))
        when Type::HashShape then widen_args(MutationWidening.widen_hash_shape(type))
        when Type::Nominal then widen_args(type)
        when Type::Difference then widen(type.base)
        when Type::Union then Type::Combinator.union(*type.members.map { |member| widen(member) })
        else Type::Combinator.widen_value_pinned(type)
        end
      end

      def widen_args(nominal)
        return nominal unless nominal.is_a?(Type::Nominal) && !nominal.type_args.empty?

        Type::Combinator.nominal_of(nominal.class_name, type_args: nominal.type_args.map { |arg| widen(arg) })
      end

      # The parameter nodes whose names a block (or a `for` index) binds to the collection's elements.
      ELEMENT_PARAMETER_NODES = [
        Prism::RequiredParameterNode, Prism::OptionalParameterNode, Prism::RestParameterNode,
        Prism::KeywordRestParameterNode, Prism::LocalVariableTargetNode
      ].freeze
      ELEMENT_WRITE_NODES = [
        Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
        Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
      ].freeze
      private_constant :ELEMENT_PARAMETER_NODES, :ELEMENT_WRITE_NODES

      # True when `body` mutates in place a value that a name in `names` (a loop's element) holds: a mutator
      # (`MutationWidening::SHAPE_MUTATORS`) called on a read or an index chain rooted at it (`x << 1`,
      # `x[0].push(1)`, `x[0] = 1`), or an operator write on one (`x[0] += 1`). The parameters of a block inside the
      # body count too (`x.each { |y| y << 1 }` mutates an element of `x`). It does not follow an alias (`y = x`) or
      # an element passed to a call (`add(x)`), which the straight-line widening does not either.
      def element_mutation?(body, names)
        return false if body.nil?

        names |= nested_parameter_names(body)
        Source::NodeWalker.each(body).any? { |node| element_mutation_site?(node, names) }
      end

      # The names `parameters` (a block's parameter list, or a `for` index) binds.
      def parameter_names(parameters)
        return [] if parameters.nil?

        Source::NodeWalker.each(parameters).filter_map do |node|
          node.name if ELEMENT_PARAMETER_NODES.include?(node.class)
        end
      end

      def nested_parameter_names(body)
        Source::NodeWalker.each(body).flat_map { |node| node.is_a?(Prism::BlockNode) ? parameter_names(node.parameters) : [] }
      end

      def element_mutation_site?(node, names)
        if node.is_a?(Prism::CallNode)
          MutationWidening::SHAPE_MUTATORS.include?(node.name) && element_rooted?(node.receiver, names)
        else
          ELEMENT_WRITE_NODES.include?(node.class) && element_rooted?(node.receiver, names)
        end
      end

      def element_rooted?(node, names)
        node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver
        node = node.body.body.last while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode)
        case node
        when Prism::LocalVariableReadNode then names.include?(node.name) || /\A_[1-9]\z/.match?(node.name)
        when Prism::ItLocalVariableReadNode then true
        else false
        end
      end

      # A block call hands each of its receiver's elements to the block's parameters, and a body that mutates one in
      # place (`a.each { |x| x << 2 }`) changes the shape the receiver's binding still carries one level down
      # (`[[1]]`). The receiver's variables drop their shapes at every depth ({widen}), as a `for` loop's
      # value does ({StatementEvaluator#for_collection_after}).
      def widen_element_aliases(receiver, body, names, scope)
        return scope unless element_mutation?(body, names)

        ReceiverAlias.candidates(receiver).reduce(scope) { |acc, read| widen_read(read, acc) }
      end

      def widen_read(read, scope)
        getter, builder = MutationWidening::ALIAS_ACCESSORS[read.class]
        return scope if getter.nil?

        name = ReceiverAlias.read_name(read)
        current = scope.public_send(getter, name)
        return scope if current.nil?

        widened = widen(current)
        return scope if widened == current

        MutationRejoin.rebind(scope, builder, name, widened, pre_state: current, kind: getter)
      end
    end
  end
end
