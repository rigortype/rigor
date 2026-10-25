# frozen_string_literal: true

require "prism"

require_relative "block_parameter_binder"

module Rigor
  module Inference
    # Can a block see the hash that an in-place transform is rewriting? This is the gate for the in-place forms
    # of the HashShape per-pair fold (`ExpressionTyper#try_hash_shape_block_fold`).
    #
    # `transform_values!` / `transform_keys!` rewrite their receiver pair by pair while they iterate, so a block
    # that reads the receiver sees the pairs it has already rewritten. The fold types every pair against the
    # pre-call state held by the entry scope, so it gives a precise wrong answer: `h = { x: 1, y: 2 };
    # h.transform_values! { |e| h[:x] + e }` folded to `{ x: 2, y: 3 }`, where Ruby answers `{ x: 2, y: 4 }`.
    #
    # The engine records no aliasing between bindings, and a method can return the receiver under any name.
    # The gate therefore does not look for the receiver. It admits a block only when everything the block
    # reads from outside itself is incapable of describing a hash's contents:
    #
    # - A local declared inside the block tree — a parameter or a block-local — is admitted. Prism's `depth`
    #   decides this, so a nested parameter that shadows an outer local is still a parameter.
    # - A captured local, instance, class or global variable, or a constant, is admitted when its entry type
    #   carries no hash contents ({#carries_hash_contents?}). A compound write reads first, so it counts too.
    #   A constant compound write (`F ||= …`) names no read node to type, and a constant path under a
    #   non-constant parent (`m::T`) cannot be typed from the entry scope, so neither is admitted.
    # - A method call is admitted only when its receiver is built from block parameters and literals alone
    #   (`e.to_s.upcase`, `[e].map { … }`, `%i[a b].include?(k)`). This excludes an implicit-self call and a
    #   call on `self`, a constant, a captured variable or a block-local, because the method can return the
    #   receiver however the value it is called on is typed (`Registry.store[:x]`, `tbl[:x]` for
    #   `def tbl = TABLE`).
    # - `super`, `yield`, and a nested `def` / `class` / `module` / `class << x` run code the walk cannot
    #   see, so they are never admitted.
    # - The operand of `defined?` is not walked: it asks whether a name is defined and reads no value.
    #
    # What a method called on a block parameter reaches is outside the gate. Such a method can read global
    # state, but its inferred return type can hold stale constant contents without any in-place transform,
    # so this is the engine-wide method-effect gap rather than this fold's. The gate only costs precision on
    # the value of the bang call itself, because the receiver's own binding is widened after any bang call.
    module ReceiverBlindBlock
      LOCAL_READS = [
        Prism::LocalVariableReadNode,
        Prism::LocalVariableOperatorWriteNode,
        Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode
      ].freeze

      # Each captured non-local read, and the `Scope` accessor holding its entry binding.
      VARIABLE_ACCESSORS = Ractor.make_shareable({
                                                   Prism::InstanceVariableReadNode => :ivar,
                                                   Prism::InstanceVariableOperatorWriteNode => :ivar,
                                                   Prism::InstanceVariableOrWriteNode => :ivar,
                                                   Prism::InstanceVariableAndWriteNode => :ivar,
                                                   Prism::ClassVariableReadNode => :cvar,
                                                   Prism::ClassVariableOperatorWriteNode => :cvar,
                                                   Prism::ClassVariableOrWriteNode => :cvar,
                                                   Prism::ClassVariableAndWriteNode => :cvar,
                                                   Prism::GlobalVariableReadNode => :global,
                                                   Prism::GlobalVariableOperatorWriteNode => :global,
                                                   Prism::GlobalVariableOrWriteNode => :global,
                                                   Prism::GlobalVariableAndWriteNode => :global
                                                 })

      CONSTANT_READS = [Prism::ConstantReadNode, Prism::ConstantPathNode].freeze

      # A constant compound write reads the constant by name, with no read node for the walk to type.
      CONSTANT_COMPOUND_WRITES = [
        Prism::ConstantOperatorWriteNode,
        Prism::ConstantOrWriteNode,
        Prism::ConstantAndWriteNode
      ].freeze

      # Every node that calls a method on a receiver.
      RECEIVER_CALLS = [
        Prism::CallNode,
        Prism::CallAndWriteNode,
        Prism::CallOperatorWriteNode,
        Prism::CallOrWriteNode,
        Prism::CallTargetNode,
        Prism::IndexAndWriteNode,
        Prism::IndexOperatorWriteNode,
        Prism::IndexOrWriteNode,
        Prism::IndexTargetNode
      ].freeze

      # Nodes that run code the walk cannot see, or open a scope the block's locals are invisible from.
      OPAQUE = [
        Prism::SuperNode,
        Prism::ForwardingSuperNode,
        Prism::YieldNode,
        Prism::DefNode,
        Prism::ClassNode,
        Prism::ModuleNode,
        Prism::SingletonClassNode
      ].freeze

      # Literal nodes, whose value is built from their children alone.
      LITERALS = [
        Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
        Prism::StringNode, Prism::SymbolNode, Prism::RegularExpressionNode,
        Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode, Prism::EmbeddedStatementsNode,
        Prism::NilNode, Prism::TrueNode, Prism::FalseNode,
        Prism::ArrayNode, Prism::HashNode, Prism::AssocNode, Prism::RangeNode
      ].freeze

      # A `Type` carrier is an immutable value built bottom-up, so it cannot contain itself. The cap is
      # defensive only, and exceeding it answers "carries": declining the fold is the safe side.
      TYPE_DEPTH_CAP = 8

      module_function

      # @param base_scope — the call-site scope the block closes over.
      def blind?(block_node, base_scope)
        scope_blind?(block_node, [], base_scope)
      end

      # `levels` holds the parameter names of each block from the transform's own block (index 0) down to
      # the innermost block around the node, so a local read's Prism `depth` names the block that declares
      # it, or none when the read is captured from outside.
      def scope_blind?(block_node, levels, base_scope)
        levels += [Set.new(BlockParameterBinder.new.bind(block_node).keys)]
        [block_node.parameters, block_node.body].all? { |child| node_blind?(child, levels, base_scope) }
      end

      def node_blind?(node, levels, base_scope)
        case node
        when nil, Prism::DefinedNode then true
        when Prism::BlockNode, Prism::LambdaNode then scope_blind?(node, levels, base_scope)
        when *OPAQUE then false
        else
          admitted?(node, levels, base_scope) &&
            node.compact_child_nodes.all? { |child| node_blind?(child, levels, base_scope) }
        end
      end

      def admitted?(node, levels, base_scope)
        case node
        when *LOCAL_READS then in_block_tree?(node, levels) || !carries_hash_contents?(base_scope.local(node.name))
        when *VARIABLE_ACCESSORS.keys
          !carries_hash_contents?(base_scope.public_send(VARIABLE_ACCESSORS[node.class], node.name))
        when *CONSTANT_READS then !constant_carries?(node, base_scope)
        when *CONSTANT_COMPOUND_WRITES then false
        when *RECEIVER_CALLS then built_from_parameters?(node.receiver, levels)
        else true
        end
      end

      def in_block_tree?(read, levels) = !declaring_level(read, levels).nil?

      # The index into `levels` of the block that declares a local read, or `nil` for a captured read.
      def declaring_level(read, levels)
        level = levels.size - 1 - read.depth
        level unless level.negative?
      end

      # Whether a call receiver's value comes from block parameters and literals alone. A call inside it is
      # followed to its own receiver; its arguments are admitted by the walk on their own.
      def built_from_parameters?(receiver, levels)
        case receiver
        when Prism::LocalVariableReadNode
          level = declaring_level(receiver, levels)
          !level.nil? && levels[level].include?(receiver.name)
        when Prism::ItLocalVariableReadNode then true
        when Prism::ParenthesesNode then built_from_parameters?(receiver.body, levels)
        when Prism::StatementsNode then built_from_parameters?(receiver.body.last, levels)
        when *RECEIVER_CALLS then built_from_parameters?(receiver.receiver, levels)
        when *LITERALS then receiver.compact_child_nodes.all? { |child| built_from_parameters?(child, levels) }
        else false
        end
      end

      def constant_carries?(node, base_scope)
        return true if node.is_a?(Prism::ConstantPathNode) && !constant_parent?(node.parent)

        carries_hash_contents?(base_scope.type_of(node))
      rescue StandardError
        true
      end

      # `::T` has no parent; `A::T` and `A::B::T` have constant parents.
      def constant_parent?(parent)
        parent.nil? || CONSTANT_READS.include?(parent.class)
      end

      # Whether a value of `type` can tell a reader what some hash holds, key by key or as `Hash[K, V]`
      # parameters. A read through such a value in an in-place transform's block can be stale by the next
      # pair. `Dynamic[top]`, a bare `Hash` and a scalar cannot, and neither can a `Hash` whose parameters are
      # untyped.
      def carries_hash_contents?(type, depth = 0)
        return false if type.nil?
        return true if depth > TYPE_DEPTH_CAP || type.is_a?(Type::HashShape) || typed_hash_nominal?(type)

        component_types(type).any? { |inner| carries_hash_contents?(inner, depth + 1) }
      end

      def typed_hash_nominal?(type)
        type.is_a?(Type::Nominal) && type.class_name == "Hash" &&
          type.type_args.any? { |arg| !arg.is_a?(Type::Dynamic) && !arg.is_a?(Type::Top) }
      end

      # The types a carrier holds. The list is empty for a carrier that cannot hold another value's type.
      def component_types(type)
        case type
        when Type::Union, Type::Intersection then type.members
        when Type::Tuple then type.elements
        when Type::Nominal then type.type_args
        when Type::Refined, Type::Difference then [type.base]
        when Type::StructInstance, Type::DataInstance then type.members.values
        when Type::Dynamic then [type.static_facet]
        when Type::BoundMethod then [type.receiver_type]
        when Type::Maybe then [type.value_type]
        when Type::Result then [type.ok_type, type.err_type]
        when Type::App then [*type.args, type.bound]
        else []
        end
      end
    end
  end
end
