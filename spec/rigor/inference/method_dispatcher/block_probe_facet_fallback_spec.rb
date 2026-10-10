# frozen_string_literal: true

require "spec_helper"

# Issue #1750 — the block-parameter probe reads a faceted positional argument (a `Dynamic` with sealed facet members)
# member by member through `FacetDistribution.select`. Where that falls back to the arguments as given (the overloads
# are not provable, or a member matches no overload), the bare `Dynamic` gradually matches every arm, so the strict
# pass took the first overload and the block bound to its parameters: `visit(n) { |v| v.even? }` reported `even?`
# undefined on `String` for an `Integer` `n`. The probe now binds only what every gradual match agrees on.
RSpec.describe "Block parameters of a faceted argument's fallback (#1750)", type: :runner do
  let(:sig) do
    { "visitor.rbs" => <<~RBS }
      class Visitor
        def visit: (String x) { (String) -> void } -> void
                 | (Integer x) { (Integer) -> void } -> void
        def loose: ((String | :x) x) { (String) -> void } -> void
                 | (Integer x) { (Integer) -> void } -> void
        def number: (Integer x) { (Integer) -> void } -> void
                  | (Float x) { (Float) -> void } -> void
        def same: ((String | :x) x) { (Integer) -> void } -> void
                | (Integer x) { (Integer) -> void } -> void
        def keyed: ((String | :x) x, mode: Symbol) { (String) -> void } -> void
                 | (Integer x, mode: Symbol) { (Integer) -> void } -> void
        def int_or_nil: (Integer x) -> Integer
                      | (String x) -> nil
        def int_or_sym: (Integer x) -> Integer
                      | (String x) -> Symbol
        def int_or_float: (Integer x) -> Integer
                        | (String x) -> Float
        def untyped_value: () -> untyped
        def mode_value: () -> (:a | :b)
        def paired: ((Integer | :x) n, Integer x, mode: Symbol) { (Integer) -> void } -> Integer
                  | ((Integer | :x) n, Float x, mode: Symbol) { (Float) -> void } -> Float
        def kret: ((String | :x) x, mode: Symbol) -> String
                | (Integer x, mode: Symbol) -> Integer
      end
    RBS
  end

  def analyzed(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\nw = Visitor.new\n#{source}), sig: sig)
  end

  def dumped_types(source)
    analyzed(source).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def errors(source) = analyzed(source).diagnostics.select(&:error?).map(&:message)

  it "still binds the arm a member selects on provable overloads" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer])
      w.visit(w.int_or_nil(w.untyped_value)) { |v| dump_type(v) }
    RUBY
  end

  it "binds nothing where the overloads are not provable and disagree" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]"])
      w.loose(w.int_or_nil(w.untyped_value)) { |v| dump_type(v) }
      w.keyed(w.int_or_nil(w.untyped_value), mode: :a) { |v| dump_type(v) }
    RUBY
  end

  it "binds nothing where a member matches no overload" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
      w.visit(w.int_or_sym(w.untyped_value)) { |v| dump_type(v) }
    RUBY
  end

  # Two members selecting different arms disagree on the block parameter too; the singular selection read the
  # arguments as given and took the first arm.
  it "binds nothing where two members select arms that disagree" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
      w.number(w.int_or_float(w.untyped_value)) { |v| dump_type(v) }
    RUBY
  end

  it "binds what every gradual match agrees on" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer])
      w.same(w.int_or_nil(w.untyped_value)) { |v| dump_type(v) }
    RUBY
  end

  # The fallback's agreement runs over every arm the arguments reach, including those an untyped part of a union
  # argument reaches on its own (#1675): `1 | untyped` may be a Float, which takes the `(Float)` arm.
  it "counts the arms an argument's untyped part reaches toward the agreement" do
    expect(errors(<<~RUBY)).to eq([])
      u = rand > 0.5 ? 1 : w.untyped_value
      w.paired(w.int_or_nil(w.untyped_value), u, mode: :a) { |v| v.nan? }
    RUBY
  end

  # The return path's per-list keyword matches (#1746) read the fallback the same way, so a union keyword value with a
  # faceted argument the overloads cannot prove joins every arm rather than typing the first.
  it "joins every gradual match on the return path of a keyword call" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[Integer | String]"])
      dump_type(w.kret(w.int_or_nil(w.untyped_value), mode: w.mode_value))
    RUBY
  end

  it "reports nothing on correct code the first arm's block parameters used to mistype" do
    expect(errors(<<~RUBY)).to eq([])
      w.loose(w.int_or_nil(w.untyped_value)) { |v| v.even? }
      w.keyed(w.int_or_nil(w.untyped_value), mode: :a) { |v| v.even? }
      w.visit(w.int_or_sym(w.untyped_value)) { |v| v.even? }
    RUBY
  end
end
