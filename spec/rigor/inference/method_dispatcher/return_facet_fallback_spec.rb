# frozen_string_literal: true

require "spec_helper"

# Issue #1782 — the return path reads a faceted positional argument (a `Dynamic` with sealed facet members) member by
# member through `FacetDistribution.select`. Where that falls back to the arguments as given (the overloads are not
# provable, or a member matches no overload), the bare `Dynamic` gradually matches every arm, so the strict pass took
# the first overload and the call typed by its return: `w.fmt(n).even?` reported `even?` undefined on `String` for an
# `Integer` `n`. The fallback now joins every gradual match, as the block probe binds only what they agree on (#1750).
RSpec.describe "Return of a faceted argument's fallback (#1782)", type: :runner do
  let(:sig) do
    { "w.rbs" => <<~RBS }
      class W
        def fmt: ((String | :x) x) -> String
               | (Integer x) -> Integer
        def provable: (String x) -> String
                    | (Integer x) -> Integer
        def loose: ((String | :x) x, mode: Symbol) -> String
                 | (Integer x, mode: Symbol) -> Integer
        def int_or_nil: (Integer x) -> Integer
                      | (String x) -> nil
        def int_or_sym: (Integer x) -> Integer
                      | (String x) -> Symbol
        def untyped_value: () -> untyped
      end
    RBS
  end

  def analyzed(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\nw = W.new\nn = w.int_or_nil(w.untyped_value)\n#{source}),
            sig: sig)
  end

  def dumped_types(source)
    analyzed(source).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def errors(source) = analyzed(source).diagnostics.select(&:error?).map(&:message)

  it "joins every gradual match where the overloads are not provable" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[Integer?]", "Dynamic[Integer | String]", "Dynamic[Integer | String]"])
      dump_type(n)
      dump_type(w.fmt(n))
      dump_type(w.loose(n, mode: :a))
    RUBY
  end

  it "joins every gradual match where a member matches no overload" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[Integer | String]"])
      dump_type(w.fmt(w.int_or_sym(w.untyped_value)))
    RUBY
  end

  it "still types the overload a member selects on provable overloads" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer])
      dump_type(w.provable(n))
    RUBY
  end

  # The join's cost: a stdlib call whose overloads are not provable joins every arm the wrapper reaches, so
  # `Kernel#Rational`'s type-variable arm (`[T] (Numeric & _RationalDiv[T], Numeric) -> T`, unbound here) and its
  # `(untyped, ?untyped) -> Rational?` catch-all join the `Rational` the first arm answered.
  it "joins a stdlib call's every gradual match where its overloads are not provable" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[Dynamic[top] | Rational | nil]", "Dynamic[Complex?]"])
      dump_type(Rational(n, 3))
      dump_type(Complex(n, 1))
    RUBY
  end

  it "reports nothing on correct code the first overload's return used to mistype" do
    expect(errors(<<~RUBY)).to eq([])
      w.fmt(n).even?
      w.loose(n, mode: :a).even?
    RUBY
  end
end
