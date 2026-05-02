# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Enumerable` module catalog. Singleton — load once.
      #
      # `Enumerable` is a Ruby module, not a class, so the
      # catalog is NOT routed through
      # `MethodDispatcher::ConstantFolding::CATALOG_BY_CLASS`
      # (which dispatches on the receiver's concrete class).
      # The data is consumed by future include-aware lookup —
      # see `docs/CURRENT_WORK.md` for the planned slice.
      ENUMERABLE_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/enumerable.yml",
          __dir__
        ),
        mutating_selectors: {
          "Enumerable" => Set[]
        }
      )
    end
  end
end
