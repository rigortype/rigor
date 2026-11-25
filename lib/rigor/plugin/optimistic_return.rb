# frozen_string_literal: true

module Rigor
  module Plugin
    # Issue #3322 — a `dynamic_return` answer whose nil-freeness is the plugin's bet rather than a property of the
    # value. A plugin returns one through {Base#optimistic_nil_free} when the honest type is `T | nil` but
    # contributing the `nil` would report `call.possible-nil-receiver` on the idiom every caller writes:
    # rigor-activerecord's reader of a column the schema does not declare `null: false` answers `Time`, not
    # `Time | nil`. The engine types the call as `type` and records an {Inference::OptimisticOrigin} mark on it, so
    # the certainty consumers (`flow.always-truthy-condition`, the `&&` / `||` dead-operand gate, branch elision)
    # decline to conclude from it exactly as they do for `Hash#[]` — `if record.completed_at.present?` stays live.
    #
    # The wrapper never reaches a type position: `Base#dynamic_return_type` unwraps it, and only the engine's own
    # contribution tier reads the flag (`Base#dynamic_return_answer`).
    OptimisticReturn = Data.define(:type) do
      # The bare type of a `dynamic_return` answer, wrapped or not.
      def self.unwrap(answer) = answer.is_a?(OptimisticReturn) ? answer.type : answer
    end
  end
end
