# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Pathname` catalog. Singleton — load once, consult during
      # dispatch.
      #
      # TODO(blocklist curation): read
      # `data/builtins/ruby_core/pathname.yml` and add per-method
      # blocklist entries for any `:leaf` classifications that are
      # actually mutators or otherwise unsafe to fold. Each entry
      # SHOULD carry a one-line comment naming the indirect mutator
      # helper that triggered the false positive (see
      # `string_catalog.rb`, `array_catalog.rb`, `time_catalog.rb`
      # for the canonical shape).
      PATHNAME_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/pathname.yml",
          __dir__
        ),
        mutating_selectors: {
          "Pathname" => Set[
          # initialize_copy is blocklisted by convention so a
          # hypothetical future `Constant<Pathname>` carrier
          # cannot fold an aliasing copy through the catalog.
          :initialize_copy
          ]
        }
      )
    end
  end
end
