# frozen_string_literal: true

require_relative "top"
require_relative "bot"
require_relative "dynamic"
require_relative "nominal"
require_relative "singleton"
require_relative "constant"
require_relative "integer_range"
require_relative "tuple"
require_relative "hash_shape"
require_relative "union"
require_relative "difference"
require_relative "refined"
require_relative "intersection"
require_relative "bound_method"

module Rigor
  module Type
    # Factory entry point that routes every public construction through the
    # deterministic normalization rules. Production code paths MUST go
    # through Rigor::Type::Combinator. Direct constructor calls are an
    # internal escape hatch for tests and for combinator's own
    # implementation.
    #
    # See docs/internal-spec/internal-type-api.md and
    # docs/type-specification/normalization.md.
    module Combinator # rubocop:disable Metrics/ModuleLength
      module_function

      def top
        Top.instance
      end

      def bot
        Bot.instance
      end

      # ADR-15 Phase 4b.x — read the eagerly-allocated
      # `@untyped` ivar instead of `||=`. The singleton-class
      # `@untyped = Dynamic.new(top)` initializer runs at module
      # body (below) on the main Ractor at load time. Workers
      # READ the populated ivar without performing the lazy
      # write that non-main Ractors are forbidden from doing.
      def untyped
        @untyped
      end

      # Wraps the static facet in a Dynamic[T] carrier. Idempotent on the
      # static facet so Dynamic[Dynamic[T]] collapses to Dynamic[T] per the
      # value-lattice algebra.
      def dynamic(static_facet)
        return untyped if static_facet.equal?(top)

        facet = static_facet.is_a?(Dynamic) ? static_facet.static_facet : static_facet
        return untyped if facet.is_a?(Top)

        Dynamic.new(facet)
      end

      # Constructs a Nominal type. Slice 4 phase 2d accepts an optional
      # `type_args:` array, an ordered list of Rigor::Type values that
      # carry the receiver's generic instantiation (`Array[Integer]` is
      # `Nominal["Array", [Nominal["Integer"]]]`). Omitting the keyword
      # produces the raw form `Nominal["Array"]`, which is structurally
      # distinct from any applied form.
      def nominal_of(class_name_or_object, type_args: [])
        Nominal.new(resolve_class_name(class_name_or_object), type_args)
      end

      def singleton_of(class_name_or_object)
        Singleton.new(resolve_class_name(class_name_or_object))
      end

      def constant_of(value)
        Constant.new(value)
      end

      # `Object#method(:name)` carrier. Stores the bound
      # `(receiver, method_name)` pair so the dispatcher can
      # substitute the original dispatch at `.call` / `.()` /
      # `[]` time. See {Type::BoundMethod}.
      def bound_method_of(receiver_type, method_name)
        BoundMethod.new(receiver_type: receiver_type, method_name: method_name)
      end

      # Bounded-integer carrier. Each bound is either an `Integer` or
      # one of `:neg_infinity` / `:pos_infinity` (sentinels exposed as
      # `IntegerRange::NEG_INFINITY` / `POS_INFINITY`).
      def integer_range(min, max)
        IntegerRange.new(min, max)
      end

      # Convenience aliases for the most common bounded shapes. The
      # named alias survives roundtrip through `describe` for nicer
      # human-facing output.
      def positive_int
        IntegerRange.new(1, IntegerRange::POS_INFINITY)
      end

      def non_negative_int
        IntegerRange.new(0, IntegerRange::POS_INFINITY)
      end

      def negative_int
        IntegerRange.new(IntegerRange::NEG_INFINITY, -1)
      end

      def non_positive_int
        IntegerRange.new(IntegerRange::NEG_INFINITY, 0)
      end

      def universal_int
        IntegerRange.new(IntegerRange::NEG_INFINITY, IntegerRange::POS_INFINITY)
      end

      # Point-removal refinement carrier (ADR-3 OQ3 Option C). Use
      # `non_empty_string` / `non_zero_int` / `non_empty_array` /
      # `non_empty_hash` for the imported built-in shapes; raw
      # `difference(base, removed)` for ad-hoc refinements an
      # `RBS::Extended` annotation introduces.
      def difference(base, removed)
        Difference.new(base, removed)
      end

      def non_empty_string
        Difference.new(nominal_of("String"), constant_of(""))
      end

      def non_zero_int
        Difference.new(nominal_of("Integer"), constant_of(0))
      end

      # `non-empty-array[T]` requires the element type so the
      # `Nominal[Array, [T]]` projection through Array#first /
      # #last keeps element precision intact. The default
      # `Top` admits any array element when the caller does
      # not have a more specific element type.
      def non_empty_array(element = top)
        Difference.new(
          nominal_of("Array", type_args: [element]),
          tuple_of
        )
      end

      def non_empty_hash(key = top, value = top)
        Difference.new(
          nominal_of("Hash", type_args: [key, value]),
          hash_shape_of({})
        )
      end

      # Predicate-subset refinement carrier (ADR-3 OQ3 Option C,
      # second half). Use `lowercase_string` /
      # `uppercase_string` / `numeric_string` for the imported
      # built-in shapes; raw `refined(base, predicate_id)` for
      # ad-hoc refinements introduced by an `RBS::Extended`
      # annotation or a plugin-contributed predicate.
      def refined(base, predicate_id)
        Refined.new(base, predicate_id)
      end

      def lowercase_string
        Refined.new(nominal_of("String"), :lowercase)
      end

      # Complement of `lowercase-string`: a `String` with at least
      # one non-lowercase character (i.e. `v != v.downcase`).
      # Registered as the paired complement of
      # `:lowercase` in {Refined::COMPLEMENT_PAIRS} so
      # `~lowercase-string` narrows to this carrier instead of
      # falling back to `Difference[String, lowercase-string]`.
      def non_lowercase_string
        Refined.new(nominal_of("String"), :not_lowercase)
      end

      def uppercase_string
        Refined.new(nominal_of("String"), :uppercase)
      end

      # Complement of `uppercase-string`: a `String` with at least
      # one non-uppercase character. Paired with `:uppercase` in
      # {Refined::COMPLEMENT_PAIRS}.
      def non_uppercase_string
        Refined.new(nominal_of("String"), :not_uppercase)
      end

      def numeric_string
        Refined.new(nominal_of("String"), :numeric)
      end

      # Complement of `numeric-string`: a `String` that is not
      # accepted by Rigor's Ruby numeric-string predicate
      # (contains at least one non-digit, has a malformed numeric
      # form, etc.). Paired with `:numeric` in
      # {Refined::COMPLEMENT_PAIRS}.
      def non_numeric_string
        Refined.new(nominal_of("String"), :not_numeric)
      end

      def decimal_int_string
        Refined.new(nominal_of("String"), :decimal_int)
      end

      def octal_int_string
        Refined.new(nominal_of("String"), :octal_int)
      end

      def hex_int_string
        Refined.new(nominal_of("String"), :hex_int)
      end

      # `literal-string` — a `String` that is statically known to
      # come from a source-code literal (or a composition of
      # literals). v0.0.9 tracks this flow through interpolation
      # `"#{...}"`, leaving propagation through `+` / `<<` to a
      # later slice. Every `Constant<String>` is implicitly
      # literal-string-compatible; the carrier exists for cases
      # where the concrete value is unknown but literal-ness has
      # been established (an RBS::Extended `return: literal-string`
      # annotation, or interpolation over literal-bearing parts).
      def literal_string
        Refined.new(nominal_of("String"), :literal_string)
      end

      # `non-empty-literal-string` = `non-empty-string ∩ literal-string`.
      # Composes the point-removal half (`Difference[String, ""]`)
      # with the predicate-subset half. Both members erase to
      # `String`.
      def non_empty_literal_string
        intersection(non_empty_string, literal_string)
      end

      # Recognises the carriers that participate in literal-string
      # flow tracking: any `Constant<String>` (constants are literal
      # by construction), the `literal-string` Refined carrier, an
      # `Intersection` containing `literal-string`, or a `Union`
      # whose every member qualifies. Used by
      # `ExpressionTyper#type_of_interpolated_string` and the
      # `LiteralStringFolding` dispatcher tier so propagation
      # through interpolation and `+`/`*` composition stays
      # consistent.
      def literal_string_compatible?(type)
        case type
        when Constant then type.value.is_a?(String)
        when Refined then literal_string_carrier?(type)
        when Intersection then type.members.any? { |m| literal_string_compatible?(m) }
        when Union then type.members.all? { |m| literal_string_compatible?(m) }
        else false
        end
      end

      def literal_string_carrier?(refined)
        refined.predicate_id == :literal_string &&
          refined.base.is_a?(Nominal) &&
          refined.base.class_name == "String"
      end

      # Normalised intersection. Flattens nested Intersections,
      # drops `Top` members, collapses to `Bot` if any member is
      # `Bot`, deduplicates structurally-equal members, sorts the
      # survivors by `describe(:short)`, and collapses 0-/1-member
      # results so a degenerate intersection never reaches the
      # carrier. See ADR-3 OQ3 for the rationale; the lattice
      # algebra is in
      # [`value-lattice.md`](docs/type-specification/value-lattice.md).
      def intersection(*members)
        collapse_intersection(normalised_intersection_members(members))
      end

      # `non-empty-lowercase-string` = non-empty-string ∩
      # lowercase-string. Composes the point-removal half
      # (`Difference[String, ""]`) with the predicate-subset half
      # (`Refined[String, :lowercase]`). Both members erase to
      # `String` so the carrier's RBS erasure is unambiguous.
      def non_empty_lowercase_string
        intersection(non_empty_string, lowercase_string)
      end

      def non_empty_uppercase_string
        intersection(non_empty_string, uppercase_string)
      end

      # Constructs a heterogeneous, fixed-arity Tuple from positional
      # element types. `tuple_of()` produces the empty tuple `Tuple[]`,
      # which is structurally distinct from the raw `Nominal[Array]`.
      def tuple_of(*elements)
        Tuple.new(elements)
      end

      # Constructs a HashShape from an ordered (Symbol|String) -> type
      # map. The argument is duped and frozen by the carrier; callers
      # MUST NOT rely on later mutation.
      def hash_shape_of(pairs = nil, **options)
        if pairs.nil?
          pairs = options
          options = {}
        end

        HashShape.new(pairs, **options)
      end

      # Normalized union. Flattens nested Unions, deduplicates structurally
      # equal members, drops Bot, and collapses 0/1-member results.
      def union(*types)
        collapse_union(normalized_union_members(types))
      end

      # `key_of[T]` type function — projects the type-level
      # union of `T`'s known keys. Recognised shapes:
      #
      # - `Type::HashShape{a: A, b: B}` → `Constant<:a> | Constant<:b>`.
      # - `Type::Tuple[A, B, C]` → `Constant<0> | Constant<1> | Constant<2>`.
      # - `Type::Nominal["Hash", [K, V]]` → `K` (untyped if absent).
      # - `Type::Nominal["Array", [E]]` → `non-negative-int`.
      # - `Type::Constant` whose value is a Hash / Array / Range —
      #   project through the literal's per-element keys.
      #
      # Other inputs (`Top`, `Dynamic`, untyped Nominals, `Union`,
      # `Refined`, `Difference`, `Intersection`) project to `top`
      # so the type function always returns a value — callers may
      # narrow further when they know more.
      def key_of(type)
        case type
        when HashShape then hash_shape_keys(type)
        when Tuple then tuple_indices(type)
        when Nominal then nominal_keys(type)
        when Constant then constant_keys(type.value)
        else top
        end
      end

      # `value_of[T]` type function — projects the type-level
      # union of `T`'s known values. Mirror of `key_of`:
      #
      # - `Type::HashShape{a: A, b: B}` → `A | B`.
      # - `Type::Tuple[A, B, C]` → `A | B | C`.
      # - `Type::Nominal["Hash", [K, V]]` → `V` (untyped if absent).
      # - `Type::Nominal["Array", [E]]` → `E` (untyped if absent).
      # - `Type::Constant` whose value is a Hash / Array / Range —
      #   union of `Constant<…>` for each element.
      def value_of(type)
        case type
        when HashShape then hash_shape_values(type)
        when Tuple then tuple_values(type)
        when Nominal then nominal_values(type)
        when Constant then constant_values(type.value)
        else top
        end
      end

      # `int_mask[1, 2, 4]` type function — every Integer
      # representable by a bitwise OR over the listed flags,
      # including 0. The closure of `[1, 2, 4]` is
      # `{0, 1, 2, 3, 4, 5, 6, 7}`. Returns a `Union[Constant…]`
      # for small closures and a covering `IntegerRange` once
      # the cardinality exceeds `INT_MASK_UNION_LIMIT`. Returns
      # `nil` when the input is malformed (non-integer flag,
      # negative flag, or too many flags to compute the closure
      # cheaply).
      INT_MASK_FLAG_LIMIT = 6
      INT_MASK_UNION_LIMIT = 16
      private_constant :INT_MASK_FLAG_LIMIT, :INT_MASK_UNION_LIMIT

      def int_mask(flags)
        return nil unless flags.is_a?(Array) && flags.all?(Integer)
        return nil if flags.any?(&:negative?)
        return nil if flags.size > INT_MASK_FLAG_LIMIT

        values = compute_int_mask_closure(flags)
        return nil if values.nil?

        if values.size <= INT_MASK_UNION_LIMIT
          union(*values.map { |v| constant_of(v) })
        else
          integer_range(values.min, values.max)
        end
      end

      # `int_mask_of[T]` — derives the int_mask closure from
      # a finite integer-literal type:
      # `Constant<n>` (single flag), `Union[Constant…]` (every
      # member must be a `Constant<Integer>`). Returns nil for
      # incompatible inputs (Top, Dynamic, IntegerRange, mixed
      # member shapes).
      def int_mask_of(type)
        flags = extract_constant_int_set(type)
        return nil if flags.nil?

        int_mask(flags)
      end

      # `T[K]` indexed-access type operator — extracts the type
      # at index / key `K` from a structured `T`:
      #
      # - `Tuple[A, B, C][Constant<i>]` → `A` / `B` / `C` (out-of-
      #   range indices return `Top` for safety).
      # - `HashShape{a: A, b: B}[Constant<:a>]` → `A`.
      # - `Nominal[Hash, [K, V]][_]` → `V` (untyped if absent).
      # - `Nominal[Array, [E]][_]` → `E` (untyped if absent).
      #
      # Other shapes (`Top`, `Dynamic`, untyped Nominals,
      # `Union`, `Refined`, `Difference`, `Intersection`)
      # project to `Top`. The key argument is itself a
      # `Type::t`; only `Type::Constant` keys produce a precise
      # answer.
      def indexed_access(type, key)
        case type
        when Tuple then tuple_indexed_access(type, key)
        when HashShape then hash_shape_indexed_access(type, key)
        when Nominal then nominal_indexed_access(type)
        when Constant then constant_indexed_access(type.value, key)
        else top
        end
      end

      # `pick_of[T, K]` shape-projection — keeps only the entries
      # of `T` whose key is in the literal-key set extracted from
      # `K`. ADR-13 § "Shape projection / Restriction and removal".
      #
      # Phase A handles `Type::HashShape` (literal-key K).
      # Phase B (slice 5) extends to `Type::Tuple` (integer-index
      # K) — `pick_of[Tuple[A, B, C], 0 | 2]` evaluates to
      # `Tuple[A, C]`. Non-shape inputs (`Type::Nominal`, etc.)
      # return `type` unchanged ("lossy degradation"; the
      # `dynamic.shape.lossy-projection` diagnostic that flags
      # the boundary lands when caller-side diagnostic threading
      # arrives).
      def pick_of(type, keys)
        case type
        when HashShape then hash_shape_pick(type, keys)
        when Tuple     then tuple_pick(type, keys)
        else type
        end
      end

      # `omit_of[T, K]` shape-projection — dual of {pick_of}.
      # Drops the entries / positions whose key (or index, for a
      # `Tuple`) is in the literal-key set extracted from `K`.
      def omit_of(type, keys)
        case type
        when HashShape then hash_shape_omit(type, keys)
        when Tuple     then tuple_omit(type, keys)
        else type
        end
      end

      # `partial_of[T]` shape-projection — flips every required
      # entry of `T` to optional. ADR-13 § "Required-ness flips".
      # Does NOT add `nil` to value types — Rigor's HashShape
      # distinguishes "key absent" from "key present with nil
      # value", so flipping required-ness is sufficient.
      def partial_of(type)
        return type unless type.is_a?(HashShape)

        HashShape.new(
          type.pairs,
          required_keys: [],
          optional_keys: type.pairs.keys,
          read_only_keys: type.read_only_keys,
          extra_keys: type.extra_keys
        )
      end

      # `required_of[T]` shape-projection — inverse of
      # {partial_of}; flips every optional entry to required.
      def required_of(type)
        return type unless type.is_a?(HashShape)

        HashShape.new(
          type.pairs,
          required_keys: type.pairs.keys,
          optional_keys: [],
          read_only_keys: type.read_only_keys,
          extra_keys: type.extra_keys
        )
      end

      # `readonly_of[T]` shape-projection — marks every entry of
      # `T` as read-only in the current view. View-level only —
      # does NOT prove the underlying Ruby Hash is frozen.
      def readonly_of(type)
        return type unless type.is_a?(HashShape)

        HashShape.new(
          type.pairs,
          required_keys: type.required_keys,
          optional_keys: type.optional_keys,
          read_only_keys: type.pairs.keys,
          extra_keys: type.extra_keys
        )
      end

      # Predicate that a shape-projection (`pick_of`, `omit_of`,
      # `partial_of`, `required_of`, `readonly_of`) would degrade
      # to "input unchanged" on this carrier. Callers consult
      # this BEFORE invoking the projection so they can emit a
      # `dynamic.shape.lossy-projection` diagnostic at the site
      # where the projection was authored.
      #
      # `HashShape` and `Tuple` carry shape-level information
      # the projections honour; every other carrier is lossy.
      # Slice 5b wires diagnostic emission through `RbsExtended`
      # / parser callers; this predicate stands alone in slice 5
      # for unit-test coverage and future composition.
      def shape_projection_lossy?(type)
        !type.is_a?(HashShape) && !type.is_a?(Tuple)
      end

      class << self # rubocop:disable Metrics/ClassLength
        private

        def hash_shape_keys(shape)
          return Bot.instance if shape.pairs.empty?

          union(*shape.pairs.keys.map { |k| constant_of(k) })
        end

        def hash_shape_values(shape)
          return Bot.instance if shape.pairs.empty?

          union(*shape.pairs.values)
        end

        def tuple_indices(tuple)
          return Bot.instance if tuple.elements.empty?

          union(*tuple.elements.each_index.map { |i| constant_of(i) })
        end

        def tuple_values(tuple)
          return Bot.instance if tuple.elements.empty?

          union(*tuple.elements)
        end

        def nominal_keys(nominal)
          case nominal.class_name
          when "Hash"
            nominal.type_args.first || untyped
          when "Array"
            non_negative_int
          else
            top
          end
        end

        def nominal_values(nominal)
          case nominal.class_name
          when "Hash"
            nominal.type_args[1] || untyped
          when "Array"
            nominal.type_args.first || untyped
          else
            top
          end
        end

        # `Type::Constant` only carries scalar literals (Integer
        # / Float / String / Symbol / Range / Rational / Complex
        # / true / false / nil); Array and Hash literals become
        # Tuple / HashShape carriers earlier in the typer. Range
        # is the only scalar with meaningful key/value
        # projections.
        def compute_int_mask_closure(flags)
          unique = flags.uniq
          return [0] if unique.empty?

          # Closure under bitwise OR over a set of non-negative
          # integers is `0..(max_or_value)` only when the flags
          # are bit-disjoint; otherwise it's a strict subset.
          # Enumerate every subset's OR.
          closure = Set.new([0])
          unique.each do |flag|
            closure |= closure.map { |c| c | flag }
          end
          closure.to_a.sort
        end

        def extract_constant_int_set(type)
          case type
          when Constant
            type.value.is_a?(Integer) ? [type.value] : nil
          when Union
            type.members.all?(Constant) ? type.members.map(&:value).grep(Integer) : nil
          end
        end

        # Literal-key set extraction for {pick_of} / {omit_of}.
        # Accepts `Constant<Symbol|String>` or `Union[Constant…]`
        # where every member is such a Constant. Returns `nil`
        # when the shape can't be reduced to a finite key set
        # (untyped, Top, Difference, Refined, mixed-kind union,
        # etc.) — callers degrade to "input unchanged" per
        # ADR-13's lossy-projection rule.
        def extract_constant_key_set(type)
          case type
          when Constant then constant_key_set(type)
          when Union    then union_key_set(type)
          end
        end

        def constant_key_set(type)
          literal_key?(type.value) ? [type.value] : nil
        end

        def union_key_set(type)
          return nil unless type.members.all?(Constant)

          values = type.members.map(&:value)
          values.all? { |v| literal_key?(v) } ? values : nil
        end

        def literal_key?(value)
          value.is_a?(Symbol) || value.is_a?(String)
        end

        # Rebuild a {HashShape} from the subset of `keys` the
        # caller decided to keep. Preserves required / optional /
        # read-only classification AND the extra-keys policy of
        # the source shape; entries dropped from `pairs` also
        # drop from each policy list. Used by both {pick_of}
        # (intersection with K) and {omit_of} (set difference).
        def rebuild_hash_shape_with_keys(shape, kept_keys)
          HashShape.new(
            shape.pairs.slice(*kept_keys),
            required_keys: shape.required_keys.select { |k| kept_keys.include?(k) },
            optional_keys: shape.optional_keys.select { |k| kept_keys.include?(k) },
            read_only_keys: shape.read_only_keys.select { |k| kept_keys.include?(k) },
            extra_keys: shape.extra_keys
          )
        end

        def hash_shape_pick(type, keys)
          key_set = extract_constant_key_set(keys)
          return type if key_set.nil?

          rebuild_hash_shape_with_keys(type, type.pairs.keys & key_set)
        end

        def hash_shape_omit(type, keys)
          key_set = extract_constant_key_set(keys)
          return type if key_set.nil?

          rebuild_hash_shape_with_keys(type, type.pairs.keys - key_set)
        end

        # ADR-13 slice 5 — Tuple support. `K` MUST be a
        # `Constant<Integer>` or `Union[Constant<Integer>, …]`;
        # other K shapes (or non-integer Constants in a Union)
        # return the input unchanged. Negative or out-of-range
        # indices are dropped silently per slice 5's permissive
        # take — surface diagnostics are slice 5b material.
        def tuple_pick(type, keys)
          index_set = extract_tuple_index_set(keys, type.elements.size)
          return type if index_set.nil?

          Tuple.new(index_set.map { |i| type.elements[i] })
        end

        def tuple_omit(type, keys)
          index_set = extract_tuple_index_set(keys, type.elements.size)
          return type if index_set.nil?

          dropped = index_set.to_a
          Tuple.new(type.elements.each_with_index.reject { |_, i| dropped.include?(i) }.map(&:first))
        end

        # Extracts a sorted, deduplicated set of in-range integer
        # indices from a `Constant<Integer>` / `Union[Constant<Integer>, …]`
        # carrier. Out-of-range indices are dropped silently; the
        # caller decides whether an empty result still means
        # "lossy projection" (current pick / omit just produce an
        # empty Tuple).
        def extract_tuple_index_set(type, size)
          flags = extract_constant_int_set(type)
          return nil if flags.nil?

          flags.uniq.select { |i| i >= 0 && i < size }.sort
        end

        def tuple_indexed_access(tuple, key)
          return top unless key.is_a?(Constant) && key.value.is_a?(Integer)

          index = key.value
          return top if index.negative? || index >= tuple.elements.size

          tuple.elements[index]
        end

        def hash_shape_indexed_access(shape, key)
          return top unless key.is_a?(Constant)

          shape.pairs[key.value] || top
        end

        def nominal_indexed_access(nominal)
          case nominal.class_name
          when "Hash" then nominal.type_args[1] || untyped
          when "Array" then nominal.type_args.first || untyped
          else top
          end
        end

        def constant_indexed_access(value, key)
          return top unless key.is_a?(Constant)

          if value.is_a?(Range) && key.value.is_a?(Integer)
            element = value.to_a[key.value]
            return constant_of(element) unless element.nil?
          end

          top
        end

        def constant_keys(value)
          return non_negative_int if value.is_a?(Range) && value.begin.is_a?(Integer)

          top
        end

        def constant_values(value)
          return range_value_of(value) if value.is_a?(Range)

          top
        end

        def range_value_of(range)
          beg = range.begin
          en  = range.end
          return top unless beg.is_a?(Integer) && en.is_a?(Integer)

          upper = range.exclude_end? ? en - 1 : en
          return Bot.instance if upper < beg

          integer_range(beg, upper)
        end

        def normalized_union_members(types)
          flattened = []
          types.each { |t| flatten_into(flattened, t) }
          flattened.reject! { |t| t.is_a?(Bot) }

          return [top] if flattened.any?(Top)

          unique_members(flattened)
        end

        def unique_members(types)
          types.each_with_object([]) do |type, unique|
            unique << type unless unique.any? { |member| member == type }
          end
        end

        def collapse_union(types)
          case types.size
          when 0 then bot
          when 1 then types.first
          else Union.new(sort_members(types))
          end
        end

        # Symmetric counterparts to the Union normalisers. The
        # absorbing element is `Bot` (anything intersected with
        # nothing is nothing) and the identity element is `Top`
        # (intersecting with the universal type is a no-op).
        def normalised_intersection_members(types)
          flattened = []
          types.each { |t| flatten_intersection_into(flattened, t) }
          return [bot] if flattened.any?(Bot)

          flattened.reject! { |t| t.is_a?(Top) }
          unique_members(flattened)
        end

        def collapse_intersection(types)
          case types.size
          when 0 then top
          when 1 then types.first
          else Intersection.new(sort_members(types))
          end
        end

        def flatten_intersection_into(acc, type)
          if type.is_a?(Intersection)
            type.members.each { |m| flatten_intersection_into(acc, m) }
          else
            acc << type
          end
        end

        def resolve_class_name(class_name_or_object)
          name =
            case class_name_or_object
            when Module then class_name_or_object.name
            when String then class_name_or_object
            else
              raise ArgumentError, "expected Class/Module or String, got #{class_name_or_object.class}"
            end

          raise ArgumentError, "anonymous class has no name" if name.nil? || name.empty?

          name
        end

        def flatten_into(acc, type)
          if type.is_a?(Union)
            type.members.each { |m| flatten_into(acc, m) }
          else
            acc << type
          end
        end

        def sort_members(members)
          members.sort_by { |m| m.describe(:short) }
        end
      end

      # ADR-15 Phase 4b.x — eager-allocate the singleton
      # `Dynamic[Top]` carrier on the main Ractor at load time.
      # The `untyped` reader above just returns this ivar.
      @untyped = Dynamic.new(Top.instance)
    end
  end
end
