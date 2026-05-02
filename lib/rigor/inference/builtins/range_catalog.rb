# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Range` catalog. Singleton — load once, consult during
      # dispatch.
      #
      # Range is largely immutable: `begin`, `end`, and `excl` are
      # set at construction by `range_initialize` and never mutated
      # afterwards. The blocklist below therefore stays small. The
      # entries we DO need are the iteration methods whose C body
      # routes through a helper the block/yield regex does not
      # recognise, so the classifier mis-flags them as `:leaf`
      # despite yielding to a block.
      RANGE_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/range.yml",
          __dir__
        ),
        mutating_selectors: {
          "Range" => Set[
            # `range_initialize` / `range_initialize_copy` write
            # `begin`/`end`/`excl` slots on the receiver; classed
            # `:leaf` because the writes go through the struct
            # accessor not `rb_check_frozen`. Blocked for symmetry
            # with String / Array.
            :initialize, :initialize_copy,
            # `range_reverse_each` yields to its block via
            # `range_each_func` -> caller's block; the regex
            # classifier follows direct `rb_yield*` calls only.
            :reverse_each,
            # `range_percent_step` returns an Enumerator unless a
            # block is supplied, in which case it yields. Treated
            # as block-dependent so the fold tier never invokes it
            # against a literal Range and tries to materialise an
            # Enumerator into a Constant.
            :%
          ]
        }
      )
    end
  end
end
