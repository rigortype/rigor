# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Array` catalog. Singleton — load once, consult during dispatch.
      #
      # Array has more mutation surface than String: every method that
      # logically reshapes the array tends to call `rb_ary_modify` or
      # an internal helper (`ary_replace`, `ary_resize`, `ary_pop`,
      # `ary_push_internal`, …) that the classifier does not yet
      # recognise. The blocklist captures the methods we have
      # specifically observed flowing as `:leaf` despite mutating.
      ARRAY_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/array.yml",
          __dir__
        ),
        mutating_selectors: {
          "Array" => Set[
            # Mutators classified `:leaf` by the C-body heuristic
            :<<, :push, :replace, :clear, :concat, :insert, :"[]=",
            :unshift, :prepend, :pop, :shift, :delete_at, :slice!,
            :compact!, :flatten!, :uniq!, :sort!, :reverse!,
            :rotate!, :keep_if, :delete_if, :select!, :filter!,
            :reject!, :collect!, :map!, :assoc, :rassoc,
            :fill, :delete, :transpose,
            # Methods that yield (block-dependent) — classifier
            # may mark them leaf when the block call is gated:
            :each, :each_with_index, :each_index, :each_slice,
            :each_cons, :each_with_object,
            # Identity/comparison methods that take a block too
            :max, :min, :max_by, :min_by, :minmax, :minmax_by,
            :sort_by, :group_by, :partition, :all?, :any?, :none?,
            :one?, :find, :detect, :find_all, :find_index,
            :reduce, :inject, :flat_map, :collect_concat,
            :zip, :product, :combination, :permutation,
            :chunk_while, :slice_when, :tally
          ]
        }
      )
    end
  end
end
