# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Rational` catalog. Singleton — load once, consult during
      # dispatch.
      #
      # Rational is fully immutable: numerator / denominator slots
      # are written once during `nurat_s_new_internal` and the C
      # body never reaches for `rb_check_frozen`. Every catalog
      # entry classifies cleanly (`:leaf`, `:leaf_when_numeric`,
      # or `:dispatch` for the two methods that delegate into
      # user-redefinable `==` / `Float()` — `nurat_eqeq_p` and
      # `nurat_fdiv`). Bang-suffixed mutators do not exist on
      # Rational.
      #
      # The blocklist therefore stays minimal. `initialize_copy`
      # is added defensively (mirrors Range / Set) so a
      # hypothetical future `Constant<Rational>` carrier cannot
      # fold an aliasing copy through the catalog and surface a
      # shared mutable handle.
      RATIONAL_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/rational.yml",
          __dir__
        ),
        mutating_selectors: {
          "Rational" => Set[
            :initialize_copy
          ]
        }
      )
    end
  end
end
