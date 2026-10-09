# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "mutation_widening"
require_relative "unknown_store_widening"

module Rigor
  module Inference
    # Closes the "`params[:f] ||= []; params[:f] << x`" precision gap surfaced by the Redmine
    # 6.1.2 `Query#as_params` survey (ROADMAP § Future cycles / Type-language / engine —
    # "Indexed-collection narrowing through `Hash[k] ||= default`").
    #
    # After `receiver[key] ||= default` the next read at `receiver[key]` is known non-nil, but
    # Rigor types each `Hash#[]` independently and the subsequent `<<` / `[]=` / other mutator
    # dispatches against the un-narrowed result — which on a `HashShape{}` carrier folds to
    # `Constant[nil]`.
    #
    # This module is the address-recogniser + invalidator shared by
    # {Inference::StatementEvaluator}'s `eval_index_or_write` handler (which RECORDS the
    # narrowing) and `eval_call` (which INVALIDATES on intervening writes / mutators) and by
    # {Inference::ExpressionTyper}'s `call_type_for` (which CONSUMES the narrowing when typing a
    # follow-up `[]` read).
    #
    # **Stable receivers.** A receiver is "stable" iff it is a `LocalVariableReadNode` or
    # `InstanceVariableReadNode`. Method-call chains (`foo.bar[:k]`) and other shapes are
    # rejected because a follow-up read against an identical-looking AST chain has no guarantee
    # of resolving to the same runtime value — narrowing it would invent a fact.
    #
    # **Stable keys.** A key is "stable" iff it is a literal `SymbolNode` / `StringNode` /
    # `IntegerNode`. Local-variable keys (`params[field]`) are excluded for the same
    # invent-a-fact reason: the local could be rebound between the `||=` and the read.
    #
    # **Invalidation.** Three conditions drop a recorded narrowing:
    # - The receiver variable is rebound (handled inside `Scope#with_local` / `Scope#with_ivar`).
    # - An intervening `receiver[key] = value` writes the same slot — `:[]=` could rebind the
    #   slot to nil; conservative drop.
    # - An intervening mutator from {MutationWidening::SHAPE_MUTATORS} runs against the receiver
    #   (e.g. `params.delete(:f)`, `params.clear`, `params.default = 0`, `buf.delete_prefix!("x")`).
    #
    # All three are implemented in `StatementEvaluator#eval_call`'s post-dispatch path through
    # {.invalidate_after_call}.
    module IndexedNarrowing
      # Literal Prism nodes whose Ruby value the analyzer trusts as a stable address. Symbol /
      # String are the dominant Hash key shapes; Integer covers numerically-keyed Hashes and
      # Array indices.
      STABLE_KEY_NODES = [Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode].freeze

      module_function

      # Returns `[receiver_kind, receiver_name]` when `node` is a `LocalVariableReadNode` or
      # `InstanceVariableReadNode`, otherwise nil.
      def stable_receiver(node)
        case node
        when Prism::LocalVariableReadNode then [:local, node.name]
        when Prism::InstanceVariableReadNode then [:ivar, node.name]
        end
      end

      # Returns the literal Ruby value when `node` is a stable key shape, otherwise nil.
      # Symbols → `Symbol`, Strings → `String` (unescaped), Integers → `Integer`.
      def stable_key(node)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::StringNode then node.unescaped
        when Prism::IntegerNode then node.value
        end
      end

      # Returns `[receiver_kind, receiver_name, key]` when the CallNode is a `receiver[key]` read
      # or write whose receiver and key are both stable, otherwise nil. Used by both the recorder
      # (for `IndexOrWriteNode`'s receiver/arguments triplet) and the invalidator (for `CallNode
      # :[]=` / mutator calls). Treats only the FIRST argument as the key; `:[]=`'s second
      # argument is the rvalue and is not part of the address.
      def stable_address(receiver_node, key_node)
        receiver = stable_receiver(receiver_node)
        return nil if receiver.nil?

        key = stable_key(key_node)
        return nil if key.nil?

        [receiver.first, receiver.last, key]
      end

      # Issue #544 — whether the RECEIVER's type is precise enough for a recorded slot value to be a
      # fact. A `Dynamic` / `Top` constituent means the collection can hold a caller-supplied value at
      # the slot that `||=` keeps, so recording the default alone would invent a fact (mail's
      # `options[:count] ||= :all` folded a reachable `count: 1` path away). Unions walk their members;
      # everything else — the tracked `HashShape` / `Tuple` carriers this feature was built for, and
      # plain nominals whose RBS read already answers honestly — passes.
      def fully_tracked_receiver_type?(type)
        case type
        when Type::Dynamic, Type::Top then false
        when Type::Union then type.members.all? { |m| fully_tracked_receiver_type?(m) }
        else true
        end
      end

      # Looks up a recorded narrowing for `receiver[key]` against `scope`, returning the narrowed
      # type or nil when no entry applies. Used by ExpressionTyper's `[]` dispatch to refine the
      # result of a stable indexed read.
      def lookup_for_call(node, scope)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.name == :[]
        return nil if node.arguments.nil?
        return nil unless node.arguments.arguments.size == 1

        address = stable_address(node.receiver, node.arguments.arguments.first)
        return nil if address.nil?

        scope.indexed_narrowing(*address)
      end

      # Removes recorded narrowings invalidated by `call_node`. Two patterns:
      #
      # - `receiver[key] = value` (a `:[]=` against a stable address): drop the specific
      #   `(receiver, key)` entry.
      # - Any mutator from `SHAPE_MUTATORS` against a stable receiver: drop EVERY entry rooted at
      #   that receiver, because the mutator could rebind any slot. A {HashLookupMutation} name
      #   rebinds none, but it changes what a read of one answers — a missing slot's default, or
      #   whether a literal key still finds its pair — so it drops them too.
      #
      # Returns the updated scope. Always-safe (only forgets; never invents).
      def invalidate_after_call(call_node:, current_scope:)
        return current_scope unless call_node.is_a?(Prism::CallNode)

        if call_node.name == :[]=
          widen_mutated_slot(call_node, invalidate_indexed_write(call_node, current_scope))
        elsif mutator?(call_node.name)
          invalidate_mutator(call_node, current_scope)
        else
          current_scope
        end
      end

      # The String table too: `s[0] ||= "x"; s.delete_prefix!("x")` leaves `s[0]` nil.
      def mutator?(method_name)
        MutationWidening::SHAPE_MUTATORS.include?(method_name)
      end

      def invalidate_indexed_write(call_node, current_scope)
        args = call_node.arguments&.arguments
        return current_scope if args.nil? || args.empty?

        address = stable_address(call_node.receiver, args.first)
        return current_scope if address.nil?

        current_scope.without_indexed_narrowing(*address)
      end

      def invalidate_mutator(call_node, current_scope)
        receiver = stable_receiver(call_node.receiver)
        return widen_mutated_slot(call_node, current_scope) if receiver.nil?

        current_scope.without_indexed_narrowings_for(*receiver)
      end

      # A mutator whose receiver is the element a `(receiver, key)` narrowing records — `h[k] << x`,
      # `h[k][:x] = v`, or `(h[k] ||= []) << x`, whose value is that element — changes the object the
      # narrowing holds, so the narrowing is widened as the mutator widens that value, or dropped when the
      # widening declines.
      # Without it `groups[:a] ||= []; groups[:a] << 1` kept reading `groups[:a]` as `[]` and folded
      # `groups[:a].size == 0`; issue #1223's threading of a receiver's write made the parenthesised spelling
      # record the same narrowing.
      def widen_mutated_slot(call_node, current_scope)
        address = element_address(call_node.receiver)
        return current_scope if address.nil?

        recorded = current_scope.indexed_narrowing(*address)
        return current_scope if recorded.nil?

        widened = MutationWidening.widen_for_mutator(recorded, call_node.name) ||
                  string_slot_floor(recorded, call_node.name)
        return current_scope.without_indexed_narrowing(*address) if widened.nil?

        current_scope.with_indexed_narrowing(*address, widened)
      end

      # A String mutator the widening declines on a String slot — a `String` nominal it may not grow, a refinement it
      # does not model — still leaves the same object in the slot, so the `||=` proof that the slot is non-nil stands.
      # The narrowing is kept, floored to `String` so no value or refinement pin outlives the rewrite. Dropping it read
      # `h[:name]` back as the declared `String?` after `h[:name].strip!` and reported a nil receiver on correct code.
      def string_slot_floor(recorded, method_name)
        return nil unless StringMutation::MUTATORS.include?(method_name)

        members = recorded.is_a?(Type::Union) ? recorded.members : [recorded]
        return nil unless members.all? { |member| UnknownStoreWidening.carrier_class(member) == "String" }

        Type::Combinator.nominal_of("String")
      end

      ELEMENT_WRITE_NODES = [Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode].freeze
      private_constant :ELEMENT_WRITE_NODES

      # The `(receiver, key)` address of a single-key element read `h[k]`, or of an index compound write
      # (`h[k] ||= v`) whose value is that element, bare or parenthesised on its own; nil otherwise.
      def element_address(node)
        while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1
          node = node.body.body.first
        end
        return nil unless (node.is_a?(Prism::CallNode) && node.name == :[] && node.block.nil?) ||
                          ELEMENT_WRITE_NODES.include?(node.class)

        args = node.arguments&.arguments
        args&.size == 1 ? stable_address(node.receiver, args.first) : nil
      end

      # Companion invalidator for single-hop method-chain narrowings (ROADMAP § Future cycles —
      # "Method-call receiver narrowing across stable receivers", B2 from the slice's design
      # notes). Drops every `(receiver, *)` chain narrowing rooted at the call's OUTER stable
      # receiver — matching the ROADMAP's "any intervening method call against the same
      # receiver" criterion. A call against `x.last` (the OUTER receiver is a `CallNode`, not a
      # stable root) does NOT drop narrowings keyed on `x`, so the worked-site `x.last << y`
      # pattern correctly preserves the chain narrowing for any further `x.last` read in the same
      # body. Always-safe (only forgets; never invents).
      def invalidate_chain_after_call(call_node:, current_scope:)
        return current_scope unless call_node.is_a?(Prism::CallNode)

        receiver = stable_receiver(call_node.receiver)
        return current_scope if receiver.nil?

        current_scope.without_method_chain_narrowings_for(*receiver)
      end

      # Issue #1703 — the key half of a key-presence guard's address when the key is not a literal: a local, an
      # instance variable, or a no-argument, no-block call chain rooted at one (`prop.column_type`). `path` is
      # `[[root_kind, root_name], method, …]`, so two spellings of the same chain compare equal. The chain's own
      # calls are taken to be side-effect-free readers, the bet the method-chain narrowing already makes.
      KeyExpr = Data.define(:path) do
        def root = path.first

        # Whether `other` (another chain) reads a prefix of this one — `prop` or `prop.column_type` for
        # `prop.column_type` — so evaluating it is part of re-reading this key rather than an intervening call.
        def prefixed_by?(other) = path.first(other.path.size) == other.path
      end

      # What a key-presence guard stores at its address. The fact is the entry's presence on every joined arm; the
      # read recomputes its type from the receiver ({.key_guarded_read}), so the stored value carries nothing.
      KEY_GUARD_PRESENT = Type::Combinator.constant_of(true)
      private_constant :KEY_GUARD_PRESENT

      # A reader's name: not an operator (`!`, `-@`, `[]`) and not a writer (`x=`) or bang method.
      READER_NAME = /\A[a-z_][A-Za-z0-9_]*\??\z/
      private_constant :READER_NAME

      # The {KeyExpr} for `node`, or nil when it is not a local / ivar read or a no-argument, no-block,
      # non-safe-navigation reader chain rooted at one. A literal key is the shape path's business and answers nil.
      def key_expr(node)
        case node
        when Prism::LocalVariableReadNode then KeyExpr.new(path: [[:local, node.name]].freeze)
        when Prism::InstanceVariableReadNode then KeyExpr.new(path: [[:ivar, node.name]].freeze)
        when Prism::CallNode
          return nil unless node.block.nil? && node.arguments.nil? && !node.safe_navigation?
          return nil unless READER_NAME.match?(node.name.to_s)

          inner = node.receiver && key_expr(node.receiver)
          inner && KeyExpr.new(path: (inner.path + [node.name]).freeze)
        end
      end

      # The receiver half of a key-presence guard's address: a local, an instance variable or a constant read.
      def key_guard_receiver(node)
        stable_receiver(node) || (node.is_a?(Prism::ConstantReadNode) ? [:const, node.name] : nil)
      end

      # `[receiver_kind, receiver_name, KeyExpr]` for `receiver[key]` / `receiver.key?(key)`, or nil.
      def key_guard_address(receiver_node, key_node)
        receiver = key_guard_receiver(receiver_node)
        return nil if receiver.nil?

        key = key_expr(key_node)
        key && [receiver.first, receiver.last, key]
      end

      # Whether `type` is a receiver whose computed-key read a key-presence guard can sharpen: a closed, non-empty
      # hash shape (or a union of them), the carrier whose read by a non-literal key answers every value plus the
      # miss `nil` (`ShapeDispatch#hash_dig_step`). Anything else — an RBS `Hash[K, V]`, whose read is already
      # nil-free, an open shape, a user class answering `key?` — is left alone.
      def key_guard_receiver_type?(type)
        members = type.is_a?(Type::Union) ? type.members : [type]
        members.all? { |member| member.is_a?(Type::HashShape) && member.closed? && !member.pairs.empty? }
      end

      # The truthy edge of `receiver.key?(key)` with a non-literal key: `scope` with the guard recorded, or nil when
      # the receiver, key or receiver type is not one this narrowing addresses.
      def record_key_guard(call_node, scope)
        args = call_node.arguments&.arguments
        return nil unless args&.size == 1

        address = key_guard_address(call_node.receiver, args.first)
        return nil if address.nil?
        return nil unless key_guard_receiver_type?(scope.type_of(call_node.receiver))

        scope.with_indexed_narrowing(*address, KEY_GUARD_PRESENT)
      end

      # The type of the read `node` (`receiver[key]`) given `type`, its un-narrowed answer, when a key-presence guard
      # on the same receiver and structurally the same key holds in `scope`: the miss `nil` is dropped. The read
      # cannot tell a miss `nil` from a value's own, so it drops `nil` only when no value of the receiver can be
      # `nil`. Nil when no guard applies or nothing would change.
      def key_guarded_read(node, type, scope)
        return nil unless key_guarded?(node, scope)

        receiver_type = scope.type_of(node.receiver)
        return nil unless key_guard_receiver_type?(receiver_type)

        shapes = receiver_type.is_a?(Type::Union) ? receiver_type.members : [receiver_type]
        return nil if shapes.any? { |shape| shape.pairs.each_value.any? { |value| value_may_be_nil?(value) } }

        narrowed = Narrowing.narrow_non_nil(type)
        narrowed == type || narrowed.is_a?(Type::Bot) ? nil : narrowed
      end

      # Whether `node` is a single-key, blockless `[]` read whose address a key-presence guard in `scope` holds.
      def key_guarded?(node, scope)
        return false unless node.is_a?(Prism::CallNode) && node.name == :[] && node.block.nil?

        args = node.arguments&.arguments
        address = args&.size == 1 ? key_guard_address(node.receiver, args.first) : nil
        !address.nil? && !scope.indexed_narrowing(*address).nil?
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

      # Drops the key-presence guards `call_node` may break. Always-safe (only forgets; never invents).
      #
      # - A `[]=` or a mutator against the guarded receiver: the slot may now hold another value, or the key may be
      #   gone (`delete`, `clear`, `compare_by_identity`, …).
      # - A call whose receiver chain is rooted at a key's root variable (`prop.reload`, `prop.column_type = x`,
      #   `prop.owner.touch`), unless it is the key chain itself or a prefix of it: the any-call-against-the-root
      #   rule the method-chain narrowing applies, carried to every depth of the chain.
      # - A call on `self` (implicit or explicit) for a guard that involves an instance variable, which such a call
      #   may rebind or mutate.
      def invalidate_key_guards_after_call(call_node:, current_scope:)
        return current_scope unless call_node.is_a?(Prism::CallNode)

        doomed = current_scope.indexed_narrowings.each_key.select do |guard|
          guard.key.is_a?(KeyExpr) && breaks_key_guard?(call_node, guard)
        end
        doomed.each_with_object([current_scope]) do |guard, acc|
          acc[0] = acc[0].without_indexed_narrowing(guard.receiver_kind, guard.receiver_name, guard.key)
        end.first
      end

      def breaks_key_guard?(call_node, guard)
        receiver = call_node.receiver
        if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          return guard.receiver_kind == :ivar || guard.key.root.first == :ivar
        end

        writes_guarded_receiver?(call_node, guard) || touches_key_root?(call_node, guard.key)
      end

      def writes_guarded_receiver?(call_node, guard)
        return false unless call_node.name == :[]= || mutator?(call_node.name)

        key_guard_receiver(call_node.receiver) == [guard.receiver_kind, guard.receiver_name]
      end

      def touches_key_root?(call_node, key)
        return false unless chain_root(call_node.receiver) == key.root

        own = key_expr(call_node)
        own.nil? || !key.prefixed_by?(own)
      end

      # The `[kind, name]` of the local / ivar a receiver chain (`a.b.c`, `a[0].b`) starts from, or nil.
      def chain_root(node)
        node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver
        stable_receiver(node)
      end
    end
  end
end
