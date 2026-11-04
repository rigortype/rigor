# frozen_string_literal: true

module Rigor
  module Analysis
    module CheckRules
      # Issue #2786 — what the per-call-node rules ({CheckRules.call_node_diagnostics}) each derived on their own:
      # the call node's index scope, the type of its receiver under that scope, and the RBS signature the call
      # resolves to on that receiver. One object per call node is built before the rules run and handed to every
      # rule that reads them.
      #
      # The receiver type is computed lazily, on the first rule that asks, from the same `(scope, node)` pair each
      # rule typed before: `scope_index[call_node]` and `call_node.receiver`. Every later rule reads that value
      # instead of re-typing the receiver chain. This is not a memo over `type_of`: nothing is served across call
      # nodes or across scopes, and no fact is computed anywhere but at the first point a rule computed it before.
      # It rests on the `Scope#type_of` contract that one `(scope, node)` pair types structurally equal within a
      # run (`docs/internal-spec/inference-engine.md`).
      #
      # Of the typing, only the receiver is shared. A rule that types a sub-expression (`receiver.receiver`), an
      # argument, or any node under a scope other than the call's keeps its own `type_of` call: arguments are typed
      # from their own index entry by `call.argument-type-mismatch` and from the call's by `flow.always-raises`, and
      # the two meet only on a divisor.
      class CallFacts
        attr_reader :call_node, :scope_index, :scope

        def initialize(call_node, scope_index)
          @call_node = call_node
          @scope_index = scope_index
          @scope = scope_index[call_node]
          @receiver_type = nil
          @receiver_signature = nil
          @receiver_signature_resolved = false
        end

        # `scope.type_of(call_node.receiver)`, computed once. Callers check that the call has a receiver and that
        # {#scope} is not nil first, as they did before sharing it.
        def receiver_type
          @receiver_type ||= @scope.type_of(@call_node.receiver)
        end

        # The signature `CheckRules.receiver_signature` resolves, its block run on the first ask only. A nil answer
        # is remembered too. A block that raises leaves it unresolved, so the next ask raises as it did before.
        def receiver_signature
          return @receiver_signature if @receiver_signature_resolved

          signature = yield
          @receiver_signature_resolved = true
          @receiver_signature = signature
        end
      end
    end
  end
end
