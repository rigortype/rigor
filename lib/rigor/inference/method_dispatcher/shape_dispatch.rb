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
      # Catalogue (Slice 5 phase 2):
      #
      # - Tuple#`first`, Tuple#`last`, Tuple#`size`/`length`/`count`:
      #   no-arg, no-block.
      # - Tuple#`[]`, Tuple#`fetch` with a single `Constant[Integer]`
      #   argument inside the tuple's bounds (negative indices are
      #   normalised by length). Tuple#`[]` also handles static
      #   Range and start-length slices, returning a sliced Tuple or
      #   `Constant[nil]` for statically nil slices.
      # - Tuple#`dig` with a chain of `Constant[Integer]` /
      #   `Constant[Symbol|String]` arguments (Slice 5 phase 2 sub-
      #   phase 2). Each step recurses through the resolved member; a
      #   missing key/index along the chain collapses to `Constant[nil]`
      #   so the carrier surfaces through downstream narrowing. A
      #   non-shape intermediate falls through to the projection
      #   answer.
      # - HashShape#`size`/`length`: no-arg.
      # - HashShape#`[]`, HashShape#`fetch`, HashShape#`dig` with a
      #   single `Constant[Symbol|String]` argument matching one of
      #   the declared keys. `[]` and `dig` resolve missing keys to
      #   `Constant[nil]`; `fetch` (no default, no block) falls through
      #   on a miss because Ruby would raise `KeyError` and the
      #   analyzer prefers the conservative projection answer.
      # - HashShape#`dig` with multi-arg chains (Slice 5 phase 2 sub-
      #   phase 2). Same chaining semantics as Tuple#`dig`.
      # - HashShape#`values_at` with a list of `Constant[Symbol|String]`
      #   arguments (Slice 5 phase 2 sub-phase 2). The result is a
      #   `Tuple` whose elements are the per-key values
      #   (`Constant[nil]` for missing keys, mirroring Ruby's runtime
      #   behaviour).
      #
      # Methods that this tier does NOT yet handle (they fall through):
      #
      # - Iteration methods that bind block parameters (`each`, `map`,
      #   `select`, ...). Those land alongside the BlockNode-aware
      #   scope builder.
      # - Tuple/HashShape mutation methods. These land with the future
      #   effect model so read-only entries and mutation invalidation
      #   have one place to report diagnostics.
      #
      # See docs/internal-spec/inference-engine.md (Slice 5 phase 2)
      # and docs/adr/4-type-inference-engine.md for the slice
      # rationale.
      # rubocop:disable Metrics/ClassLength, Metrics/ModuleLength
      module ShapeDispatch
        module_function

        TUPLE_HANDLERS = {
          first: :tuple_first,
          last: :tuple_last,
          size: :tuple_size,
          length: :tuple_size,
          count: :tuple_size,
          :[] => :tuple_index,
          fetch: :tuple_index,
          dig: :tuple_dig
        }.freeze

        HASH_SHAPE_HANDLERS = {
          size: :hash_size,
          length: :hash_size,
          :[] => :hash_lookup,
          fetch: :hash_lookup,
          dig: :hash_dig,
          values_at: :hash_values_at
        }.freeze

        # @return [Rigor::Type, nil] the precise element/value type, or
        #   `nil` to defer to the next dispatcher tier.
        def try_dispatch(receiver:, method_name:, args:)
          args ||= []
          case receiver
          when Type::Tuple then dispatch_tuple(receiver, method_name, args)
          when Type::HashShape then dispatch_hash_shape(receiver, method_name, args)
          when Type::Nominal then dispatch_nominal_size(receiver, method_name, args)
          when Type::Difference then dispatch_difference(receiver, method_name, args)
          end
        end

        # Tightens `Array#size` / `Array#length` / `String#length` /
        # `String#bytesize` / `Hash#size` etc. on a `Nominal` receiver
        # from the RBS-declared `Integer` to `non_negative_int`. The
        # tier ahead of RBS sees the more precise carrier so
        # downstream narrowing (`if size > 0; …`) actually has a
        # range to intersect with.
        SIZE_RETURNING_NOMINALS = {
          "Array" => %i[size length count],
          "String" => %i[length size bytesize],
          "Hash" => %i[size length count],
          "Set" => %i[size length count],
          "Range" => %i[size length count]
        }.freeze
        private_constant :SIZE_RETURNING_NOMINALS

        # When the difference removes the empty value of the
        # base type (`Constant[""]`, `Constant[0]`, an empty
        # Tuple, an empty HashShape), `size` / `length` /
        # `count` MUST be `positive-int` (the base's
        # non-negative range minus the removed point's `0`),
        # and `empty?` / `zero?` MUST be `Constant[false]`.
        EMPTY_REMOVAL_BASES = %w[String Array Hash Set].freeze
        private_constant :EMPTY_REMOVAL_BASES

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

          def dispatch_nominal_size(nominal, method_name, args)
            return nil unless args.empty?

            selectors = SIZE_RETURNING_NOMINALS[nominal.class_name]
            return nil unless selectors&.include?(method_name)

            Type::Combinator.non_negative_int
          end

          # Refinement-aware projections over a `Difference[base,
          # removed]` receiver. When the removed value is the
          # empty witness of the base (`Constant[""]` for
          # String, `Tuple[]` for Array, `HashShape{}` for Hash,
          # `Constant[0]` for Integer), the catalog tier knows:
          #
          #   ns.size                      # positive-int
          #   ns.size == 0                 # Constant[false]   (via narrowing tier)
          #   ns.empty?                    # Constant[false]
          #   nzi.zero?                    # Constant[false]
          #
          # For any other base method, the difference is opaque
          # to ShapeDispatch — we delegate to the base nominal
          # so the size/length tier still answers the broader
          # `non_negative_int` envelope where applicable.
          def dispatch_difference(difference, method_name, args)
            base = difference.base
            return nil unless base.is_a?(Type::Nominal)

            if removes_empty_witness?(difference)
              precise = empty_removal_projection(base, method_name, args)
              return precise if precise
            end

            dispatch_nominal_size(base, method_name, args)
          end

          EMPTY_WITNESS_PREDICATES = {
            "String" => ->(removed) { removed.is_a?(Type::Constant) && removed.value == "" },
            "Integer" => lambda { |removed|
              removed.is_a?(Type::Constant) && removed.value.is_a?(Integer) && removed.value.zero?
            },
            "Array" => ->(removed) { removed.is_a?(Type::Tuple) && removed.elements.empty? },
            "Hash" => ->(removed) { removed.is_a?(Type::HashShape) && removed.pairs.empty? }
          }.freeze
          private_constant :EMPTY_WITNESS_PREDICATES

          def removes_empty_witness?(difference)
            return false unless difference.base.is_a?(Type::Nominal)

            predicate = EMPTY_WITNESS_PREDICATES[difference.base.class_name]
            !!(predicate && predicate.call(difference.removed))
          end

          def empty_removal_projection(base, method_name, args)
            return nil unless args.empty?

            if %i[size length count bytesize].include?(method_name)
              return size_returning_for_empty_removal(base, method_name)
            end

            empty_predicate_projection(base, method_name)
          end

          def empty_predicate_projection(base, method_name)
            case method_name
            when :empty?
              base.class_name == "Integer" ? nil : Type::Combinator.constant_of(false)
            when :zero?
              base.class_name == "Integer" ? Type::Combinator.constant_of(false) : nil
            end
          end

          def size_returning_for_empty_removal(base, method_name)
            return nil if base.class_name == "Integer" # Integer has no size method on Difference

            selectors = SIZE_RETURNING_NOMINALS[base.class_name]
            return nil unless selectors&.include?(method_name)

            Type::Combinator.positive_int
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

          # `tuple[i]`, `tuple[range]`, `tuple[start, length]`, and
          # `tuple.fetch(i)` for static arguments. Out-of-range single
          # indices still fall through because the same handler serves
          # `fetch`, while statically nil slices can be represented
          # precisely for `[]`.
          def tuple_index(tuple, method_name, args)
            case args.size
            when 1 then tuple_single_index(tuple, method_name, args.first)
            when 2 then tuple_start_length_slice(tuple, method_name, args)
            end
          end

          def tuple_single_index(tuple, method_name, arg)
            return nil unless arg.is_a?(Type::Constant)

            return tuple_range_slice(tuple, arg.value) if method_name == :[] && arg.value.is_a?(Range)
            return nil unless arg.value.is_a?(Integer)

            idx = normalise_index(arg.value, tuple.elements.size)
            return nil unless idx

            tuple.elements[idx]
          end

          def tuple_start_length_slice(tuple, method_name, args)
            return nil unless method_name == :[]

            start, length = args
            return nil unless start.is_a?(Type::Constant) && length.is_a?(Type::Constant)
            return nil unless start.value.is_a?(Integer) && length.value.is_a?(Integer)

            tuple_slice(tuple.elements[start.value, length.value])
          end

          def tuple_range_slice(tuple, range)
            return nil unless integer_range?(range)

            tuple_slice(tuple.elements[range])
          end

          def tuple_slice(elements)
            return Type::Combinator.constant_of(nil) if elements.nil?

            Type::Combinator.tuple_of(*elements)
          end

          def integer_range?(range)
            [range.begin, range.end].all? { |endpoint| endpoint.nil? || endpoint.is_a?(Integer) }
          end

          # `tuple.dig(i, ...)` with a chain of static keys/indices.
          # Each step recurses through the resolved member: a Tuple
          # member dispatches `dig` on the remaining args, a HashShape
          # member does the same, and a `Constant[nil]` member ends
          # the chain at `Constant[nil]` (matching Ruby's `Array#dig`
          # short-circuit on nil). Anything else along the chain
          # falls through to the projection answer so the analyzer
          # never invents a value it cannot prove.
          def tuple_dig(tuple, _method_name, args)
            return nil if args.empty?

            step = tuple_dig_step(tuple, args.first)
            return nil if step.nil?

            chain_dig(step, args.drop(1))
          end

          def tuple_dig_step(tuple, arg)
            return nil unless arg.is_a?(Type::Constant)
            return nil unless arg.value.is_a?(Integer)

            idx = normalise_index(arg.value, tuple.elements.size)
            return Type::Combinator.constant_of(nil) if idx.nil?

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
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            Type::Combinator.constant_of(shape.pairs.size)
          end

          # `shape[k]` and `shape.fetch(k)` for a static symbol/string
          # key. Missing-key resolution depends on the method:
          #
          # - `[]` returns `nil` at runtime; we surface `Constant[nil]`
          #   so the carrier is visible to downstream narrowing.
          # - `fetch` (no default, no block) raises `KeyError`; we let
          #   the projection answer apply because the runtime would
          #   not produce a value.
          def hash_lookup(shape, method_name, args)
            return nil unless args.size == 1

            step = hash_dig_step(shape, args.first)
            return nil if step.nil?
            return nil if method_name == :fetch && optional_key_step?(shape, args.first)
            return step unless missing_key_step?(shape, args.first)

            return step if method_name == :[]

            nil
          end

          # `shape.dig(:a, :b, ...)` with a chain of static keys.
          # Same recursion semantics as Tuple#`dig`: each step looks
          # up the key, then `chain_dig` continues with the
          # resolved value as the new receiver. Missing keys collapse
          # to `Constant[nil]` (Ruby's `Hash#dig` short-circuits on
          # nil too).
          def hash_dig(shape, _method_name, args)
            return nil if args.empty?

            step = hash_dig_step(shape, args.first)
            return nil if step.nil?

            chain_dig(step, args.drop(1))
          end

          # Returns the per-step value type for a HashShape lookup
          # (or `Constant[nil]` for a known-missing key). Returns
          # `nil` when the argument is not a static symbol/string
          # so the caller can fall through to the projection answer.
          def hash_dig_step(shape, arg)
            return nil unless arg.is_a?(Type::Constant)

            key = arg.value
            return nil unless key.is_a?(Symbol) || key.is_a?(String)

            if shape.pairs.key?(key)
              value = shape.pairs[key]
              return value unless shape.optional_key?(key)

              return Type::Combinator.union(value, Type::Combinator.constant_of(nil))
            end

            Type::Combinator.constant_of(nil)
          end

          def optional_key_step?(shape, arg)
            return false unless arg.is_a?(Type::Constant)

            shape.optional_key?(arg.value)
          end

          def missing_key_step?(shape, arg)
            return false unless arg.is_a?(Type::Constant)

            !shape.pairs.key?(arg.value)
          end

          # `shape.values_at(:a, :b, ...)` with a list of static
          # keys. Returns a `Tuple` whose per-position values are
          # the per-key value types (`Constant[nil]` for missing
          # keys, mirroring Ruby's runtime behaviour). Falls through
          # when any argument is not a static symbol/string.
          def hash_values_at(shape, _method_name, args)
            return nil if args.empty?

            values = []
            args.each do |arg|
              step = hash_dig_step(shape, arg)
              return nil if step.nil?

              values << step
            end

            Type::Combinator.tuple_of(*values)
          end

          # Continues a `dig` chain after the first step. Tuple and
          # HashShape members re-dispatch into the catalogue;
          # `Constant[nil]` short-circuits the chain (Hash#dig and
          # Array#dig do the same at runtime); anything else falls
          # through so the projection answer applies.
          def chain_dig(receiver, args)
            return receiver if args.empty?

            case receiver
            when Type::Tuple then tuple_dig(receiver, :dig, args)
            when Type::HashShape then hash_dig(receiver, :dig, args)
            when Type::Constant then receiver.value.nil? ? Type::Combinator.constant_of(nil) : nil
            end
          end
        end
      end
      # rubocop:enable Metrics/ClassLength, Metrics/ModuleLength
    end
  end
end
