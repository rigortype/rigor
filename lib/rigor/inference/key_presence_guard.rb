# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "mutation_widening"

module Rigor
  module Inference
    # Issue #1703 — `H.key?(k)` / `has_key?` / `include?` / `member?` with a non-literal key, followed by `H[k]`.
    #
    # A closed hash shape read by a computed key answers every value plus the miss `nil`
    # (`ShapeDispatch#hash_dig_step`), so the guarded read in typelizer's
    # `COLUMN_TYPE_MAP.key?(property.column_type) && …; COLUMN_TYPE_MAP[property.column_type].dup` kept the `nil`
    # and its `[]=` reported `call.possible-nil-receiver`.
    # On the true edge the guard is recorded in the scope's indexed-narrowing table under a {KeyExpr} address, and a
    # later read of the same receiver by structurally the same key drops the miss `nil` ({.guarded_read}).
    #
    # The narrowing exists to remove nil-receiver reports and must not add a diagnostic anywhere else:
    # - the read and every value computed from it are marked optimistic ({OptimisticOrigin::KEY_PRESENCE_GUARD} /
    #   `KEY_PRESENCE_DERIVED`), so certainty verdicts folded from them decline;
    # - a method's return summary and `sig-gen` are computed with guards off ({.without_guards}), so no narrowed type
    #   crosses a method boundary;
    # - the guard is dropped wherever the receiver or the key may have changed ({.invalidate_after_call},
    #   {.invalidate_after_write}, and `Scope#bind_local` / `#bind_ivar` for a rebinding).
    module KeyPresenceGuard
      # The key half of a guard's address: a local, an instance variable, or a chain of plain readers rooted at one
      # (`prop.column_type`). `path` is `[[root_kind, root_name], method, …]`, so two spellings of one chain compare
      # equal.
      KeyExpr = Data.define(:path) do
        def root = path.first

        # Whether `other` reads a prefix of this chain (`prop` or `prop.column_type` for `prop.column_type`), so
        # evaluating it re-reads this key rather than intervening.
        def prefixed_by?(other) = path.first(other.path.size) == other.path
      end

      # What a guard stores at its address. The fact is the entry's presence on every joined arm; the read
      # recomputes its type from the receiver, so the value carries nothing.
      PRESENT = Type::Combinator.constant_of(true)

      OFF_KEY = :__rigor_key_presence_guards_off
      private_constant :OFF_KEY

      # A plain reader's name: lower-case, no operator, writer or bang.
      READER_NAME = /\A[a-z_][a-z0-9_]*\??\z/

      # Reader-shaped names that answer something new on each call or consume state, so `h.key?(q.shift)` and a later
      # `h[q.shift]` read different keys. Every name the mutation tables know is excluded too.
      NON_IDEMPOTENT_READERS = (
        %i[
          shift pop unshift push append prepend next succ pred gets read readline readlines readpartial read_nonblock
          getc getbyte readchar readbyte each each_line each_char each_byte rand random sample shuffle tick now call
          yield resume take take_while drop lazy to_enum enum_for peek rewind reload reset lock unlock clear
          generate fetch_next dequeue deq enqueue enq poll receive recv accept consume
        ] + MutationWidening::SHAPE_MUTATORS.to_a
      ).to_set.freeze

      # Blockless calls on a guarded receiver that cannot remove a key or rebind a slot. Any other call on it, and
      # any call with a block, may (`h.delete(k)`, `h.send(:delete, k)`, `h.each { … h.clear }`).
      READ_ONLY_RECEIVER_CALLS = %i[
        [] key? has_key? include? member? fetch dig values_at fetch_values size length count empty? any? none?
        keys values to_a to_h dup clone freeze frozen? itself hash == != eql? equal? inspect to_s is_a? kind_of?
        instance_of? nil? respond_to?
      ].to_set.freeze

      # The nodes whose `value` a write stores: storing the receiver or the key's root somewhere else aliases it.
      WRITE_NODES = [
        Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode,
        Prism::GlobalVariableWriteNode, Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::MultiWriteNode,
        Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::LocalVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
        Prism::InstanceVariableOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
        Prism::IndexOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode, Prism::CallOperatorWriteNode
      ].to_set.freeze

      module_function

      # Runs the block with guards neither recorded nor read, for the analyses whose answer leaves the method: a
      # callee's return summary and `sig-gen`. Thread-local, so it holds under a Ractor worker too.
      def without_guards
        previous = Thread.current[OFF_KEY]
        Thread.current[OFF_KEY] = true
        yield
      ensure
        Thread.current[OFF_KEY] = previous
      end

      def off? = Thread.current[OFF_KEY] == true

      # The {KeyExpr} for `node`, or nil unless it is a local / ivar read or a chain of plain, idempotent readers
      # (no argument, block or `&.`) rooted at one. A literal key is the shape path's business and answers nil.
      def key_expr(node)
        case node
        when Prism::LocalVariableReadNode then KeyExpr.new(path: [[:local, node.name]].freeze)
        when Prism::InstanceVariableReadNode then KeyExpr.new(path: [[:ivar, node.name]].freeze)
        when Prism::CallNode
          return nil unless plain_reader_call?(node)

          inner = key_expr(node.receiver)
          inner && KeyExpr.new(path: (inner.path + [node.name]).freeze)
        end
      end

      def plain_reader_call?(node)
        node.receiver && node.block.nil? && node.arguments.nil? && !node.safe_navigation? &&
          READER_NAME.match?(node.name) && !NON_IDEMPOTENT_READERS.include?(node.name)
      end

      # The receiver half of a guard's address: a local, an instance variable or a constant read.
      def receiver_ref(node)
        case node
        when Prism::LocalVariableReadNode then [:local, node.name]
        when Prism::InstanceVariableReadNode then [:ivar, node.name]
        when Prism::ConstantReadNode then [:const, node.name]
        end
      end

      # `[receiver_kind, receiver_name, KeyExpr]` for `receiver[key]` / `receiver.key?(key)`, or nil.
      def address(receiver_node, key_node)
        receiver = receiver_ref(receiver_node)
        return nil if receiver.nil?

        key = key_expr(key_node)
        key && [receiver.first, receiver.last, key]
      end

      # A closed, non-empty hash shape (or a union of them): the carrier whose computed-key read carries the miss
      # `nil`. An RBS `Hash[K, V]` read is already nil-free; an open shape or a user class answering `key?` is left
      # alone.
      def receiver_type?(type)
        if type.is_a?(Type::Union)
          type.members.all? { |member| closed_shape?(member) }
        else
          closed_shape?(type)
        end
      end

      def closed_shape?(type) = type.is_a?(Type::HashShape) && type.closed? && !type.pairs.empty?

      # The truthy edge of `receiver.key?(key)` with a non-literal key: `scope` with the guard recorded, or nil when
      # the guard does not apply.
      def record(call_node, scope)
        return nil if off?

        args = call_node.arguments&.arguments
        return nil unless args&.size == 1

        guard = address(call_node.receiver, args.first)
        return nil if guard.nil?
        return nil unless receiver_type?(scope.type_of(call_node.receiver))

        scope.with_indexed_narrowing(*guard, PRESENT)
      end

      # `type`, the un-narrowed answer of the read `node`, with the miss `nil` dropped when a guard on the same
      # receiver and structurally the same key holds in `scope` and no value of the receiver can be `nil` (the read
      # cannot tell a value's own `nil` from the miss). Nil when no guard applies or nothing would change.
      def guarded_read(node, type, scope)
        return nil unless node.name == :[] && guarded?(node, scope)

        receiver_type = scope.type_of(node.receiver)
        return nil unless receiver_type?(receiver_type)

        shapes = receiver_type.is_a?(Type::Union) ? receiver_type.members : [receiver_type]
        return nil if shapes.any? { |shape| shape.pairs.each_value.any? { |value| value_may_be_nil?(value) } }

        narrowed = Narrowing.narrow_non_nil(type)
        narrowed == type || narrowed.is_a?(Type::Bot) ? nil : narrowed
      end

      def guarded?(node, scope)
        return false if off? || !any_guard?(scope) || !node.block.nil?

        args = node.arguments&.arguments
        guard = args&.size == 1 ? address(node.receiver, args.first) : nil
        !guard.nil? && !scope.indexed_narrowing(*guard).nil?
      end

      # Whether `scope` holds any guard. Walks the keys without allocating, so the common no-guard case costs a size
      # check.
      def any_guard?(scope)
        table = scope.indexed_narrowings
        return false if table.empty?

        table.each_key { |key| return true if key.key.is_a?(KeyExpr) }
        false
      end

      def value_may_be_nil?(value)
        case value
        when Type::Top then true
        when Type::Constant then value.value.nil?
        when Type::Nominal then value.class_name == "NilClass"
        when Type::Union then value.members.any? { |member| value_may_be_nil?(member) }
        else false
        end
      end

      # Drops the guards `call_node` may break. Always-safe (only forgets; never invents).
      def invalidate_after_call(call_node, scope)
        return scope unless call_node.is_a?(Prism::CallNode) && any_guard?(scope)

        drop_guards(scope) { |guard| breaks?(call_node, guard) }
      end

      # Drops the guards a write aliases: one whose value holds the guarded receiver or the key's root variable
      # (`g = h`, `j = k`, `@cache = [MAP]`), since the copy may then be mutated or rebound out of sight.
      def invalidate_after_write(node, scope)
        return scope unless WRITE_NODES.include?(node.class) && any_guard?(scope)

        value = node.value
        drop_guards(scope) do |guard|
          mentions?(value, [guard.receiver_kind, guard.receiver_name]) || mentions?(value, guard.key.root)
        end
      end

      def drop_guards(scope)
        result = scope
        scope.indexed_narrowings.each_key do |guard|
          next unless guard.key.is_a?(KeyExpr) && yield(guard)

          result = result.without_indexed_narrowing(guard.receiver_kind, guard.receiver_name, guard.key)
        end
        result
      end

      # A guard ends at:
      # - a call that passes the receiver as an argument (or `self`, when an instance variable is involved), or whose
      #   block mentions the receiver or the key's root;
      # - a call on the receiver other than a blockless read ({READ_ONLY_RECEIVER_CALLS});
      # - a call rooted at the key's variable that does not re-read the key chain (`prop.reload`, `prop.x = 1`);
      # - a call on `self` when the receiver or the key is an instance variable.
      # Passing the key's root as an argument (`overridden?(prop)`) does not end it, as it does not end a method-chain
      # narrowing.
      def breaks?(call_node, guard)
        receiver_ref = [guard.receiver_kind, guard.receiver_name]
        return true if escapes_through_operands?(call_node, receiver_ref, guard.key.root)

        receiver = call_node.receiver
        if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          return guard.receiver_kind == :ivar || guard.key.root.first == :ivar
        end
        return true if receiver_ref(receiver) == receiver_ref && !read_only_call?(call_node)

        touches_key_root?(call_node, guard.key)
      end

      def escapes_through_operands?(call_node, receiver_ref, key_root)
        args = call_node.arguments
        return true if args && mentions?(args, receiver_ref)
        # `other.mutate_owner(self)` hands on every instance variable.
        return true if args && (receiver_ref.first == :ivar || key_root.first == :ivar) && mentions_self?(args)

        block = call_node.block
        return false if block.nil?

        mentions?(block, receiver_ref) || (block.is_a?(Prism::BlockNode) && mentions?(block, key_root))
      end

      def read_only_call?(call_node) = call_node.block.nil? && READ_ONLY_RECEIVER_CALLS.include?(call_node.name)

      def touches_key_root?(call_node, key)
        return false unless chain_root(call_node.receiver) == key.root

        own = key_expr(call_node)
        own.nil? || !key.prefixed_by?(own)
      end

      # The `[kind, name]` of the local / ivar a receiver chain (`a.b.c`, `a[0].b`) starts from, or nil.
      def chain_root(node)
        node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver
        case node
        when Prism::LocalVariableReadNode then [:local, node.name]
        when Prism::InstanceVariableReadNode then [:ivar, node.name]
        end
      end

      def mentions_self?(node)
        node.is_a?(Prism::SelfNode) || node.compact_child_nodes.any? { |child| mentions_self?(child) }
      end

      # Whether `node` holds a read of the variable `ref` in a position that may hand it on: anywhere but as the
      # receiver of a blockless read ({READ_ONLY_RECEIVER_CALLS}), so `h[k]` and `MAP.key?(x)` do not count while
      # `zap(h)`, `[h]` and `h.delete(k)` do.
      def mentions?(node, ref)
        return false if node.nil?
        return receiver_ref(node) == ref if receiver_ref(node)

        if node.is_a?(Prism::CallNode) && receiver_ref(node.receiver) == ref && read_only_call?(node)
          return [node.arguments, node.block].any? { |part| mentions?(part, ref) }
        end

        node.compact_child_nodes.any? { |child| mentions?(child, ref) }
      end
    end
  end
end
