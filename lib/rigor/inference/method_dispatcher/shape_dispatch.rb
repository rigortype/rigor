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
          empty?: :tuple_empty?,
          any?: :tuple_any?,
          all?: :tuple_all?,
          none?: :tuple_none?,
          include?: :tuple_include?,
          sum: :tuple_sum,
          min: :tuple_min,
          max: :tuple_max,
          sort: :tuple_sort,
          reverse: :tuple_reverse,
          to_a: :tuple_to_a,
          to_h: :tuple_to_h,
          :[] => :tuple_index,
          fetch: :tuple_index,
          dig: :tuple_dig
        }.freeze

        HASH_SHAPE_HANDLERS = {
          size: :hash_size,
          length: :hash_size,
          count: :hash_size,
          empty?: :hash_empty?,
          any?: :hash_any?,
          keys: :hash_keys,
          values: :hash_values,
          to_a: :hash_to_a,
          to_h: :hash_to_h,
          invert: :hash_invert,
          merge: :hash_merge,
          :[] => :hash_lookup,
          fetch: :hash_lookup,
          dig: :hash_dig,
          values_at: :hash_values_at
        }.freeze

        # @return [Rigor::Type, nil] the precise element/value type, or
        #   `nil` to defer to the next dispatcher tier.
        # Per-carrier dispatch table. Adding a new carrier here
        # is a one-row change; the helper methods stay private.
        # Anonymous Type subclasses are not expected.
        RECEIVER_HANDLERS = {
          Type::Tuple => :dispatch_tuple,
          Type::HashShape => :dispatch_hash_shape,
          Type::Nominal => :dispatch_nominal_size,
          Type::Difference => :dispatch_difference,
          Type::Refined => :dispatch_refined,
          Type::Intersection => :dispatch_intersection
        }.freeze
        private_constant :RECEIVER_HANDLERS

        def try_dispatch(receiver:, method_name:, args:)
          args ||= []
          handler = RECEIVER_HANDLERS[receiver.class]
          return nil unless handler

          send(handler, receiver, method_name, args)
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

          # Predicate-subset projections over a `Refined[base,
          # predicate]` receiver. Today the catalogue is the
          # String case-normalisation pair: `s.downcase` over a
          # `lowercase-string` receiver folds to the same
          # carrier (already lowercase), and `s.upcase` lifts a
          # `lowercase-string` to `uppercase-string`. Symmetric
          # rules apply with the predicates swapped. Numeric-
          # string idempotence over `#downcase` / `#upcase` is
          # also recognised because a numeric string equals its
          # own case-normalisation.
          #
          # For methods this tier does not have a refinement-
          # specific rule for, projection delegates to
          # `dispatch_nominal_size` so size-returning calls on
          # a `Refined[String, *]` still tighten to
          # `non_negative_int`.
          REFINED_STRING_PROJECTIONS = {
            %i[lowercase downcase] => :refined_self,
            %i[lowercase upcase] => :uppercase_string,
            %i[uppercase upcase] => :refined_self,
            %i[uppercase downcase] => :lowercase_string,
            %i[numeric downcase] => :refined_self,
            %i[numeric upcase] => :refined_self,
            # Digit-only strings are case-invariant; the prefix
            # letters in `0o…` / `0x…` are accepted by the
            # predicate in either case so the predicate-subset
            # is preserved across `#downcase` / `#upcase` even
            # though the value-set element changes.
            %i[decimal_int downcase] => :refined_self,
            %i[decimal_int upcase] => :refined_self,
            %i[octal_int downcase] => :refined_self,
            %i[octal_int upcase] => :refined_self,
            %i[hex_int downcase] => :refined_self,
            %i[hex_int upcase] => :refined_self
          }.freeze
          private_constant :REFINED_STRING_PROJECTIONS

          def dispatch_refined(refined, method_name, args)
            base = refined.base
            return nil unless base.is_a?(Type::Nominal)

            if base.class_name == "String" && args.empty?
              precise = refined_string_projection(refined, method_name)
              return precise if precise
            end

            dispatch_nominal_size(base, method_name, args)
          end

          def refined_string_projection(refined, method_name)
            handler = REFINED_STRING_PROJECTIONS[[refined.predicate_id, method_name]]
            return nil unless handler

            case handler
            when :refined_self then refined
            when :uppercase_string then Type::Combinator.uppercase_string
            when :lowercase_string then Type::Combinator.lowercase_string
            end
          end

          # Projects a method call over an `Intersection[M1, …]`
          # receiver by collecting each member's projection and
          # combining the results. The set-theoretic identity is
          # `M(A ∩ B) ⊆ M(A) ∩ M(B)`, so the meet of the per-member
          # projections is sound. Combining is best-effort:
          #
          # - If every result is a `Type::IntegerRange`, return
          #   their bounded-integer meet (max of lower bounds, min
          #   of upper bounds). This catches the common
          #   `(non_empty_string ∩ lowercase_string).size`
          #   pattern where one member projects to `positive-int`
          #   and the other to `non-negative-int`; the meet is
          #   `positive-int`.
          # - Otherwise return the first non-nil result. A richer
          #   meet (e.g. of Difference + Refined results when both
          #   project) is left for a future slice; the carrier
          #   stays sound because every member's projection is
          #   already a superset of the true intersection.
          #
          # Returns nil when no member projects, so the caller
          # falls through to the next dispatcher tier.
          def dispatch_intersection(intersection, method_name, args)
            results = intersection.members.filter_map do |member|
              ShapeDispatch.try_dispatch(receiver: member, method_name: method_name, args: args)
            end

            case results.size
            when 0 then nil
            when 1 then results.first
            else combine_intersection_results(results)
            end
          end

          def combine_intersection_results(results)
            return narrow_integer_ranges(results) if results.all?(Type::IntegerRange)

            results.first
          end

          # Compute the bounded-integer meet of two or more
          # `IntegerRange` carriers. We compare via the numeric
          # `lower` / `upper` accessors (`-Float::INFINITY` /
          # `Float::INFINITY` for the symbolic ends), then map
          # back to the symbolic-bound representation
          # `IntegerRange.new` expects. The disjoint-meet case
          # cannot arise from sound member-wise projections in
          # v0.0.4 but is guarded defensively to keep the
          # carrier total.
          def narrow_integer_ranges(ranges)
            numeric_low = ranges.map(&:lower).max
            numeric_high = ranges.map(&:upper).min
            return Type::Combinator.bot if numeric_low > numeric_high

            min = numeric_low == -Float::INFINITY ? Type::IntegerRange::NEG_INFINITY : numeric_low.to_i
            max = numeric_high == Float::INFINITY ? Type::IntegerRange::POS_INFINITY : numeric_high.to_i
            Type::Combinator.integer_range(min, max)
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

          # `tuple.empty?` — folds to a precise bool from the
          # tuple's known arity.
          # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
          def tuple_empty?(tuple, _method_name, args)
            return nil unless args.empty?

            Type::Combinator.constant_of(tuple.elements.empty?)
          end

          # `tuple.any?` (no-arg, no-block) — empty tuple → false,
          # non-empty → true. The block / arg forms flow through
          # `BlockFolding` and the RBS tier.
          def tuple_any?(tuple, _method_name, args)
            return nil unless args.empty?

            Type::Combinator.constant_of(!tuple.elements.empty?)
          end

          # `tuple.all?` (no-arg, no-block) — true for empty
          # tuple (vacuous truth) AND for non-empty tuples whose
          # every element is provably truthy. Mixed / unknown
          # element truthiness declines so the RBS / BlockFolding
          # tiers can still answer.
          def tuple_all?(tuple, _method_name, args)
            return nil unless args.empty?
            return Type::Combinator.constant_of(true) if tuple.elements.empty?

            decision = tuple_predicate_truthiness(tuple, all: true)
            return nil if decision.nil?

            Type::Combinator.constant_of(decision)
          end

          # `tuple.none?` (no-arg, no-block) — true when every
          # element is provably falsey, false when any element is
          # provably truthy. Empty tuple folds to true (vacuous).
          def tuple_none?(tuple, _method_name, args)
            return nil unless args.empty?
            return Type::Combinator.constant_of(true) if tuple.elements.empty?

            decision = tuple_predicate_truthiness(tuple, all: false)
            return nil if decision.nil?

            Type::Combinator.constant_of(decision)
          end

          # `tuple.include?(needle)` — folds to a precise bool when
          # the needle is a `Constant` and the tuple's elements
          # are all `Constant` (so disjointness is checkable).
          # If any element matches the needle's value the answer
          # is `Constant[true]`; if every element is a Constant
          # whose value is structurally distinct from the needle
          # the answer is `Constant[false]`.
          def tuple_include?(tuple, _method_name, args)
            return nil unless args.size == 1

            needle = args.first
            return nil unless needle.is_a?(Type::Constant)
            return Type::Combinator.constant_of(false) if tuple.elements.empty?

            return Type::Combinator.constant_of(true) if any_element_matches?(tuple.elements, needle.value)
            return Type::Combinator.constant_of(false) if tuple.elements.all?(Type::Constant)

            nil
          end
          # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

          # `tuple.sum` — when every element is a numeric Constant,
          # fold to `Constant[sum]`. Mixed / non-numeric elements
          # decline so RBS widens.
          def tuple_sum(tuple, _method_name, args)
            return nil unless args.empty?
            return Type::Combinator.constant_of(0) if tuple.elements.empty?

            values = constant_numeric_values(tuple.elements)
            return nil if values.nil?

            Type::Combinator.constant_of(values.sum)
          end

          # `tuple.min` / `tuple.max` — fold when every element is
          # a `Constant` whose values share a Ruby-comparable
          # domain. Empty tuples fold to `Constant[nil]`.
          def tuple_min(tuple, _method_name, args)
            tuple_minmax(tuple, args, :min)
          end

          def tuple_max(tuple, _method_name, args)
            tuple_minmax(tuple, args, :max)
          end

          def tuple_minmax(tuple, args, edge)
            return nil unless args.empty?
            return Type::Combinator.constant_of(nil) if tuple.elements.empty?

            values = constant_values(tuple.elements)
            return nil if values.nil?

            result = values.public_send(edge)
            Type::Combinator.constant_of(result)
          rescue StandardError
            nil
          end

          # `tuple.sort` — every element must be a `Constant` and
          # the values must Ruby-compare. The result is a Tuple
          # with the same elements in sorted order. Comparison
          # failures (mixed-class incomparable values) decline.
          def tuple_sort(tuple, _method_name, args)
            return nil unless args.empty?
            return tuple if tuple.elements.size <= 1

            values = constant_values(tuple.elements)
            return nil if values.nil?

            sorted = values.sort
            Type::Combinator.tuple_of(*sorted.map { |v| Type::Combinator.constant_of(v) })
          rescue StandardError
            nil
          end

          # `tuple.reverse` — independent of element shape; a
          # tuple-precise reversed Tuple.
          def tuple_reverse(tuple, _method_name, args)
            return nil unless args.empty?

            Type::Combinator.tuple_of(*tuple.elements.reverse)
          end

          # `tuple.to_a` — Tuple is structurally identical to its
          # to_a (Ruby returns the receiver itself for an Array).
          def tuple_to_a(tuple, _method_name, args)
            return nil unless args.empty?

            tuple
          end

          # `tuple.to_h` — folds when every Tuple element is itself
          # a 2-element Tuple whose first element is a `Constant`
          # (so it can serve as a Hash key). Produces a closed
          # `HashShape` whose entries mirror the per-position
          # pairs. Empty Tuples fold to the empty HashShape.
          # rubocop:disable Metrics/CyclomaticComplexity
          def tuple_to_h(tuple, _method_name, args)
            return nil unless args.empty?
            return Type::Combinator.hash_shape_of({}) if tuple.elements.empty?

            pairs = tuple.elements.map { |e| tuple_to_h_pair(e) }
            return nil if pairs.any?(&:nil?)
            return nil unless pairs.map(&:first).uniq.size == pairs.size

            Type::Combinator.hash_shape_of(pairs.to_h)
          end
          # rubocop:enable Metrics/CyclomaticComplexity

          def tuple_to_h_pair(element)
            return nil unless element.is_a?(Type::Tuple)
            return nil unless element.elements.size == 2

            key = element.elements[0]
            value = element.elements[1]
            return nil unless key.is_a?(Type::Constant)

            [key.value, value]
          end

          # Returns `true` / `false` if every element's truthiness
          # agrees, nil for mixed-or-unknown shapes. `all: true`
          # checks every element is truthy; `all: false` checks
          # every element is falsey.
          def tuple_predicate_truthiness(tuple, all:)
            samples = tuple.elements.map { |e| element_truthiness(e) }
            return nil if samples.any?(:unknown)

            if all
              samples.all?(:truthy)
            else
              samples.all?(:falsey)
            end
          end

          def element_truthiness(type)
            return :unknown unless type.is_a?(Type::Constant)

            falsey = type.value.nil? || type.value == false
            falsey ? :falsey : :truthy
          end

          def any_element_matches?(elements, value)
            elements.any? { |e| e.is_a?(Type::Constant) && e.value == value }
          end

          # Per-element Constant value extraction. Returns nil
          # when any element is non-Constant, so the caller can
          # decline.
          def constant_values(elements)
            return nil unless elements.all?(Type::Constant)

            elements.map(&:value)
          end

          def constant_numeric_values(elements)
            values = constant_values(elements)
            return nil if values.nil?
            return nil unless values.all?(Numeric)

            values
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

          # `shape.empty?` — folds to a precise bool when the
          # shape's emptiness is statically known. Closed shapes
          # with no optional keys have a fixed size, so empty?
          # is `Constant[shape.pairs.empty?]`. The handler returns
          # `Type::t | nil` (nil signals "no rule, defer to next
          # tier") so the standard predicate-return rubocop rule
          # does not apply.
          # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
          def hash_empty?(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            Type::Combinator.constant_of(shape.pairs.empty?)
          end

          # `shape.any?` (no block, no arg) — opposite of
          # `empty?`. The block / arg forms are answered by the
          # RBS / BlockFolding tier.
          def hash_any?(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            Type::Combinator.constant_of(!shape.pairs.empty?)
          end
          # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

          # `shape.keys` — returns a `Tuple[Constant<k>…]` for a
          # closed shape with no optional keys; the Tuple's
          # arity matches the shape's per-key declaration order
          # so downstream `tuple[i]` projections stay precise.
          def hash_keys(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            Type::Combinator.tuple_of(*shape.pairs.keys.map { |k| Type::Combinator.constant_of(k) })
          end

          # `shape.values` — returns a `Tuple[V_1, …, V_n]` for a
          # closed shape with no optional keys, the Tuple's arity
          # matching the shape's per-key value order.
          def hash_values(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            Type::Combinator.tuple_of(*shape.pairs.values)
          end

          # `shape.to_a` — returns a per-entry `Tuple[Tuple[K, V], …]`
          # for a closed shape with no optional keys.
          def hash_to_a(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            entries = shape.pairs.map do |k, v|
              Type::Combinator.tuple_of(Type::Combinator.constant_of(k), v)
            end
            Type::Combinator.tuple_of(*entries)
          end

          # `shape.to_h` — Hash is structurally identical to its
          # to_h (Ruby returns the receiver itself for a Hash).
          def hash_to_h(shape, _method_name, args)
            return nil unless args.empty?

            shape
          end

          # `shape.invert` — swaps keys and values. Folds when
          # every value is a `Constant` whose value is a Symbol
          # or String (the only hashable types that
          # `HashShape` accepts as keys). Duplicate values would
          # alias under inversion, so Rigor declines on
          # collisions rather than silently dropping entries.
          # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          def hash_invert(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?
            return nil unless shape.pairs.values.all?(Type::Constant)
            return nil unless shape.pairs.values.all? { |v| v.value.is_a?(Symbol) || v.value.is_a?(String) }

            inverted = shape.pairs.each_with_object({}) do |(k, v), acc|
              return nil if acc.key?(v.value)

              acc[v.value] = Type::Combinator.constant_of(k)
            end
            Type::Combinator.hash_shape_of(inverted)
          end
          # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          # `shape.merge(other)` — when both sides are closed
          # HashShape with no optional keys, fold to the merged
          # HashShape. Right-hand entries override left-hand
          # entries on key collision (matching Ruby's runtime
          # `Hash#merge`).
          def hash_merge(shape, _method_name, args)
            return nil unless args.size == 1
            return nil unless shape.closed? && shape.optional_keys.empty?

            other = args.first
            return nil unless other.is_a?(Type::HashShape)
            return nil unless other.closed? && other.optional_keys.empty?

            Type::Combinator.hash_shape_of(shape.pairs.merge(other.pairs))
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
