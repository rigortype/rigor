# frozen_string_literal: true

require_relative "../../type"
require_relative "call_context"

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
          minmax: :tuple_minmax_pair,
          sort: :tuple_sort,
          reverse: :tuple_reverse,
          to_a: :tuple_to_a,
          to_h: :tuple_to_h,
          zip: :tuple_zip,
          :[] => :tuple_index,
          slice: :tuple_index,
          fetch: :tuple_index,
          dig: :tuple_dig,
          values_at: :tuple_values_at,
          :+ => :tuple_concat,
          compact: :tuple_compact,
          take: :tuple_take,
          drop: :tuple_drop,
          rotate: :tuple_rotate,
          uniq: :tuple_uniq,
          index: :tuple_find_index,
          find_index: :tuple_find_index,
          rindex: :tuple_rindex,
          flatten: :tuple_flatten,
          join: :tuple_join
        }.freeze

        # Byte cap on a folded `tuple.join` result — a huge tuple times a
        # long separator must not materialise an unbounded `Constant`.
        TUPLE_JOIN_BYTE_LIMIT = 4096
        private_constant :TUPLE_JOIN_BYTE_LIMIT

        HASH_SHAPE_HANDLERS = {
          size: :hash_size,
          length: :hash_size,
          count: :hash_size,
          empty?: :hash_empty?,
          any?: :hash_any?,
          none?: :hash_none?,
          one?: :hash_one?,
          keys: :hash_keys,
          values: :hash_values,
          first: :hash_first,
          flatten: :hash_flatten,
          compact: :hash_compact,
          to_a: :hash_to_a,
          entries: :hash_to_a,
          to_h: :hash_to_h,
          to_hash: :hash_to_h,
          deconstruct_keys: :hash_deconstruct_keys,
          invert: :hash_invert,
          merge: :hash_merge,
          slice: :hash_slice,
          except: :hash_except,
          :[] => :hash_lookup,
          fetch: :hash_lookup,
          dig: :hash_dig,
          values_at: :hash_values_at,
          fetch_values: :hash_fetch_values,
          assoc: :hash_assoc,
          rassoc: :hash_rassoc,
          key: :hash_key,
          has_key?: :hash_has_key?,
          key?: :hash_has_key?,
          member?: :hash_has_key?,
          include?: :hash_has_key?,
          has_value?: :hash_has_value?,
          value?: :hash_has_value?,
          default: :hash_default,
          default_proc: :hash_default,
          :< => :hash_compare,
          :<= => :hash_compare,
          :> => :hash_compare,
          :>= => :hash_compare
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
          Type::Intersection => :dispatch_intersection,
          Type::IntegerRange => :dispatch_integer_range
        }.freeze
        private_constant :RECEIVER_HANDLERS

        # v0.1.1 Track 1 slice 5b — `Integer#to_s(base)` on a
        # non-negative `IntegerRange` receiver. The output of
        # `n.to_s(b)` for `n >= 0` is digit-string-only (no
        # leading sign), so when the base is in this table the
        # result lifts to the matching imported refinement.
        # Bases not listed (2, 36, ...) keep the v0.1.0 baseline
        # since Rigor has no carrier for the resulting alphabet.
        TO_S_BASE_REFINEMENTS = {
          10 => :decimal_int_string,
          8 => :octal_int_string,
          16 => :hex_int_string
        }.freeze
        private_constant :TO_S_BASE_REFINEMENTS

        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
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
        SIZE_RETURNING_NOMINALS = Ractor.make_shareable({
                                                          "Array" => %i[size length count],
                                                          "String" => %i[length size bytesize],
                                                          "Hash" => %i[size length count],
                                                          "Set" => %i[size length count],
                                                          "Range" => %i[size length count]
                                                        })
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
            projection = nominal_projection(nominal, method_name, args)
            return projection if projection

            return nil unless args.empty?

            selectors = SIZE_RETURNING_NOMINALS[nominal.class_name]
            return nil unless selectors&.include?(method_name)

            Type::Combinator.non_negative_int
          end

          # Arg-/method-driven precision projections for a `Nominal`
          # receiver, consulted ahead of the no-arg size tier. Each
          # branch gates on the class name first so unrelated nominals
          # skip the work. Returns nil when no projection applies.
          def nominal_projection(nominal, method_name, args)
            case nominal.class_name
            when "String"
              dispatch_string_binary_from_arg(method_name, args.first) if args.size == 1
            when "Integer"
              dispatch_integer_binary_from_arg(method_name, args.first) if args.size == 1
            when "Array"
              case method_name
              when :flatten then array_nominal_flatten(nominal, args)
              when :compact then array_nominal_compact(nominal, args)
              end
            end
          end

          # `Array[T]#compact` — `compact` removes every `nil` element,
          # so the result element type is `T` with its `nil` constituent
          # stripped (`Array[Node?]#compact` → `Array[Node]`). Mirrors
          # the `Tuple#compact` constant fold for the generic element
          # case. Declines when the receiver carries no type argument
          # (the RBS `Array[untyped]` answer is already maximal) or when
          # `T` has no `nil` constituent to remove (the result equals the
          # receiver, so the RBS tier's answer is already precise).
          def array_nominal_compact(nominal, args)
            return nil unless args.empty?

            element = nominal.type_args&.first
            return nil if element.nil?

            stripped = strip_nil_constituent(element)
            return nil if stripped.equal?(element)

            Type::Combinator.nominal_of("Array", type_args: [stripped])
          end

          # Removes the `nil` constituent from a (possibly union) type,
          # returning the same object when there is nothing to remove so
          # callers can detect the no-op cheaply. Kept local to the
          # dispatch tier to avoid a dependency on the narrowing module.
          def strip_nil_constituent(type)
            case type
            when Type::Constant
              type.value.nil? ? Type::Combinator.bot : type
            when Type::Nominal
              type.class_name == "NilClass" ? Type::Combinator.bot : type
            when Type::Union
              kept = type.members.map { |m| strip_nil_constituent(m) }
              return type if kept.zip(type.members).all? { |k, m| k.equal?(m) }

              Type::Combinator.union(*kept)
            else
              type
            end
          end

          # `Array[T]#flatten` (and `flatten(depth)`). When `T` is a
          # nested `Array[U]` nominal, one flatten level yields the
          # joined inner element type — `Array[Array[U]]#flatten` →
          # `Array[U]`. When `T` is non-nested the result is `Array[T]`
          # unchanged (Ruby returns a copy with the same element type).
          # Multi-level nesting is handled conservatively: each level
          # joins its element types, and a `depth` argument that does
          # not fully resolve the nesting still produces a sound
          # superset. Declines on an `Array` with no type argument
          # (the RBS `Array[untyped]` answer is already as precise as
          # we can be) and on a non-static depth argument.
          def array_nominal_flatten(nominal, args)
            element = nominal.type_args&.first
            return nil if element.nil?

            depth = tuple_flatten_depth(args)
            return nil if depth == :decline

            flattened = flatten_nominal_element(element, depth)
            Type::Combinator.nominal_of("Array", type_args: [flattened])
          end

          # Resolves the element type of a flattened `Array[element]`.
          # Each `Array[U]` nesting level contributes `U`; the per-level
          # element types are unioned. `depth < 0` recurses without
          # bound; `depth == 0` stops (Ruby's `flatten(0)` is a no-op
          # copy and returns the element unchanged).
          def flatten_nominal_element(element, depth)
            return element if depth.zero?
            return element unless array_nominal?(element)

            inner = element.type_args.first
            return element if inner.nil?

            flatten_nominal_element(inner, depth - 1)
          end

          def array_nominal?(type)
            type.is_a?(Type::Nominal) && type.class_name == "Array" && !type.type_args.nil? &&
              !type.type_args.empty?
          end

          # Arg-type-driven String binary projections for any String-typed
          # receiver (including Nominal, Refined, and Difference fallbacks).
          # Called before the no-arg size guard so binary operators are seen.
          #
          # - `String + non-empty-string` → `non-empty-string`
          #   (arg guarantees the concatenation is non-empty)
          # - `String * Constant[0]` → `Constant[""]`
          #   (every string repeated 0 times is the empty string)
          def dispatch_string_binary_from_arg(method_name, arg)
            case method_name
            when :+
              return Type::Combinator.non_empty_string if Type::Combinator.non_empty_string_compatible?(arg)
            when :*
              if arg.is_a?(Type::Constant) && arg.value.is_a?(Integer) && arg.value.zero?
                return Type::Combinator.constant_of("")
              end
            end
            nil
          end

          # Arg-type-driven Integer binary projections for any Integer-typed
          # receiver (including Nominal, Refined, and Difference fallbacks).
          #
          # - `Integer * Constant[0]` → `Constant[0]`
          #   (any integer multiplied by 0 is 0)
          def dispatch_integer_binary_from_arg(method_name, arg)
            return nil unless method_name == :*
            return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(Integer) && arg.value.zero?

            Type::Combinator.constant_of(0)
          end

          # `IntegerRange#to_s` precision (v0.1.1 Track 1 slice 5b).
          # When the range's lower bound is `>= 0`, every member is
          # a non-negative integer and `to_s(base)` returns a
          # digit-string with no leading sign. The result lifts to
          # the matching imported refinement (`decimal-int-string`
          # for base 10, `octal-int-string` for 8, `hex-int-string`
          # for 16). Signed ranges fall through (the result could
          # carry a `-` sign that no Rigor refinement currently
          # captures), as do bases without a digit-only refinement.
          def dispatch_integer_range(range, method_name, args)
            return nil unless method_name == :to_s
            return nil unless range.lower >= 0

            base = base_argument(args)
            return nil if base.nil?

            refinement = TO_S_BASE_REFINEMENTS[base]
            return nil if refinement.nil?

            Type::Combinator.public_send(refinement)
          end

          # `to_s` with no argument defaults to base 10. With one
          # argument, the value MUST be a `Constant<Integer>` to
          # be statically known. Anything else (Nominal[Integer]
          # arg, multi-arg, etc.) declines.
          def base_argument(args)
            return 10 if args.empty?
            return nil unless args.size == 1

            arg = args.first
            return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(Integer)

            arg.value
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
              precise = empty_removal_projection(difference, method_name, args)
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

          # Methods on a non-empty String that preserve non-emptiness
          # (they transform characters but never reduce the string to "").
          NON_EMPTY_STRING_PRESERVING_UNARY = Set[:upcase, :downcase, :capitalize, :swapcase, :reverse].freeze
          # Methods on non-zero-int that return a non-zero-int (identity ops).
          # Negation of a non-zero integer is non-zero; `to_i`/`to_int` are
          # identity operations on Integer.
          NON_ZERO_INT_PRESERVING_UNARY = Set[:-@, :+@, :to_i, :to_int].freeze
          private_constant :NON_EMPTY_STRING_PRESERVING_UNARY, :NON_ZERO_INT_PRESERVING_UNARY

          def empty_removal_projection(difference, method_name, args)
            base = difference.base
            return empty_removal_unary(difference, base, method_name) if args.empty?

            empty_removal_binary(difference, base, method_name, args)
          end

          def empty_removal_unary(difference, base, method_name)
            return size_returning_for_empty_removal(base, method_name) if
              %i[size length count bytesize].include?(method_name)

            predicate_result = empty_predicate_projection(base, method_name)
            return predicate_result if predicate_result

            return difference if base.class_name == "String" &&
                                 NON_EMPTY_STRING_PRESERVING_UNARY.include?(method_name)

            non_zero_int_unary_projection(difference, base, method_name)
          end

          def non_zero_int_unary_projection(difference, base, method_name)
            return nil unless base.class_name == "Integer"
            return Type::Combinator.positive_int if %i[abs magnitude].include?(method_name)
            return difference if NON_ZERO_INT_PRESERVING_UNARY.include?(method_name)

            nil
          end

          def empty_removal_binary(difference, base, method_name, args)
            return empty_string_binary(difference, method_name, args) if base.class_name == "String"
            return empty_integer_binary(difference, method_name, args) if base.class_name == "Integer"

            nil
          end

          def empty_string_binary(difference, method_name, args)
            return difference if method_name == :+ && args.size == 1
            return non_empty_string_repeat(difference, args.first) if method_name == :* && args.size == 1

            nil
          end

          def empty_integer_binary(difference, method_name, args)
            return nil unless method_name == :* && args.size == 1
            return nil unless Type::Combinator.non_zero_int_compatible?(args.first)

            difference
          end

          def empty_predicate_projection(base, method_name)
            case method_name
            when :empty?
              base.class_name == "Integer" ? nil : Type::Combinator.constant_of(false)
            when :zero?
              base.class_name == "Integer" ? Type::Combinator.constant_of(false) : nil
            end
          end

          # `non-empty-string * n` result:
          # - `n == 0`  → `Constant[""]` (any string repeated 0 times is empty)
          # - `n >= 1`  → `difference` (non-empty-string stays non-empty)
          # - otherwise → nil (fall through, e.g. unknown n or non-negative-int)
          def non_empty_string_repeat(difference, arg)
            case arg
            when Type::Constant
              return nil unless arg.value.is_a?(Integer)

              return Type::Combinator.constant_of("") if arg.value.zero?
              return difference if arg.value.positive?
            when Type::IntegerRange
              return Type::Combinator.constant_of("") if arg.lower.zero? && arg.upper.zero?
              return difference if arg.lower >= 1
            end
            nil
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
          # ADR-15 Phase 4b.x — `Ractor.make_shareable` (not `.freeze`)
          # because the keys are two-element Symbol arrays whose
          # inner arrays are unfrozen under shallow `.freeze`.
          # Surfaced on Discourse via `Ractor::IsolationError` when
          # the dispatch loop's `REFINED_STRING_PROJECTIONS[[id, sym]]`
          # lookup ran from a worker Ractor.
          REFINED_STRING_PROJECTIONS = Ractor.make_shareable({
                                                               %i[lowercase downcase] => :refined_self,
                                                               %i[lowercase upcase] => :uppercase_string,
                                                               %i[uppercase upcase] => :refined_self,
                                                               %i[uppercase downcase] => :lowercase_string,
                                                               # `numeric-string` is the full Ruby numeric-literal
                                                               # grammar (since the predicate delegates to the
                                                               # parser). `#downcase` preserves it — lowercasing a
                                                               # literal (hex digits, `0X` / `E` prefixes) yields a
                                                               # valid lowercase literal — but `#upcase` does NOT:
                                                               # the rational / imaginary suffixes are lowercase-only
                                                               # (`"1r".upcase == "1R"` is not a literal), so `upcase`
                                                               # drops to the plain base `String` — still sound (the
                                                               # result is a String), just no longer numeric.
                                                               %i[numeric downcase] => :refined_self,
                                                               %i[numeric upcase] => :base_string,
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
                                                               %i[hex_int upcase] => :refined_self,
                                                               # v0.1.1 Track 1 slice 2 — `to_i` / `to_int` on a
                                                               # `decimal-int-string` parses to an `Integer`. The
                                                               # carrier is `universal_int`, NOT `non-negative-int`:
                                                               # the predicate `/\A-?\d+\z/` admits a leading sign, so
                                                               # `"-7"` is a valid decimal-int-string and
                                                               # `"-7".to_i == -7 < 0`. `String#to_i` is total (never
                                                               # raises), so the projection is sound — just signed.
                                                               # `numeric-string` is deliberately NOT projected to
                                                               # `to_i` at all: it now spans the full numeric-literal
                                                               # grammar, so a `"1.5"` / `"2i"` inhabitant has a
                                                               # fractional or non-Integer parse — it falls through to
                                                               # the RBS `Integer`.
                                                               %i[decimal_int to_i] => :universal_int,
                                                               %i[decimal_int to_int] => :universal_int
                                                             })
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
            when :non_negative_int then Type::Combinator.non_negative_int
            when :universal_int then Type::Combinator.universal_int
            when :base_string then refined.base
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
              ShapeDispatch.try_dispatch(
                CallContext.build(receiver: member, method_name: method_name, args: args)
              )
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

          # `first` (no arg) → the first element (or `Constant[nil]` when
          # empty). The `first(n)` arg-form is deliberately left to RBS
          # overload selection (see the overload-selection specs) — folding
          # it here would change that documented `Array[Elem]` contract.
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

          # `tuple.join(sep = "")` — fold to the joined `Constant[String]`
          # when every element is a `Constant` (its `to_s` is deterministic
          # for the scalar value classes) and the separator is absent or a
          # `Constant[String]`. Capped at `TUPLE_JOIN_BYTE_LIMIT`.
          def tuple_join(tuple, _method_name, args)
            sep = tuple_join_separator(args)
            return nil if sep.nil?

            values = constant_values(tuple.elements)
            return nil if values.nil?

            result = values.join(sep)
            return nil if result.bytesize > TUPLE_JOIN_BYTE_LIMIT

            Type::Combinator.constant_of(result)
          rescue StandardError
            nil
          end

          # The join separator: `""` for the no-arg form, the value of a
          # single `Constant[String]` arg, or `nil` to decline.
          def tuple_join_separator(args)
            return "" if args.empty?
            return nil unless args.size == 1

            arg = args.first
            return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(String)

            arg.value
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

          # `tuple.minmax` — the `[min, max]` pair as a 2-slot
          # `Tuple[Constant[min], Constant[max]]`, mirroring the
          # `Range#minmax` fold. Every element must be a `Constant`
          # and the values must Ruby-compare; an empty tuple folds to
          # `Tuple[nil, nil]` (Ruby's `[].minmax`), incomparable
          # mixed-class values decline.
          def tuple_minmax_pair(tuple, _method_name, args)
            return nil unless args.empty?

            if tuple.elements.empty?
              nil_const = Type::Combinator.constant_of(nil)
              return Type::Combinator.tuple_of(nil_const, nil_const)
            end

            values = constant_values(tuple.elements)
            return nil if values.nil?

            low, high = values.minmax
            Type::Combinator.tuple_of(
              Type::Combinator.constant_of(low),
              Type::Combinator.constant_of(high)
            )
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

          # `tuple.zip(other_1, other_2, …)` — pairs the receiver's
          # per-position elements with the per-position elements of
          # each other Tuple-shaped argument. The result is a Tuple
          # of Tuples whose arity matches the receiver: position
          # `i` is `Tuple[receiver[i], other_1[i], other_2[i], …]`.
          # Out-of-range positions in any `other_k` contribute
          # `Constant[nil]` (matching Ruby's runtime semantics).
          # Declines when any `other_k` is not a Tuple, since the
          # arity is then unknown and the result would be
          # `Array[Array[…]]` — RBS already gives that answer.
          def tuple_zip(tuple, _method_name, args)
            return nil if args.empty? || args.size > MAX_ZIP_ARITY
            return nil unless args.all?(Type::Tuple)

            zipped = tuple.elements.each_with_index.map do |elem, i|
              positions = [elem] + args.map { |other| other.elements[i] || Type::Combinator.constant_of(nil) }
              Type::Combinator.tuple_of(*positions)
            end
            Type::Combinator.tuple_of(*zipped)
          end

          MAX_ZIP_ARITY = 8
          private_constant :MAX_ZIP_ARITY

          # `tuple.to_h` — folds when every Tuple element is itself
          # a 2-element Tuple whose first element is a `Constant`
          # (so it can serve as a Hash key). Produces a closed
          # `HashShape` whose entries mirror the per-position
          # pairs. Empty Tuples fold to the empty HashShape.
          def tuple_to_h(tuple, _method_name, args)
            return nil unless args.empty?
            return Type::Combinator.hash_shape_of({}) if tuple.elements.empty?

            pairs = tuple.elements.map { |e| tuple_to_h_pair(e) }
            return nil if pairs.any?(&:nil?)
            return nil unless pairs.map(&:first).uniq.size == pairs.size

            Type::Combinator.hash_shape_of(pairs.to_h)
          end

          def tuple_to_h_pair(element)
            return nil unless element.is_a?(Type::Tuple)
            return nil unless element.elements.size == 2

            key = element.elements[0]
            value = element.elements[1]
            return nil unless key.is_a?(Type::Constant)

            [key.value, value]
          end

          # `tuple.values_at(i1, i2, ...)` — returns a Tuple of
          # per-index elements. Each argument must be a
          # `Constant[Integer]`. Out-of-range indices fill with
          # `Constant[nil]`, mirroring Ruby's runtime behaviour.
          # Declines when any argument is non-static.
          def tuple_values_at(tuple, _method_name, args)
            return nil if args.empty?

            values = args.map do |arg|
              return nil unless arg.is_a?(Type::Constant)
              return nil unless arg.value.is_a?(Integer)

              idx = normalise_index(arg.value, tuple.elements.size)
              idx ? tuple.elements[idx] : Type::Combinator.constant_of(nil)
            end

            Type::Combinator.tuple_of(*values)
          end

          # `tuple + other` — concatenates two Tuples. Both sides
          # must be `Type::Tuple`. Returns a new Tuple whose
          # elements are those of the receiver followed by those
          # of the argument.
          def tuple_concat(tuple, _method_name, args)
            return nil unless args.size == 1

            other = args.first
            return nil unless other.is_a?(Type::Tuple)

            Type::Combinator.tuple_of(*tuple.elements, *other.elements)
          end

          # `tuple.compact` — removes every element that is
          # `Constant[nil]`. Folds only when every element is a
          # `Constant` (so the nil set is decidable). Mixed-shape
          # elements decline so the RBS tier widens.
          def tuple_compact(tuple, _method_name, args)
            return nil unless args.empty?
            return nil unless tuple.elements.all?(Type::Constant)

            kept = tuple.elements.reject { |e| e.is_a?(Type::Constant) && e.value.nil? }
            Type::Combinator.tuple_of(*kept)
          end

          # `uniq` (no block) → `Tuple` of the first occurrence of each
          # distinct value. Folds only when every element is a `Constant`
          # so value equality is decidable; the block form defers.
          def tuple_uniq(tuple, _method_name, args)
            return nil unless args.empty?
            return nil unless tuple.elements.all?(Type::Constant)

            seen = []
            kept = tuple.elements.each_with_object([]) do |element, acc|
              next if seen.include?(element.value)

              seen << element.value
              acc << element
            end
            Type::Combinator.tuple_of(*kept)
          end

          # `index(obj)` / `find_index(obj)` → `Constant[Integer]` of the
          # first element equal to `obj`, `Constant[nil]` when none match.
          # Folds only for the argument form (the block form defers) when
          # every element AND the argument are `Constant` (decidable
          # equality).
          def tuple_find_index(tuple, _method_name, args)
            constant_index(tuple, args) { |elements, value| elements.index { |e| e.value == value } }
          end

          # `tuple.flatten` / `tuple.flatten(depth)` — recursively
          # flattens nested Tuple elements into a single Tuple. With
          # no argument the flatten is unbounded (matching Ruby's
          # `Array#flatten`); a `Constant[Integer]` depth bounds it.
          # Non-Tuple elements (scalars, `Array[T]` nominals, …) pass
          # through unchanged at their level. A non-static depth
          # argument (or a non-Integer one) declines so RBS answers.
          def tuple_flatten(tuple, _method_name, args)
            depth = tuple_flatten_depth(args)
            return nil if depth == :decline

            Type::Combinator.tuple_of(*flatten_elements(tuple.elements, depth))
          end

          # Returns the requested flatten depth: `-1` for the no-arg
          # (unbounded) form, the Integer for a `Constant[Integer]`
          # argument, or `:decline` for any non-static / wrong-arity
          # argument shape.
          def tuple_flatten_depth(args)
            return -1 if args.empty?
            return :decline unless args.size == 1

            arg = args.first
            return arg.value if arg.is_a?(Type::Constant) && arg.value.is_a?(Integer)

            :decline
          end

          # Flattens a list of element types to `depth` levels.
          # `depth < 0` means unbounded. A Tuple element is spliced
          # in (recursing with `depth - 1`); everything else passes
          # through at this level.
          def flatten_elements(elements, depth)
            return elements if depth.zero?

            elements.flat_map do |element|
              if element.is_a?(Type::Tuple)
                flatten_elements(element.elements, depth - 1)
              else
                [element]
              end
            end
          end

          # `rindex(obj)` → the LAST matching index, same decidability gate.
          def tuple_rindex(tuple, _method_name, args)
            constant_index(tuple, args) { |elements, value| elements.rindex { |e| e.value == value } }
          end

          def constant_index(tuple, args)
            return nil unless args.size == 1

            needle = args.first
            return nil unless needle.is_a?(Type::Constant)
            return nil unless tuple.elements.all?(Type::Constant)

            Type::Combinator.constant_of(yield(tuple.elements, needle.value))
          end

          # `tuple.take(n)` — returns the first n elements as a
          # new Tuple. The argument must be a `Constant[Integer]`.
          # n <= 0 returns the empty Tuple; n >= size returns the
          # full receiver.
          def tuple_take(tuple, _method_name, args)
            n = non_negative_count_arg(args)
            return nil if n.nil?

            Type::Combinator.tuple_of(*tuple.elements.take(n))
          end

          # `drop(n)` → `Tuple` of every element after the first `n`
          # (mirror of `take`; `n >= size` → empty Tuple).
          def tuple_drop(tuple, _method_name, args)
            n = non_negative_count_arg(args)
            return nil if n.nil?

            Type::Combinator.tuple_of(*tuple.elements.drop(n))
          end

          # `rotate` (no arg → 1) / `rotate(n)` → `Tuple` of the elements
          # cyclically shifted left by `n` (`Array#rotate` handles negative
          # and out-of-range `n` by modulo, so any Integer arg folds).
          def tuple_rotate(tuple, _method_name, args)
            count =
              if args.empty?
                1
              else
                arg = args.size == 1 ? args.first : nil
                return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(Integer)

                arg.value
              end
            Type::Combinator.tuple_of(*tuple.elements.rotate(count))
          end

          # Unwraps a single non-negative `Constant[Integer]` count argument
          # (the `take` / `drop` / `first(n)` / `last(n)` shape). Returns the
          # Integer, or nil to defer (wrong arity, non-constant, non-Integer,
          # or negative — `Array#take`/`#drop` raise on negative counts).
          def non_negative_count_arg(args)
            return nil unless args.size == 1

            arg = args.first
            return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(Integer)
            return nil if arg.value.negative?

            arg.value
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
          # `[]` and its exact alias `slice` share the index / Range /
          # start-length folding. `fetch` routes here too but stays
          # integer-index-only: the Range and start-length branches gate
          # on this selector set, which `fetch` is deliberately not in.
          SLICE_SELECTORS = Set[:[], :slice].freeze
          private_constant :SLICE_SELECTORS

          def tuple_index(tuple, method_name, args)
            case args.size
            when 1 then tuple_single_index(tuple, method_name, args.first)
            when 2 then tuple_start_length_slice(tuple, method_name, args)
            end
          end

          def tuple_single_index(tuple, method_name, arg)
            return nil unless arg.is_a?(Type::Constant)

            value = arg.value
            return tuple_range_slice(tuple, value) if SLICE_SELECTORS.include?(method_name) && value.is_a?(Range)
            return nil unless value.is_a?(Integer)

            idx = normalise_index(value, tuple.elements.size)
            return nil unless idx

            tuple.elements[idx]
          end

          def tuple_start_length_slice(tuple, method_name, args)
            return nil unless SLICE_SELECTORS.include?(method_name)

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

          # `shape.none?` (no block, no arg) — mirror of `any?`.
          # Folds to `Constant[shape.pairs.empty?]` for closed
          # shapes with no optional keys.
          def hash_none?(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            Type::Combinator.constant_of(shape.pairs.empty?)
          end

          # `shape.one?` (no block, no arg) — folds to
          # `Constant[shape.pairs.size == 1]` for a closed shape
          # with no optional keys.
          def hash_one?(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            Type::Combinator.constant_of(shape.pairs.size == 1)
          end

          # `shape.deconstruct_keys(keys)` — Ruby's `Hash#deconstruct_keys`
          # returns the receiver itself regardless of the `keys`
          # argument, so the precise answer is the shape unchanged.
          def hash_deconstruct_keys(shape, _method_name, args)
            return nil unless args.size == 1

            shape
          end

          # `shape.fetch_values(:a, :b, ...)` — like `values_at` but
          # raises `KeyError` on a missing key. Folds to `Tuple[V…]`
          # only when every requested key is present; a missing key
          # declines so the RBS tier reflects the raise.
          def hash_fetch_values(shape, _method_name, args)
            return nil if args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            values = []
            args.each do |arg|
              return nil unless arg.is_a?(Type::Constant)

              key = arg.value
              return nil unless key.is_a?(Symbol) || key.is_a?(String)
              return nil unless shape.pairs.key?(key)

              values << shape.pairs[key]
            end
            Type::Combinator.tuple_of(*values)
          end

          # `shape.assoc(key)` — returns `Tuple[Constant[k], V]` for a
          # known key, `Constant[nil]` for a missing key.
          def hash_assoc(shape, _method_name, args)
            return nil unless args.size == 1
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            arg = args.first
            return nil unless arg.is_a?(Type::Constant)

            key = arg.value
            return nil unless key.is_a?(Symbol) || key.is_a?(String)
            return Type::Combinator.constant_of(nil) unless shape.pairs.key?(key)

            Type::Combinator.tuple_of(Type::Combinator.constant_of(key), shape.pairs[key])
          end

          # `shape.rassoc(value)` — reverse of `assoc`: returns
          # `Tuple[Constant[k], V]` for the first key whose VALUE equals
          # the argument, `Constant[nil]` when none match. Folds when every
          # value is a `Constant` so equality is decidable (mirrors
          # `hash_key`, which returns only the key).
          def hash_rassoc(shape, _method_name, args)
            return nil unless args.size == 1
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?
            return nil unless shape.pairs.values.all?(Type::Constant)

            arg = args.first
            return nil unless arg.is_a?(Type::Constant)

            pair = shape.pairs.find { |_k, v| v.value == arg.value }
            return Type::Combinator.constant_of(nil) if pair.nil?

            Type::Combinator.tuple_of(Type::Combinator.constant_of(pair.first), pair.last)
          end

          # `shape.key(value)` — reverse lookup. Folds when every
          # value is a `Constant` so equality is decidable: returns
          # `Constant[k]` for the first matching key, `Constant[nil]`
          # when no value matches.
          def hash_key(shape, _method_name, args)
            return nil unless args.size == 1
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?
            return nil unless shape.pairs.values.all?(Type::Constant)

            arg = args.first
            return nil unless arg.is_a?(Type::Constant)

            pair = shape.pairs.find { |_k, v| v.value == arg.value }
            Type::Combinator.constant_of(pair&.first)
          end

          # `shape.has_value?(v)` / `value?(v)` — folds to
          # `Constant[true/false]` when every value is a `Constant`
          # (so equality is decidable) and the argument is a
          # `Constant`.
          def hash_has_value?(shape, _method_name, args)
            return nil unless args.size == 1
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?
            return nil unless shape.pairs.values.all?(Type::Constant)

            arg = args.first
            return nil unless arg.is_a?(Type::Constant)

            found = shape.pairs.values.any? { |v| v.value == arg.value }
            Type::Combinator.constant_of(found)
          end

          # `shape.default` / `default_proc` — a literal `HashShape`
          # carries no default value or proc, so both fold to
          # `Constant[nil]`. `default` accepts an optional key
          # argument (still returns the default), `default_proc`
          # takes none — the `args.size <= 1` guard covers both.
          def hash_default(shape, _method_name, args)
            return nil unless args.size <= 1
            return nil unless shape.closed?

            Type::Combinator.constant_of(nil)
          end

          # `shape < other` / `<=` / `>` / `>=` — Hash containment
          # comparison. Both sides must be closed `HashShape`s whose
          # values are all `Constant` (so pair equality is
          # decidable). `<` / `>` are proper-subset / -superset.
          def hash_compare(shape, method_name, args)
            return nil unless args.size == 1
            return nil unless shape.closed? && shape.optional_keys.empty?

            other = args.first
            return nil unless other.is_a?(Type::HashShape)
            return nil unless other.closed? && other.optional_keys.empty?

            left = constant_pairs(shape)
            right = constant_pairs(other)
            return nil if left.nil? || right.nil?

            Type::Combinator.constant_of(hash_containment(method_name, left, right))
          end

          # Unwraps a closed shape's pairs to a plain Ruby Hash of
          # `key => value` for value-equality comparison. Returns nil
          # when any value is not a `Constant`.
          def constant_pairs(shape)
            return nil unless shape.pairs.values.all?(Type::Constant)

            shape.pairs.transform_values(&:value)
          end

          def hash_containment(method_name, left, right)
            case method_name
            when :<  then hash_proper_subset?(left, right)
            when :<= then hash_subset?(left, right)
            when :>  then hash_proper_subset?(right, left)
            when :>= then hash_subset?(right, left)
            end
          end

          def hash_subset?(left, right)
            left.all? { |k, v| right.key?(k) && right[k] == v }
          end

          def hash_proper_subset?(left, right)
            left.size < right.size && hash_subset?(left, right)
          end

          # `shape.has_key?(k)` / `key?(k)` / `member?(k)` /
          # `include?(k)` — folds to `Constant[true/false]` when
          # the argument is a `Constant[Symbol|String]` and the
          # shape is closed with no optional keys.
          def hash_has_key?(shape, _method_name, args)
            return nil unless args.size == 1
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            arg = args.first
            return nil unless arg.is_a?(Type::Constant)

            key = arg.value
            return nil unless key.is_a?(Symbol) || key.is_a?(String)

            Type::Combinator.constant_of(shape.pairs.key?(key))
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

          # `shape.first` — returns the first `[k, v]` pair as a
          # 2-Tuple, or `Constant[nil]` when the shape is empty.
          # Folds only on closed shapes with no optional keys
          # (open shapes might contribute extra keys at runtime).
          def hash_first(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?
            return Type::Combinator.constant_of(nil) if shape.pairs.empty?

            key, value = shape.pairs.first
            Type::Combinator.tuple_of(Type::Combinator.constant_of(key), value)
          end

          # `shape.flatten` — flattens to `[k_1, v_1, k_2, v_2, …]`
          # at depth 1. Closed shapes only; element order matches
          # the per-key declaration order.
          def hash_flatten(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            elements = shape.pairs.flat_map { |k, v| [Type::Combinator.constant_of(k), v] }
            Type::Combinator.tuple_of(*elements)
          end

          # `shape.compact` — drops every entry whose value is
          # `Constant[nil]`. Folds only when every value is a
          # `Constant` (so the drop set is decidable). Mixed-shape
          # values decline so the RBS tier widens.
          def hash_compact(shape, _method_name, args)
            return nil unless args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?
            return nil unless shape.pairs.values.all?(Type::Constant)

            kept = shape.pairs.reject { |_k, v| v.value.nil? }
            Type::Combinator.hash_shape_of(kept)
          end

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

          # `shape.slice(:a, :b, ...)` — returns a sub-HashShape
          # containing only the specified keys. All arguments must
          # be `Constant[Symbol|String]`. Keys not present in the
          # shape are silently omitted (matching Ruby's runtime
          # semantics — no nil padding). Declines on open shapes
          # or when any argument is not a static key.
          def hash_slice(shape, _method_name, args)
            return nil if args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            requested = []
            args.each do |arg|
              return nil unless arg.is_a?(Type::Constant)

              key = arg.value
              return nil unless key.is_a?(Symbol) || key.is_a?(String)

              requested << key
            end

            Type::Combinator.hash_shape_of(shape.pairs.slice(*requested))
          end

          # `shape.except(:a, :b, ...)` — returns a sub-HashShape
          # with the specified keys removed. All arguments must be
          # `Constant[Symbol|String]`. Keys not present in the shape
          # are silently ignored. Declines on open shapes or when
          # any argument is not a static key.
          def hash_except(shape, _method_name, args)
            return nil if args.empty?
            return nil unless shape.closed?
            return nil unless shape.optional_keys.empty?

            excluded = {}
            args.each do |arg|
              return nil unless arg.is_a?(Type::Constant)

              key = arg.value
              return nil unless key.is_a?(Symbol) || key.is_a?(String)

              excluded[key] = true
            end

            kept = shape.pairs.reject { |k, _v| excluded.key?(k) }
            Type::Combinator.hash_shape_of(kept)
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
