# frozen_string_literal: true

module Rigor
  module Type
    # Routes `accepts` through the engine's acceptance dispatcher.
    #
    # Every carrier's acceptance check is the same fixed forwarding on `self` —
    # `Inference::Acceptance.accepts(self, other, mode: mode)` — so it lived as an identical copy in
    # fourteen carriers. The one exception is `Type::App`, which forwards on its reduced `bound` type rather
    # than `self`; it keeps its own `accepts` and does not include this.
    module AcceptanceRouter
      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end
    end
  end
end
