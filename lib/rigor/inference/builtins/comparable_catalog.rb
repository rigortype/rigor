# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Comparable` module catalog. Singleton — load once.
      #
      # `Comparable` is a Ruby module, not a class, so the catalog is NOT routed through
      # `MethodDispatcher::ConstantFolding::CATALOG_BY_CLASS` (which dispatches on the receiver's concrete
      # class). The data is wired into `MODULE_CATALOGS` in `MethodDispatcher::ConstantFolding`
      # (ancestor-chain lookup).
      COMPARABLE_CATALOG = MethodCatalog.for_topic(
        "comparable",
        mutating_selectors: {
          "Comparable" => Set[]
        }
      )
    end
  end
end
