# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Complex` catalog. Singleton — load once, consult during
      # dispatch.
      #
      # `Complex` is a fully-immutable value type in Ruby: once a
      # complex number is constructed (via `Complex(real, imag)` or
      # `Complex.rect` / `Complex.polar`) its `real` and `imag` slots
      # are never rewritten. Every public instance method either
      # returns `self` unchanged or builds a fresh `Complex` /
      # `Numeric`. The C-body classifier already correctly flags the
      # four `:dispatch` methods (`<=>`, `to_s`, `inspect`,
      # `rationalize`) so there are no false-positive `:leaf`
      # entries to override. The blocklist therefore carries only
      # the conventional `:initialize_copy` defence-in-depth entry
      # so a hypothetical future `Constant<Complex>` carrier cannot
      # fold an aliasing copy through the catalog (mirrors
      # `range_catalog.rb`, `time_catalog.rb`, `date_catalog.rb`).
      COMPLEX_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/complex.yml",
          __dir__
        ),
        mutating_selectors: {
          "Complex" => Set[
            # Defence in depth: `Complex` does not currently expose
            # a public `initialize_copy`, but blocking it keeps the
            # convention identical to every other catalog so future
            # CRuby additions cannot leak a copy-mutator through.
            :initialize_copy
          ]
        }
      )
    end
  end
end
