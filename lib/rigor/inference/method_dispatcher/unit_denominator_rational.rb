# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #1357 — `Kernel#Rational(x, 1)` is a `Rational` for every `Float` / `Integer` / `Rational` /
      # `Complex` `x`. CRuby's `nurat_convert` converts rather than returning the argument; only an argument
      # that is already a `Rational` comes back as-is, and that is a `Rational` too. The core RBS spells the
      # `1`-denominator form `[T < Numeric] (T value, 1) -> T`, which binds `T` to the argument's own class
      # and read `Rational(f, 1)` as a `Float`. This answers the nominal `Rational` for those argument
      # classes; any other argument (`BigDecimal`, a user `Numeric`) keeps the RBS answer.
      module UnitDenominatorRational
        module_function

        CLASSES = Set["Float", "Integer", "Rational", "Complex"].freeze
        private_constant :CLASSES

        # Answers `Rational`, or nil when the call is not the unit-denominator form.
        def answer(method_name, args)
          return nil unless method_name == :Rational && args.size >= 2
          return nil if args.size == 3 && !exception_keyword?(args[2])

          denominator = args[1]
          return nil unless denominator.is_a?(Type::Constant) && denominator.value.eql?(1)
          return nil unless numerator?(args.first)

          Type::Combinator.nominal_of("Rational")
        end

        # The trailing `exception:` keyword hash: a `HashShape` whose only key is `:exception`. Its value
        # does not change the answer (a Float that cannot convert raises either way).
        def exception_keyword?(type)
          type.is_a?(Type::HashShape) && type.pairs.keys == [:exception]
        end

        def numerator?(type)
          case type
          when Type::Union then type.members.all? { |member| numerator?(member) }
          when Type::Constant then CLASSES.include?(type.value.class.name)
          when Type::Nominal then CLASSES.include?(type.class_name) && type.type_args.empty?
          else false
          end
        end
      end
    end
  end
end
