# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #1357 — `Kernel#Rational(x, 1)` converts its argument. CRuby's `nurat_convert` returns a
      # `Rational` for a `Float` / `Integer` / `Rational` / `String`-free numerator and for a `BigDecimal` (which
      # has `to_r`; NaN and Infinity raise). A `Complex` is unwrapped only when its imaginary part is an exact
      # zero, otherwise `a / 1` comes back, a `Complex`, so a `Complex` numerator answers `Rational | Complex`.
      # The core RBS spells the `1`-denominator form `[T < Numeric] (T value, 1) -> T`, which binds `T` to the
      # argument's own class and read `Rational(f, 1)` as a `Float`. Any other numerator (a user `Numeric`
      # without `to_r`) keeps the RBS answer.
      module UnitDenominatorRational
        module_function

        CONVERTING = Set["Float", "Integer", "Rational", "BigDecimal"].freeze
        private_constant :CONVERTING

        # Answers `Rational` (or `Rational | Complex`), or nil when the call is not the unit-denominator form.
        def answer(method_name, args)
          return nil unless method_name == :Rational && args.size.between?(2, 3)
          return nil if args.size == 3 && !exception_keyword?(args[2])

          denominator = args[1]
          return nil unless denominator.is_a?(Type::Constant) && denominator.value.eql?(1)

          classes = numerator_classes(args.first)
          return nil if classes.nil?

          members = [Type::Combinator.nominal_of("Rational")]
          members << Type::Combinator.nominal_of("Complex") if classes.include?(:complex)
          Type::Combinator.union(*members)
        end

        # The trailing `exception:` keyword hash: a `HashShape` whose only key is `:exception`. Its value
        # does not change the answer (a Float that cannot convert raises either way).
        def exception_keyword?(type)
          type.is_a?(Type::HashShape) && type.pairs.keys == [:exception]
        end

        # `[:converting]`, `[:complex]` or both for a recognised numerator; nil when any member is unknown.
        def numerator_classes(type)
          case type
          when Type::Union then union_classes(type)
          when Type::IntegerRange then [:converting]
          when Type::Refined then type.base.is_a?(Type::Nominal) ? numerator_classes(type.base) : nil
          when Type::Constant then class_kind(type.value.class.name)
          when Type::Nominal then type.type_args.empty? ? class_kind(type.class_name) : nil
          end
        end

        def union_classes(union)
          kinds = union.members.map { |member| numerator_classes(member) }
          kinds.any?(&:nil?) ? nil : kinds.flatten.uniq
        end

        def class_kind(name)
          return [:complex] if name == "Complex"

          CONVERTING.include?(name) ? [:converting] : nil
        end
      end
    end
  end
end
