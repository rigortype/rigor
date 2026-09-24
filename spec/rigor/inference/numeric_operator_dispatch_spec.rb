# frozen_string_literal: true

require "spec_helper"

# Issue #1344 — the arithmetic operators and `divmod` between Ruby's four core numeric classes, dispatched on nominal
# receivers and arguments, must not name a class Ruby does not return. The receiver-affinity pre-sort
# (`ReceiverAffinity`) moved each receiver's `(Numeric) -> Self` arm ahead of the `(Float)` / `(Complex)` arms core RBS
# declares first, so `Rational + Float` read `Rational` and `Float * Complex` read `Float`. Each sample pair runs under
# Ruby, and the dispatched type must admit the runtime class: a union, `Numeric`, or a `Dynamic` is imprecise but not
# wrong. `Rational#*` declares `[T < Numeric](T) -> T`, whose argument binding a dispatch without a call site
# declines, so it answers `Dynamic[top]` here (#1347). `Rational#divmod` declares `(Integer | Float | Rational) ->
# [Integer, Rational]` first, wrong for a Float remainder, which is why pass 0 declines a union parameter.
RSpec.describe "numeric operator dispatch" do
  let(:environment) { Rigor::Scope.empty.environment }

  def sample(class_name)
    { "Integer" => 3, "Float" => 1.5, "Rational" => Rational(3, 2), "Complex" => Complex(1, 2) }
      .fetch(class_name)
  end

  def dispatched(receiver, method_name, arg)
    Rigor::Inference::MethodDispatcher.dispatch(
      receiver_type: Rigor::Type::Combinator.nominal_of(receiver), method_name: method_name,
      arg_types: [Rigor::Type::Combinator.nominal_of(arg)], environment: environment
    )
  end

  def admits?(type, class_name)
    return admits?(type.static_facet, class_name) if type.is_a?(Rigor::Type::Dynamic)
    return true if type.is_a?(Rigor::Type::Top)

    members = type.is_a?(Rigor::Type::Union) ? type.members : [type]
    members.any? do |member|
      member.is_a?(Rigor::Type::Nominal) && [class_name, "Numeric"].include?(member.class_name)
    end
  end

  %w[Integer Float Rational Complex].repeated_permutation(2).each do |receiver, arg|
    %i[+ - * / ** % modulo remainder quo fdiv].each do |method_name|
      it "types #{receiver} #{method_name} #{arg} as admitting the class Ruby returns" do
        runtime = begin
          sample(receiver).public_send(method_name, sample(arg))
        rescue NoMethodError, TypeError, RangeError, ZeroDivisionError
          skip "Ruby raises for #{receiver}##{method_name}(#{arg})"
        end
        expect(admits?(dispatched(receiver, method_name, arg), runtime.class.name)).to be(true)
      end
    end

    it "types #{receiver} divmod #{arg} as admitting both classes Ruby returns" do
      quotient, remainder = begin
        sample(receiver).divmod(sample(arg))
      rescue NoMethodError, TypeError, RangeError, ZeroDivisionError
        skip "Ruby raises for #{receiver}#divmod(#{arg})"
      end
      type = dispatched(receiver, :divmod, arg)
      expect(divmod_admits?(type, quotient.class.name, remainder.class.name)).to be(true)
    end
  end

  def divmod_admits?(type, quotient, remainder)
    return true if type.is_a?(Rigor::Type::Dynamic) || type.is_a?(Rigor::Type::Top)
    return true if type.is_a?(Rigor::Type::Nominal) && type.class_name == "Array"
    return false unless type.is_a?(Rigor::Type::Tuple) && type.elements.size == 2

    admits?(type.elements[0], quotient) && admits?(type.elements[1], remainder)
  end
end
