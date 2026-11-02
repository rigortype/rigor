# frozen_string_literal: true

require "prism"

require_relative "../type"
# `Narrowing` is resolved at call time: requiring it here closes a load cycle through `KeyPresenceGuard`.

module Rigor
  module Inference
    # Issue #2608 — a collection remover or filter narrows its receiver's element (or Hash key / value) type by what
    # Ruby guarantees it removed, where that is provable from the call alone:
    #
    # - `Array#compact!` / `Hash#compact!` drop `nil` from the element / value;
    # - `Array#delete(nil)` / `Set#delete(nil)` / `Set#delete?(nil)` drop `nil` from the element, and `Hash#delete(nil)`
    #   drops it from the key, given a literal `nil`;
    # - `reject!` / `delete_if` keep the elements the block answers falsey for, and `select!` / `filter!` / `keep_if`
    #   the ones it answers truthy for. The block's one expression is read by the engine's own predicate narrowing
    #   ({Narrowing.predicate_scopes}) with its parameter bound to the element (the Hash `|k, v|` form binds both), and
    #   the surviving element is that parameter's binding on the matching edge. `&:nil?` reads as `{ |x| x.nil? }`;
    # - a closed `HashShape` loses the key a literal `delete(:k)` names.
    #
    # Everything else (`pop`, `shift`, `slice!`, `subtract`, `delete` of a non-literal, a block whose predicate the
    # narrowing does not read) answers `nil`: which members remain is not provable, and the caller keeps its reading.
    #
    # Only a receiver that is itself a local or instance-variable read narrows: a receiver selecting among bindings
    # (`(f ? a : b).compact!`) mutates one of them, and narrowing every candidate would drop a member from the one the
    # call never touched. An alias of the receiver keeps its own, wider, binding (still true of the object).
    module RemoverNarrowing
      NIL_REJECTORS = %i[compact!].to_set.freeze
      NIL_LITERAL_DELETERS = %i[delete delete?].to_set.freeze
      FALSEY_KEEPERS = %i[reject! delete_if].to_set.freeze
      TRUTHY_KEEPERS = %i[select! filter! keep_if].to_set.freeze
      CANDIDATES = (NIL_REJECTORS | NIL_LITERAL_DELETERS | FALSEY_KEEPERS | TRUTHY_KEEPERS).freeze
      NARROWING_RECEIVERS = [Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode].freeze
      CARRIERS = %w[Array Hash Set].freeze
      # Nodes that make a one-expression block's value something other than its predicate, or rebind a parameter.
      OPAQUE_BLOCK_NODES = [
        Prism::NextNode, Prism::BreakNode, Prism::ReturnNode, Prism::RedoNode, Prism::RetryNode, Prism::YieldNode,
        Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
        Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode
      ].freeze
      private_constant :NIL_REJECTORS, :NIL_LITERAL_DELETERS, :FALSEY_KEEPERS, :TRUTHY_KEEPERS, :NARROWING_RECEIVERS,
                       :CARRIERS, :OPAQUE_BLOCK_NODES

      module_function

      # Whether `call_node` may narrow its receiver at all: a cheap syntactic gate for {.narrow}.
      def candidate?(call_node)
        CANDIDATES.include?(call_node.name) && NARROWING_RECEIVERS.any? { |klass| call_node.receiver.is_a?(klass) }
      end

      # The closed `HashShape` `shape` without the key a literal `delete(:k)` names, or `nil` when the call is no such
      # delete or the shape is open (an unseen key may be the one deleted, and the opened default reads it back).
      def narrow_shape(shape, call_node)
        return nil unless shape.is_a?(Type::HashShape) && shape.closed? && call_node.name == :delete
        return nil unless call_node.block.nil?

        key = literal_key(single_argument(call_node))
        return nil if key.equal?(NO_KEY)
        return shape unless shape.pairs.key?(key)
        return nil if shape.read_only_key?(key)

        Type::Combinator.hash_shape_of(
          shape.pairs.except(key),
          required_keys: shape.required_keys - [key], optional_keys: shape.optional_keys - [key],
          read_only_keys: shape.read_only_keys, extra_keys: :closed
        )
      end

      # `type` with each Array / Hash / Set member narrowed by what `call_node` removes, member-wise through a union.
      # `nil` when the call narrows no member (it is no exact remover for the member's class, or its block predicate
      # says nothing about the element). A member the call answers for without change (`compact!` on `Array[Integer]`)
      # still counts as answered: the caller then keeps the precise reading rather than a floored one.
      def narrow(type, call_node, scope)
        answered = false
        members = members_of(type).map do |member|
          narrowed = narrow_member(member, call_node, scope)
          next member if narrowed.nil?

          answered = true
          narrowed
        end
        answered ? Type::Combinator.union(*members) : nil
      end

      def members_of(type)
        type.is_a?(Type::Union) ? type.members : [type]
      end

      def narrow_member(member, call_node, scope)
        return nil unless member.is_a?(Type::Nominal) && CARRIERS.include?(member.class_name)

        args = member.type_args
        case member.class_name
        when "Hash" then args.size == 2 ? narrow_hash(member, call_node, scope) : nil
        else args.size == 1 ? narrow_elements(member, call_node, scope) : nil
        end
      end

      def narrow_elements(member, call_node, scope)
        element = member.type_args.first
        narrowed =
          case call_node.name
          when :compact! then member.class_name == "Array" ? Narrowing.narrow_non_nil(element) : nil
          when :delete, :delete? then nil_deleted?(call_node, member) ? Narrowing.narrow_non_nil(element) : nil
          else block_narrowed(call_node, scope, [element])&.first
          end
        usable?(narrowed) ? Type::Combinator.nominal_of(member.class_name, type_args: [narrowed]) : nil
      end

      def narrow_hash(member, call_node, scope)
        key, value = member.type_args
        narrowed =
          case call_node.name
          when :compact! then [key, Narrowing.narrow_non_nil(value)]
          when :delete then nil_argument?(call_node) ? [Narrowing.narrow_non_nil(key), value] : nil
          when :delete? then nil
          else block_narrowed(call_node, scope, [key, value])
          end
        narrowed&.all? { |arg| usable?(arg) } ? Type::Combinator.nominal_of("Hash", type_args: narrowed) : nil
      end

      # A parameter narrowed to `bot` (`select! { |x| x.nil? }` on `Array[Integer]`) says the carrier is empty; that
      # is left to the caller's reading rather than spelled as `Array[bot]`.
      def usable?(type)
        !type.nil? && !type.is_a?(Type::Bot)
      end

      # `Array#delete(nil)` and `Set#delete(nil)` / `Set#delete?(nil)`; `Array#delete?` does not exist.
      def nil_deleted?(call_node, member)
        return false if call_node.name == :delete? && member.class_name != "Set"

        nil_argument?(call_node)
      end

      def nil_argument?(call_node)
        single_argument(call_node).is_a?(Prism::NilNode)
      end

      def single_argument(call_node)
        arguments = call_node.arguments&.arguments
        arguments&.size == 1 ? arguments.first : nil
      end

      NO_KEY = Object.new.freeze
      private_constant :NO_KEY

      def literal_key(node)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::StringNode then node.unescaped.freeze
        when Prism::IntegerNode then node.value
        else NO_KEY
        end
      end

      # The block parameters' types on the edge that keeps an element, or `nil` when the call has no block the
      # narrowing reads: one expression, no jump or local write, explicit required parameters matching the carrier
      # (`|x|` for an element, `|k, v|` for a Hash pair), and a predicate that narrows one of them on some edge.
      def block_narrowed(call_node, scope, types)
        keep = keep_edge(call_node.name)
        return nil if keep.nil?

        block = call_node.block
        return symbol_nil_narrowed(block, keep, types) if block.is_a?(Prism::BlockArgumentNode)

        names = block_parameter_names(block, types.size)
        predicate = names && block_predicate(block)
        return nil if predicate.nil?

        predicate_narrowed(predicate, scope, names, types, keep)
      end

      def keep_edge(method_name)
        if FALSEY_KEEPERS.include?(method_name) then :falsey
        elsif TRUTHY_KEEPERS.include?(method_name) then :truthy
        end
      end

      def symbol_nil_narrowed(block, keep, types)
        symbol = block.expression
        return nil unless types.size == 1 && symbol.is_a?(Prism::SymbolNode) && symbol.unescaped == "nil?"

        [keep == :falsey ? Narrowing.narrow_non_nil(types.first) : Narrowing.narrow_nil(types.first)]
      end

      def block_parameter_names(block, arity)
        return nil unless block.is_a?(Prism::BlockNode)

        parameters = block.parameters
        return nil unless parameters.is_a?(Prism::BlockParametersNode) && parameters.locals.empty?

        list = parameters.parameters
        return nil if list.nil? || !simple_parameters?(list) || list.requireds.size != arity
        return nil unless list.requireds.all?(Prism::RequiredParameterNode)

        list.requireds.map(&:name)
      end

      def simple_parameters?(list)
        list.optionals.empty? && list.rest.nil? && list.posts.empty? && list.keywords.empty? &&
          list.keyword_rest.nil? && list.block.nil?
      end

      def block_predicate(block)
        body = block.body
        return nil unless body.is_a?(Prism::StatementsNode) && body.body.size == 1

        statement = body.body.first
        opaque?(statement) ? nil : statement
      end

      def opaque?(node)
        return true if OPAQUE_BLOCK_NODES.any? { |klass| node.is_a?(klass) }

        node.compact_child_nodes.any? { |child| opaque?(child) }
      end

      def predicate_narrowed(predicate, scope, names, types, keep)
        bound = names.zip(types).reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
        truthy, falsey = Narrowing.predicate_scopes(predicate, bound)
        read = ->(edge) { names.map { |name| edge.local(name) || bound.local(name) } }
        entry_types = read.call(bound)
        truthy_types = read.call(truthy)
        falsey_types = read.call(falsey)
        return nil if truthy_types == entry_types && falsey_types == entry_types

        keep == :truthy ? truthy_types : falsey_types
      end
    end
  end
end
