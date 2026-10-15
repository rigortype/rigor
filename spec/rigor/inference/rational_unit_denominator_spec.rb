# frozen_string_literal: true

require "spec_helper"

# Issue #1357 — core RBS spells `Kernel#Rational(x, 1)` as `[T < Numeric] (T, 1) -> T`, so a Float `x` typed the
# call as `Float`. CRuby's `nurat_convert` converts: `Rational(1.5, 1)` is `(3/2)`, and only a `Rational` argument is
# returned as-is (still a `Rational`). `KernelDispatch` answers `Rational` for a Float / Integer / Rational /
# Complex numerator.
RSpec.describe "Kernel#Rational with a unit denominator", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  it "types a Float numerator as Rational (Ruby: Rational(1.5, 1) is (3/2))" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Rational Rational Rational])
      def run
        f = rand
        n = rand(10)
        dump_type(Rational(f, 1))
        dump_type(Rational(f, 1, exception: false))
        dump_type(Rational(n, 1))
      end
    RUBY
  end

  it "keeps the folds and the one-argument form" do
    # Ruby: Rational(1, 1) is (1/1); Rational(1r, 1) is (1/1) (the same object); Rational(f) is a Rational.
    expect(dumped_types(<<~RUBY)).to eq(["(1/1)", "(1/1)", "Rational"])
      def run
        f = rand
        dump_type(Rational(1, 1))
        dump_type(Rational(1r, 1))
        dump_type(Rational(f))
      end
    RUBY
  end

  it "types a Complex numerator as Rational (Ruby: Rational(Complex(1, 0), 1) is (1/1))" do
    expect(dumped_types(<<~RUBY)).to eq(["Rational"])
      def run
        dump_type(Rational(Complex(rand(10), 0), 1))
      end
    RUBY
  end
end
