# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module Narrowing
      # ADR-116 C1 — the complements, finite domains and integer-range algebra that `Narrowing`'s type-level
      # entries sit on: the complement of a `Difference`, `IntegerRange`, `Intersection` or `Refined` within a
      # current type ({.complement_difference}, {.complement_integer_range}, {.complement_intersection},
      # {.complement_refined}), the falsey and nil fragments of the carriers the fast paths leave alone, and the
      # `==` / `!=` narrowing over a finite trusted-literal domain or a singleton.
      #
      # Plain functions on `Rigor::Type` values: no scope, no environment. The one call back is
      # `Narrowing.narrow_not_refinement`, which {.complement_intersection} applies to each member of an
      # intersection. Everything here is reached through `Narrowing`'s own entries (`narrow_truthy`,
      # `narrow_falsey`, `narrow_nil`, `narrow_equal`, `narrow_not_equal`, `narrow_not_refinement`) and the
      # equality predicate analyser.
      # rubocop:disable-next Metrics/ModuleLength
      module Complements
        module_function

        TRUSTED_EQUALITY_LITERAL_CLASSES = [String, Symbol, Integer, TrueClass, FalseClass, NilClass].freeze
        SINGLETON_LITERAL_CLASSES = [TrueClass, FalseClass, NilClass].freeze
        private_constant :TRUSTED_EQUALITY_LITERAL_CLASSES, :SINGLETON_LITERAL_CLASSES

        # Complement of `Difference[base, Constant[v]]` within `current_type`. Walks the
        # current type's union members, keeps each member disjoint from `base` (those values
        # were never in the refinement to begin with), and adds the removed-value `Constant[v]`
        # exactly once when any current member covers it. Members that are fully contained in
        # the refinement (i.e. inside `base` and NOT equal to the removed value) are dropped —
        # they are exactly the values the negation excludes.
        def complement_difference(current_type, difference)
          base = difference.base
          removed = difference.removed
          parts = current_type.is_a?(Type::Union) ? current_type.members : [current_type]

          survivors = []
          add_removed = false
          parts.each do |part|
            if base_disjoint?(base, part)
              survivors << part
            elsif part_covers_constant?(part, removed)
              add_removed = true
            end
          end
          survivors << removed if add_removed

          return current_type if survivors.empty?

          Type::Combinator.union(*survivors)
        end

        def base_disjoint?(base, part)
          base.accepts(part, mode: :gradual).no?
        end

        def part_covers_constant?(part, constant)
          result = part.accepts(constant, mode: :gradual)
          result.yes? || result.maybe?
        end

        # Complement of an `IntegerRange[a, b]` within `current_type`. Splits the range
        # complement into the two open halves `Integer[..a-1]` and `Integer[b+1..]` (skipping a
        # half when its bound is infinity), then intersects each half with the integer-domain
        # parts of `current_type`. Non-integer parts of a Union receiver (nil, String, …)
        # survive unchanged.
        def complement_integer_range(current_type, range)
          halves = integer_range_complement_halves(range)
          parts = current_type.is_a?(Type::Union) ? current_type.members : [current_type]

          survivors = []
          parts.each do |part|
            if integer_member?(part)
              halves.each do |half|
                meet = intersect_integer_part(part, half)
                survivors << meet unless meet.nil? || meet.is_a?(Type::Bot)
              end
            else
              survivors << part
            end
          end

          return current_type if survivors.empty?

          Type::Combinator.union(*survivors)
        end

        # Returns the two open halves of an IntegerRange's complement: the left half
        # `Integer[..a-1]` (when `a` is finite) and the right half `Integer[b+1..]` (when `b` is finite).
        # Universal ranges (both bounds infinite) yield an empty array — the complement is
        # empty.
        def integer_range_complement_halves(range)
          halves = []
          left_max = range.min
          right_min = range.max

          if left_max.is_a?(Integer)
            halves << Type::Combinator.integer_range(Type::IntegerRange::NEG_INFINITY, left_max - 1)
          end
          if right_min.is_a?(Integer)
            halves << Type::Combinator.integer_range(right_min + 1, Type::IntegerRange::POS_INFINITY)
          end
          halves
        end

        def integer_member?(part)
          case part
          when Type::Constant then part.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then part.class_name == "Integer"
          else false
          end
        end

        # Intersect an integer-domain part with a complement half-range. For a
        # Nominal[Integer] receiver the meet is the half itself; for an existing IntegerRange
        # the meet narrows both bounds; for a Constant[Integer] the meet is the constant when
        # the half covers it, otherwise nil.
        def intersect_integer_part(part, half)
          case part
          when Type::Nominal
            half
          when Type::IntegerRange
            integer_range_meet(part, half)
          when Type::Constant
            half.covers?(part.value) ? part : nil
          end
        end

        def integer_range_meet(left, right)
          low = numeric_to_bound([integer_bound_value(left.min), integer_bound_value(right.min)].max)
          high = numeric_to_bound([integer_bound_value(left.max), integer_bound_value(right.max)].min)
          return nil if integer_range_disjoint?(low, high)

          Type::Combinator.integer_range(low, high)
        end

        def integer_bound_value(bound)
          return -Float::INFINITY if bound == Type::IntegerRange::NEG_INFINITY
          return Float::INFINITY if bound == Type::IntegerRange::POS_INFINITY

          bound
        end

        def numeric_to_bound(value)
          return Type::IntegerRange::NEG_INFINITY if value == -Float::INFINITY
          return Type::IntegerRange::POS_INFINITY if value == Float::INFINITY

          value.to_i
        end

        def integer_range_disjoint?(low, high)
          return false if low == Type::IntegerRange::NEG_INFINITY
          return false if high == Type::IntegerRange::POS_INFINITY

          low > high
        end

        # De Morgan: `D \ (M1 ∩ M2 ∩ …) = (D \ M1) ∪ (D \ M2) ∪ …`. Each member's complement is
        # computed independently within `current_type` and the results are unioned. Members the
        # algebra cannot complement contribute `current_type` itself, so the union widens to
        # `current_type` overall — sound but imprecise.
        def complement_intersection(current_type, intersection)
          per_member = intersection.members.map do |member|
            Narrowing.narrow_not_refinement(current_type, member)
          end
          Type::Combinator.union(*per_member)
        end

        # v0.0.7 — complement of a `Refined[base, predicate]` refinement within `current_type`.
        # Walks the current type's union members; parts that are disjoint from the refinement's
        # base survive unchanged; parts equal to the refinement itself drop entirely (they were
        # exactly the negated subset); parts that overlap the base contribute `Difference[part,
        # refined]` so downstream narrowing knows the refinement subset is excluded.
        #
        # v0.0.9 — when the predicate has a registered complement (see
        # {Type::Refined::COMPLEMENT_PAIRS}) and the part is exactly the refinement's base, the
        # narrowing returns `Refined[base, complement_predicate]` instead of
        # `Difference[base, refined]`. This is the `~T` symmetry the spec promises:
        # `~lowercase-string` narrows `String` to `non-lowercase-string` rather than
        # `Difference[String, lowercase-string]`.
        #
        # Predicates without a registered complement still fall back to the imprecise but sound
        # `Difference[part, refined]` carrier so behaviour is unchanged for untouched call
        # sites.
        def complement_refined(current_type, refined)
          complement = registered_complement_for(refined)
          parts = current_type.is_a?(Type::Union) ? current_type.members : [current_type]
          survivors = parts.filter_map { |part| complement_refined_part(part, refined, complement) }
          return current_type if survivors.empty?

          Type::Combinator.union(*survivors)
        end

        def complement_refined_part(part, refined, complement)
          return nil if part == refined
          return part if base_disjoint?(refined.base, part)
          return complement if complement && part == refined.base

          Type::Combinator.difference(part, refined)
        end

        def registered_complement_for(refined)
          complement_id = refined.complement_predicate_id
          return nil if complement_id.nil?

          Type::Combinator.refined(refined.base, complement_id)
        end

        def falsey_value?(value)
          value.nil? || value == false
        end

        def falsey_nominal?(nominal)
          %w[NilClass FalseClass].include?(nominal.class_name)
        end

        # Carriers that the {.narrow_falsey} fast path does not handle by structural
        # inspection. Singleton/Tuple/HashShape inhabit truthy values, so their falsey fragment
        # is empty; everything else (Top, Dynamic, Bot, and any future carrier) stays
        # conservative and is returned unchanged.
        def narrow_falsey_other(type)
          case type
          when Type::Singleton, Type::Tuple, Type::HashShape then Type::Combinator.bot
          else type
          end
        end

        # Carriers that the {.narrow_nil} fast path does not handle by structural inspection.
        # Top/Dynamic narrow to `Constant[nil]` so dispatch resolves through `NilClass`; Bot is
        # its own nil fragment; the remaining carriers (Singleton, Tuple, HashShape, and any
        # future carrier whose inhabitants exclude nil) collapse to `Bot`.
        def narrow_nil_other(type)
          case type
          when Type::Dynamic, Type::Top then Type::Combinator.constant_of(nil)
          when Type::Bot then type
          else Type::Combinator.bot
          end
        end

        def trusted_equality_literal?(literal)
          literal.is_a?(Type::Constant) &&
            TRUSTED_EQUALITY_LITERAL_CLASSES.include?(literal.value.class)
        end

        def singleton_literal?(literal)
          SINGLETON_LITERAL_CLASSES.include?(literal.value.class)
        end

        def finite_trusted_literal_domain?(type)
          case type
          when Type::Bot then true
          when Type::Constant then trusted_equality_literal?(type)
          when Type::Union then type.members.all? { |member| finite_trusted_literal_domain?(member) }
          else false
          end
        end

        def narrow_finite_equal(type, literal)
          case type
          when Type::Bot then type
          when Type::Constant then type == literal ? type : Type::Combinator.bot
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_finite_equal(member, literal) })
          else Type::Combinator.bot
          end
        end

        def narrow_finite_not_equal(type, literal)
          case type
          when Type::Constant then type == literal ? Type::Combinator.bot : type
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_finite_not_equal(member, literal) })
          else type
          end
        end

        def narrow_singleton_equal(type, literal)
          case type
          when Type::Constant then type == literal ? type : Type::Combinator.bot
          when Type::Nominal then singleton_nominal_matches?(type, literal) ? type : Type::Combinator.bot
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_singleton_equal(member, literal) })
          else narrow_singleton_equal_other(type)
          end
        end

        def narrow_singleton_equal_other(type)
          case type
          when Type::Singleton, Type::Tuple, Type::HashShape then Type::Combinator.bot
          else type
          end
        end

        def narrow_singleton_not_equal(type, literal)
          case type
          when Type::Constant then type == literal ? Type::Combinator.bot : type
          when Type::Nominal then singleton_nominal_matches?(type, literal) ? Type::Combinator.bot : type
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_singleton_not_equal(member, literal) })
          else type
          end
        end

        def singleton_nominal_matches?(nominal, literal)
          case literal.value
          when nil then nominal.class_name == "NilClass"
          when true then nominal.class_name == "TrueClass"
          when false then nominal.class_name == "FalseClass"
          else false
          end
        end

        private_class_method :base_disjoint?, :part_covers_constant?, :integer_range_complement_halves,
                             :integer_member?, :intersect_integer_part, :integer_range_meet, :integer_bound_value,
                             :numeric_to_bound, :integer_range_disjoint?, :complement_refined_part,
                             :registered_complement_for, :narrow_singleton_equal_other, :singleton_nominal_matches?
      end
    end
  end
end
