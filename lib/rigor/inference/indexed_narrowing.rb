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
    end
  end
end
