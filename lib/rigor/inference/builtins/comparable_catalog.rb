# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Comparable` module catalog. Singleton — load once.
      #
      # `Comparable` is a Ruby module, not a class, so the
      # catalog is NOT routed through
      # `MethodDispatcher::ConstantFolding::CATALOG_BY_CLASS`
      # (which dispatches on the receiver's concrete class).
      # The data is consumed by future include-aware lookup —
      # see `docs/CURRENT_WORK.md` for the planned slice.
      COMPARABLE_CATALOG = MethodCatalog.for_topic(
        "comparable",
        mutating_selectors: {
          "Comparable" => Set[]
        }
      )
    end
  end
end
