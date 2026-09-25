# frozen_string_literal: true

require "spec_helper"

# Issue #1347 — the argument-position rule binds a method-level type variable to the argument's type "as it stands,
# literal included", which is sound where the return is the argument itself. `Rational#*` declares
# `[T < Numeric](T) -> T` and returns a value of the argument's class, not the argument, so `r * 0.5` read `0.5`. A
# variable that declares an upper bound is now bound to the argument widened off its value-pinned members; an
# unbounded one keeps the literal.
RSpec.describe "bounded method type variable binding", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  it "types Rational * Float as Float, not the Float argument's literal" do
    # Runtime: `Rational(3, 3) * 0.5` is `0.5`, a Float the literal only happens to equal here.
    expect(dumped_types(<<~RUBY)).to eq(["Float"])
      def run(v)
        r = Rational(Integer(v), 3)
        dump_type(r * 0.5)
      end
    RUBY
  end

  it "does not fold a comparison against the argument's literal" do
    # Runtime: prints only when `v` is `"3"`, so the condition is not always true.
    result = analyze(<<~RUBY)
      def run(v)
        r = Rational(Integer(v), 3)
        puts "half" if (r * 0.5) == 0.5
      end
    RUBY
    expect(result.diagnostics.map(&:rule)).not_to include("flow.always-truthy-condition")
  end

  it "widens a variable whatever kind its bound is" do
    # `upper_bound` answers only class, singleton and interface bounds; an alias or union bound counts too. The class
    # has no Ruby body, which would decline the argument binding altogether.
    sig = <<~RBS
      class Scaler
        def self.alias_bound: [T < int] (T) -> T
        def self.union_bound: [T < Integer | Float] (T) -> T
      end
    RBS
    result = analyze(<<~RUBY, sig: { "scaler.rbs" => sig })
      require "rigor/testing"
      include Rigor::Testing
      dump_type(Scaler.alias_bound(5))
      dump_type(Scaler.union_bound(5))
    RUBY
    dumps = result.diagnostics.map(&:message).grep(/\Adump_type/).map { |message| message.delete_prefix("dump_type: ") }
    expect(dumps).to eq(%w[Integer Integer])
  end

  it "keeps the literal for an unbounded variable, whose return is the argument" do
    expect(dumped_types(<<~RUBY)).to eq([%("x")])
      dump_type(Ractor.make_shareable("x"))
    RUBY
  end

  it "widens a bounded identity return too, the rule's cost" do
    # `String#setbyte: [T < _ToInt] (int index, T byte) -> T` returns its argument; the literal is not kept.
    expect(dumped_types(<<~RUBY)).to eq(["Integer"])
      dump_type((+"ab").setbyte(0, 65))
    RUBY
  end
end
