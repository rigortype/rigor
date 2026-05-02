# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Hash` catalog. Singleton — load once, consult during dispatch.
      #
      # Hash mirrors Array's mutation pattern: nearly every iteration
      # method yields through `rb_hash_foreach` plus a per-pair static
      # callback (`each_value_i`, `keep_if_i`, …), and the C-body
      # classifier does not follow into the callback so it lands as
      # `:leaf` despite being block-dependent. The blocklist below
      # captures every false-positive `:leaf` we have spotted in the
      # generated YAML — bias toward conservatism so a missed fold is
      # acceptable but a folded mutator/yielder is not.
      HASH_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/hash.yml",
          __dir__
        ),
        mutating_selectors: {
          "Hash" => Set[
            # Block-dependent iteration — yields via `rb_hash_foreach`
            # plus a per-pair callback that the regex classifier does
            # not follow:
            :each, :each_pair, :each_key, :each_value,
            :select, :filter, :reject,
            :transform_values,
            # Block-dependent merge — `rb_hash_merge` delegates into
            # `rb_hash_update`, which yields per conflict when a block
            # is given:
            :merge
          ]
        }
      )
    end
  end
end
