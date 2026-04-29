# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Slice 5 phase 2 shape-aware dispatch tier. Sits between
      # {ConstantFolding} (which folds Constant-on-Constant arithmetic)
      # and {RbsDispatch} (which projects shape carriers to their
      # underlying nominal and resolves return types through RBS).
      #
      # The tier resolves a curated catalogue of element-access
      # methods on `Rigor::Type::Tuple` and `Rigor::Type::HashShape`
      # receivers, returning the *precise* member type rather than the
      # projected `Array#[]` / `Hash#fetch` result. When the dispatch
      # cannot prove which element will be returned (non-static key,
      # out-of-range index, multi-arg `dig`, ...) the tier returns
      # `nil` so the surrounding pipeline falls through to
      # {RbsDispatch} and the projection-based answer.
      #
      # Catalogue (Slice 5 phase 2 sub-phase 1):
      #
      # - Tuple#`first`, Tuple#`last`, Tuple#`size`/`length`/`count`:
      #   no-arg, no-block.
      # - Tuple#`[]`, Tuple#`fetch` with a single `Constant[Integer]`
      #   argument inside the tuple's bounds (negative indices are
      #   normalised by length).
      # - HashShape#`size`/`length`: no-arg.
      # - HashShape#`[]`, HashShape#`fetch`, HashShape#`dig` with a
      #   single `Constant[Symbol|String]` argument matching one of
      #   the declared keys. `[]` and `dig` resolve missing keys to
      #   `Constant[nil]`; `fetch` (no default, no block) falls through
      #   on a miss because Ruby would raise `KeyError` and the
      #   analyzer prefers the conservative projection answer.
      #
      # Methods that this tier does NOT yet handle (they fall through):
      #
      # - Iteration methods that bind block parameters (`each`, `map`,
      #   `select`, ...). Those land alongside the BlockNode-aware
      #   scope builder.
      # - Range and start-length forms of `[]` (`tuple[1, 2]`,
      #   `tuple[1..3]`).
      # - Multi-arg `dig` (`tuple.dig(0, :k)` / `shape.dig(:a, :b)`),
      #   destructuring assignment (`a, b = tuple`), and the
      #   Rigor-extension hash-shape policies.
      #
      # See docs/internal-spec/inference-engine.md (Slice 5 phase 2)
      # and docs/adr/4-type-inference-engine.md for the slice
      # rationale.
      module ShapeDispatch
        module_function

        TUPLE_HANDLERS = {
          first: :tuple_first,
          last: :tuple_last,
          size: :tuple_size,
          length: :tuple_size,
          count: :tuple_size,
          :[] => :tuple_index,
          fetch: :tuple_index
        }.freeze

        HASH_SHAPE_HANDLERS = {
          size: :hash_size,
          length: :hash_size,
          :[] => :hash_lookup,
          fetch: :hash_lookup,
          dig: :hash_lookup
        }.freeze

        # @return [Rigor::Type, nil] the precise element/value type, or
        #   `nil` to defer to the next dispatcher tier.
        def try_dispatch(receiver:, method_name:, args:)
          args ||= []
          case receiver
          when Type::Tuple then dispatch_tuple(receiver, method_name, args)
          when Type::HashShape then dispatch_hash_shape(receiver, method_name, args)
          end
        end

        class << self
          private

          def dispatch_tuple(tuple, method_name, args)
            handler = TUPLE_HANDLERS[method_name]
            return nil unless handler

            send(handler, tuple, method_name, args)
          end

          def dispatch_hash_shape(shape, method_name, args)
            handler = HASH_SHAPE_HANDLERS[method_name]
            return nil unless handler

            send(handler, shape, method_name, args)
          end

          def tuple_first(tuple, _method_name, args)
            return nil unless args.empty?
            return Type::Combinator.constant_of(nil) if tuple.elements.empty?

            tuple.elements.first
          end

          def tuple_last(tuple, _method_name, args)
            return nil unless args.empty?
            return Type::Combinator.constant_of(nil) if tuple.elements.empty?

            tuple.elements.last
          end

          def tuple_size(tuple, _method_name, args)
            return nil unless args.empty?

            Type::Combinator.constant_of(tuple.elements.size)
          end

          # `tuple[i]` and `tuple.fetch(i)` for a known integer index.
          # Out-of-range indices return nil (`tuple[100]` -> nil at
          # runtime, `tuple.fetch(100)` raises) so we let the projection
          # answer apply rather than manufacturing a value.
          def tuple_index(tuple, _method_name, args)
            return nil unless args.size == 1

            arg = args.first
            return nil unless arg.is_a?(Type::Constant)
            return nil unless arg.value.is_a?(Integer)

            idx = normalise_index(arg.value, tuple.elements.size)
            return nil unless idx

            tuple.elements[idx]
          end

          # Returns the in-bounds non-negative index, or nil when the
          # raw index falls outside `[-size, size)`.
          def normalise_index(raw, size)
            adjusted = raw.negative? ? raw + size : raw
            return nil if adjusted.negative? || adjusted >= size

            adjusted
          end

          def hash_size(shape, _method_name, args)
            return nil unless args.empty?

            Type::Combinator.constant_of(shape.pairs.size)
          end

          # `shape[k]`, `shape.fetch(k)`, `shape.dig(k)` for a static
          # symbol/string key. Missing-key resolution depends on the
          # method:
          #
          # - `[]` and `dig` return `nil` at runtime; we surface
          #   `Constant[nil]` so the carrier is visible to downstream
          #   narrowing.
          # - `fetch` (no default, no block) raises `KeyError`; we let
          #   the projection answer apply because the runtime would
          #   not produce a value.
          def hash_lookup(shape, method_name, args)
            return nil unless args.size == 1

            arg = args.first
            return nil unless arg.is_a?(Type::Constant)

            key = arg.value
            return nil unless key.is_a?(Symbol) || key.is_a?(String)

            return shape.pairs[key] if shape.pairs.key?(key)

            return Type::Combinator.constant_of(nil) if %i[[] dig].include?(method_name)

            nil
          end
        end
      end
    end
  end
end
