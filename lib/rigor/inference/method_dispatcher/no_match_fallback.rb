# frozen_string_literal: true

module Rigor
  module Inference
    module MethodDispatcher
      module OverloadSelector
        module_function

        # The overload a call answers when no selection pass matched it. A call with a block, on a method that
        # declares a block overload, reads the block overloads (`block_call_fallback`, #2429) unless `block_fallback`
        # is false. Otherwise prefer an overload that does not REQUIRE a block over `overloads.first`: methods like
        # `Array#filter` / `Enumerable#map` declare the block-bearing overload first (`() { ... } -> Array[Elem]`)
        # and the bare-call overload second (`() -> Enumerator[...]`), and a no-block `[1, 2].filter` yields an
        # `Enumerator`.
        def no_match_fallback(overloads, shared, block_fallback)
          if block_fallback && shared[:block_required] && overloads.any? { |mt| overload_has_block?(mt) }
            return block_call_fallback(overloads, shared)
          end

          [overloads.find { |mt| !overload_requires_block?(mt) } || overloads.first]
        end

        class << self
          private

          # Issue #2429 — the block-less arm's return is what the method answers without a block, so
          # `URI.open(url, read_timeout: 3) { |io| }` read `StringIO | Tempfile` instead of the block's value. The
          # answer is the block overload whose positional arity admits the call when only one does, or the one every
          # such overload agrees on; otherwise none (`[]`, which the return path reads as `Dynamic[top]`).
          # `[3, 1, 2].max_by(2.0) { }` takes `(Integer n) { } -> Array[Elem]`, not `() { } -> Elem?`, and overloads of
          # differing returns that all admit the call are not decided by position.
          def block_call_fallback(overloads, shared)
            admitted = overloads.select { |mt| overload_has_block?(mt) && arity_admits?(mt, shared) }
            return [] if admitted.empty?

            admitted.map { |mt| mt.type.return_type }.uniq.size == 1 ? [admitted.first] : []
          end

          # The call's positional count (less a keyword hash the overload takes as keywords) fits `method_type`'s
          # arity; a splat fits when some count of its elements does (#1801).
          def arity_admits?(method_type, shared)
            fun = method_type.type
            arg_types = KeywordArguments.selection_positional(method_type, shared)
            splats = shared[:splats]
            return arity_compatible?(fun, arg_types.size) unless splats

            lists = SplatArity.expansions(fun, arg_types, splats)
            lists.nil? || lists.any? { |list| arity_compatible?(fun, list.size) }
          end
        end
      end
    end
  end
end
