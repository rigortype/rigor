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

      def untyped
        @untyped ||= Dynamic.new(top)
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

      def uppercase_string
        Refined.new(nominal_of("String"), :uppercase)
      end

      def numeric_string
        Refined.new(nominal_of("String"), :numeric)
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

      class << self
        private

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
    end
  end
end
