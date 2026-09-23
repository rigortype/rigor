# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # `Hash#transform_keys(mapping)` return type, with or without a block.
      #
      # CRuby's `transform_keys_hash_i` looks each old key up in the mapping with `rb_hash_lookup2`, which
      # ignores a default. A hit takes the mapping's value as the new key and never reaches the block. A miss
      # yields the old key to the block, or keeps it when no block is given. The new key type is therefore the
      # mapping's value type joined with the block's return type, or with the receiver's key type when there is
      # no block. The values are the receiver's, untouched.
      #
      # Neither RBS line says that. rbs 4.2 declares `[K2] (hash[_Key, K2] replacements) { (K old_key) -> K2 }
      # -> Hash[K2, V]`, and {RbsDispatch} binds `K2` from the block return alone: it binds an argument position
      # only when the parameter is a bare type variable, so the mapping's values drop out of the key. The
      # blockless `[K2] (hash[_Key, K2]) -> Hash[K | K2, V]` leaves `K2` unbound. rbs 3.10 declares no mapping
      # overload at all and answers an `Enumerator`. This tier answers ahead of both, so the forms it accepts
      # get one answer on either RBS line.
      #
      # A mapping the analysis cannot read contributes a `Dynamic[top]` key arm instead of nothing. That covers an
      # untyped argument, a `to_hash`-convertible object, a Hash subclass, the unlisted entries of an open shape,
      # a literal with a `**splat` entry written as the call's argument (the literal's own type leaves the splat
      # out), and an empty closed shape, which is what a mapping filled through an alias the engine does not track
      # still reads as. A block the call carries but the block pass could not type contributes `Dynamic[top]` too.
      # A splatted literal that arrives through a binding (a local, a constant, an inline assignment) or a method
      # return, and a non-empty shape filled through an alias, still read narrower than they are: those are gaps in
      # the literal's and the binding's own types.
      #
      # Declines, leaving the RBS answer, when:
      #
      # - the method is not `transform_keys`. `transform_keys!` returns `self` and stays with RBS.
      # - the argument count is not one, or is unknown with no block. A `*splat`, a forwarded `...`, or a lone
      #   `**splat` may pass no argument, and with no block that call answers an `Enumerator`. With a block, the
      #   call is the block form or the mapping form, and a `Dynamic[top]` mapping arm covers both.
      # - a receiver member is not a `Hash` carrier: a `HashShape` other than the empty closed one, a `Hash`
      #   nominal, or a difference over one (`non-empty-hash[K, V]`). A subclass may override the method
      #   (`ActiveSupport::HashWithIndifferentAccess` does), and an empty closed shape answers `{}` whatever the
      #   mapping says.
      module HashTransformKeysFolding
        module_function

        def try_dispatch(context)
          return nil unless context.method_name == :transform_keys

          block = block_arm(context)
          renamed = mapping_arm(context, block)
          return nil if renamed.nil?

          receiver = context.receiver
          members = receiver.is_a?(Type::Union) ? receiver.members : [receiver]
          answers = members.map { |member| answer_for(member, renamed, block) }
          return nil if answers.any?(&:nil?)

          Type::Combinator.union(*answers)
        end

        # The mapping form's block parameter: the receiver's key type, as rbs 4.2's `{ (K old_key) -> K2 }`
        # declares it. rbs 3.10 has no mapping overload for the block-parameter probe to select, so without this
        # rule the parameter is `Dynamic[top]` there, and so is every key the block returns. Reached through
        # {IteratorDispatch.block_param_types}; nil falls through to the RBS probe.
        def block_param_types(context)
          return nil unless context.args.size == 1

          receiver = context.receiver
          members = receiver.is_a?(Type::Union) ? receiver.members : [receiver]
          keys = members.map { |member| receiver_key_value(member)&.first }
          return nil if keys.any?(&:nil?)

          [Type::Combinator.union(*keys)]
        end

        # `Hash[unmapped | renamed, V]` for one receiver member, or nil when the member is not a `Hash` carrier.
        def answer_for(receiver, renamed, block)
          key_value = receiver_key_value(receiver)
          return nil if key_value.nil?

          key, value = key_value
          new_key = Type::Combinator.union(block || key, renamed)
          Type::Combinator.nominal_of("Hash", type_args: [new_key, value])
        end

        # The receiver's `[K, V]`, projected the way {RbsDispatch} projects a shape, or nil when the receiver
        # is not a `Hash` carrier. An open shape may hold entries it does not list, so its key and value take
        # a `Dynamic[top]` arm.
        def receiver_key_value(receiver)
          case receiver
          when Type::HashShape then shape_key_value(receiver)
          when Type::Nominal then nominal_key_value(receiver)
          when Type::Difference then receiver_key_value(receiver.base)
          end
        end

        def shape_key_value(shape)
          return nil if shape.pairs.empty? && shape.closed?

          key = Type::Combinator.union(*shape.pairs.keys.map { |k| Type::Combinator.constant_of(k) })
          value = Type::Combinator.union(*shape.pairs.values)
          return [key, value] if shape.closed?

          [Type::Combinator.union(key, unknown), Type::Combinator.union(value, unknown)]
        end

        def nominal_key_value(nominal)
          return nil unless nominal.class_name == "Hash"
          return [unknown, unknown] unless nominal.type_args.size == 2

          nominal.type_args
        end

        # The new keys the mapping supplies, or nil when the call is not one this tier answers (see the module
        # comment for the argument-count rule).
        def mapping_arm(context, block)
          arguments = argument_nodes(context.call_node)
          return block.nil? ? nil : unknown if unresolved_argument_count?(arguments)
          return nil unless context.args.size == 1

          renamed = mapping_value_type(context.args.first)
          arguments.any? { |argument| splatted_literal?(argument) } ? Type::Combinator.union(renamed, unknown) : renamed
        end

        # The mapping's value type. Anything whose value type cannot be read contributes `Dynamic[top]`,
        # including a member that is not a Hash at all (`to_hash` may still convert it, and a `TypeError` for one
        # that cannot is not this tier's to report).
        def mapping_value_type(mapping)
          case mapping
          when Type::HashShape then shape_value_type(mapping)
          when Type::Nominal then nominal_value_type(mapping)
          when Type::Difference then mapping_value_type(mapping.base)
          when Type::Union then Type::Combinator.union(*mapping.members.map { |member| mapping_value_type(member) })
          else unknown
          end
        end

        # An empty closed shape contributes `Dynamic[top]`, not `bot`: the engine records no aliasing, so
        # `m = {}; m.tap { |x| x[:a] = :z }` still reads `{}` after the store, and a `bot` arm would drop `:z`.
        # A non-empty shape filled through an alias has the same gap, which this rule does not close.
        def shape_value_type(shape)
          return unknown if shape.pairs.empty? && shape.closed?

          value = Type::Combinator.union(*shape.pairs.values)
          shape.closed? ? value : Type::Combinator.union(value, unknown)
        end

        def nominal_value_type(nominal)
          return unknown unless nominal.class_name == "Hash" && nominal.type_args.size == 2

          nominal.type_args[1]
        end

        # The block's return type; `Dynamic[top]` when the call carries a block the block pass left untyped (it
        # rescues to nil); nil when there is no block, so the unmapped keys keep the receiver's key type. `&nil`
        # passes no block, whatever type the block pass gave it.
        def block_arm(context)
          block_node = context.call_node.is_a?(Prism::CallNode) ? context.call_node.block : nil
          return nil if block_node.is_a?(Prism::BlockArgumentNode) && block_node.expression.is_a?(Prism::NilNode)
          return context.block_type if context.block_type

          block_node ? unknown : nil
        end

        # The call's argument nodes, or an empty list for a nil or non-call node (an internal caller, whose
        # argument types are authoritative).
        def argument_nodes(call_node)
          return EMPTY_ARGUMENTS unless call_node.is_a?(Prism::CallNode)

          call_node.arguments&.arguments || EMPTY_ARGUMENTS
        end

        EMPTY_ARGUMENTS = [].freeze
        private_constant :EMPTY_ARGUMENTS

        # A `*splat`, a forwarded `...`, or keyword arguments made only of `**splat` entries: each may pass no
        # argument at all (`transform_keys(**{})` passes none), so whether there is a mapping is not static.
        def unresolved_argument_count?(arguments)
          arguments.any? do |argument|
            case argument
            when Prism::SplatNode, Prism::ForwardingArgumentsNode then true
            when Prism::KeywordHashNode then argument.elements.all?(Prism::AssocSplatNode)
            else false
            end
          end
        end

        # A hash literal or keyword arguments with a `**splat` entry. The literal's type lists only its own pairs
        # (`{ **o, b: :y }` reads `Hash[:b, :y]`), so the splatted mapping's values are missing from it. Any
        # argument is checked, not only the first: `h.send(:transform_keys, { **o, b: :y })` reaches this tier
        # with the `send` node, whose first argument is the method name. Parentheses are looked through to the
        # value they yield, their last statement.
        def splatted_literal?(argument)
          case argument
          when Prism::HashNode, Prism::KeywordHashNode then argument.elements.any?(Prism::AssocSplatNode)
          when Prism::ParenthesesNode
            body = argument.body
            body.is_a?(Prism::StatementsNode) && splatted_literal?(body.body.last)
          else false
          end
        end

        def unknown
          Type::Combinator.untyped
        end
      end
    end
  end
end
