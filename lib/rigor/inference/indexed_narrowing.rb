# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "mutation_widening"

module Rigor
  module Inference
    # Closes the "`params[:f] ||= []; params[:f] << x`" precision
    # gap surfaced by the Redmine 6.1.2 `Query#as_params` survey
    # (ROADMAP § Future cycles / Type-language / engine —
    # "Indexed-collection narrowing through `Hash[k] ||= default`").
    #
    # After `receiver[key] ||= default` the next read at
    # `receiver[key]` is known non-nil, but Rigor types each
    # `Hash#[]` independently and the subsequent `<<` / `[]=` /
    # other mutator dispatches against the un-narrowed result —
    # which on a `HashShape{}` carrier folds to `Constant[nil]`.
    #
    # This module is the address-recogniser + invalidator shared
    # by {Inference::StatementEvaluator}'s `eval_index_or_write`
    # handler (which RECORDS the narrowing) and `eval_call`
    # (which INVALIDATES on intervening writes / mutators) and
    # by {Inference::ExpressionTyper}'s `call_type_for` (which
    # CONSUMES the narrowing when typing a follow-up `[]` read).
    #
    # **Stable receivers.** A receiver is "stable" iff it is a
    # `LocalVariableReadNode` or `InstanceVariableReadNode`.
    # Method-call chains (`foo.bar[:k]`) and other shapes are
    # rejected because a follow-up read against an identical-
    # looking AST chain has no guarantee of resolving to the
    # same runtime value — narrowing it would invent a fact.
    #
    # **Stable keys.** A key is "stable" iff it is a literal
    # `SymbolNode` / `StringNode` / `IntegerNode`. Local-variable
    # keys (`params[field]`) are excluded for the same
    # invent-a-fact reason: the local could be rebound between
    # the `||=` and the read.
    #
    # **Invalidation.** Three conditions drop a recorded
    # narrowing:
    # - The receiver variable is rebound (handled inside
    #   `Scope#with_local` / `Scope#with_ivar`).
    # - An intervening `receiver[key] = value` writes the same
    #   slot — `:[]=` could rebind the slot to nil; conservative
    #   drop.
    # - An intervening mutator from {MutationWidening::HASH_MUTATORS}
    #   or {MutationWidening::ARRAY_MUTATORS} runs against the
    #   receiver (e.g. `params.delete(:f)`, `params.clear`).
    #
    # All three are implemented in `StatementEvaluator#eval_call`'s
    # post-dispatch path through {.invalidate_after_call}.
    module IndexedNarrowing
      # Literal Prism nodes whose Ruby value the analyzer trusts
      # as a stable address. Symbol / String are the dominant
      # Hash key shapes; Integer covers numerically-keyed Hashes
      # and Array indices.
      STABLE_KEY_NODES = [Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode].freeze

      module_function

      # Returns `[receiver_kind, receiver_name]` when `node` is a
      # `LocalVariableReadNode` or `InstanceVariableReadNode`,
      # otherwise nil.
      def stable_receiver(node)
        case node
        when Prism::LocalVariableReadNode then [:local, node.name]
        when Prism::InstanceVariableReadNode then [:ivar, node.name]
        end
      end

      # Returns the literal Ruby value when `node` is a stable
      # key shape, otherwise nil. Symbols → `Symbol`,
      # Strings → `String` (unescaped), Integers → `Integer`.
      def stable_key(node)
        case node
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::StringNode then node.unescaped
        when Prism::IntegerNode then node.value
        end
      end

      # Returns `[receiver_kind, receiver_name, key]` when the
      # CallNode is a `receiver[key]` read or write whose
      # receiver and key are both stable, otherwise nil. Used
      # by both the recorder (for `IndexOrWriteNode`'s
      # receiver/arguments triplet) and the invalidator (for
      # `CallNode :[]=` / mutator calls). Treats only the FIRST
      # argument as the key; `:[]=`'s second argument is the
      # rvalue and is not part of the address.
      def stable_address(receiver_node, key_node)
        receiver = stable_receiver(receiver_node)
        return nil if receiver.nil?

        key = stable_key(key_node)
        return nil if key.nil?

        [receiver.first, receiver.last, key]
      end

      # Looks up a recorded narrowing for `receiver[key]` against
      # `scope`, returning the narrowed type or nil when no
      # entry applies. Used by ExpressionTyper's `[]` dispatch
      # to refine the result of a stable indexed read.
      def lookup_for_call(node, scope)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.name == :[]
        return nil if node.arguments.nil?
        return nil unless node.arguments.arguments.size == 1

        address = stable_address(node.receiver, node.arguments.arguments.first)
        return nil if address.nil?

        scope.indexed_narrowing(*address)
      end

      # Removes recorded narrowings invalidated by `call_node`.
      # Two patterns:
      #
      # - `receiver[key] = value` (a `:[]=` against a stable
      #   address): drop the specific `(receiver, key)` entry.
      # - Any mutator from `HASH_MUTATORS` / `ARRAY_MUTATORS`
      #   against a stable receiver: drop EVERY entry rooted
      #   at that receiver, because the mutator could rebind
      #   any slot.
      #
      # Returns the updated scope. Always-safe (only forgets;
      # never invents).
      def invalidate_after_call(call_node:, current_scope:)
        return current_scope unless call_node.is_a?(Prism::CallNode)

        if call_node.name == :[]=
          invalidate_indexed_write(call_node, current_scope)
        elsif mutator?(call_node.name)
          invalidate_mutator(call_node, current_scope)
        else
          current_scope
        end
      end

      def mutator?(method_name)
        MutationWidening::HASH_MUTATORS.include?(method_name) ||
          MutationWidening::ARRAY_MUTATORS.include?(method_name)
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
        return current_scope if receiver.nil?

        current_scope.without_indexed_narrowings_for(*receiver)
      end
    end
  end
end
