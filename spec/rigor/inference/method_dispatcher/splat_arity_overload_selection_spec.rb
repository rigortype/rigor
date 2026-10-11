# frozen_string_literal: true

require "spec_helper"

# Issue #1801 — a splat stands for any number of positional arguments, so overload selection does not rule an overload
# out by arity alone. Counted as one positional, `ph(*xs, a: "s")` skipped the one-parameter `(Hash[Symbol, String])`
# overload, which takes `{ a: "s" }` when `xs` is empty (`def ph2(h) = h; ph2(*[], a: "s")` is `{ a: "s" }`), and took
# the keyword overload through the first-overload fallback.
RSpec.describe "Overload selection behind a splat argument (#1801)", type: :runner do
  let(:sig) do
    { "s.rbs" => <<~RBS }
      class S
        def ph: (a: Integer) -> Integer
              | (Hash[Symbol, String]) -> String
        def two: (Integer, Integer) -> Integer
               | (String) -> String
        def none: () -> Integer
                | (String, String, String) -> String
        def tail: (*Integer, String) -> String
                | (Symbol) -> Symbol
        def each_two: (Integer) { (Integer) -> void } -> void
                    | (Integer, Integer) { (String) -> void } -> void
        def each_same: (Integer) { (Integer) -> void } -> void
                     | (Integer, Integer) { (Integer) -> void } -> void
        def opts: () -> Hash[Symbol, untyped]
        def rest3: (Integer, Integer, Integer, *Integer) -> Integer
                 | (String) -> String
      end
    RBS
  end

  def dumped_types(source)
    prelude = %(require "rigor/testing"\ninclude Rigor::Testing\ns = S.new\nxs = [] #: Array[untyped]\n)
    result = analyze(prelude + source, sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  it "reports nothing on a splat call the positional Hash overload takes" do
    result = analyze(<<~RUBY, sig: sig)
      xs = [] #: Array[untyped]
      S.new.ph(*xs, a: "s").upcase
      S.new.ph(*xs, { a: "s" }).upcase
    RUBY
    expect(result.diagnostics.select(&:error?).map(&:message)).to eq([])
  end

  it "reaches the overload a splat of no arguments leaves the keyword hash to" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer String String Integer])
      dump_type(s.ph(a: 1))
      dump_type(s.ph(*xs, a: "s"))
      dump_type(s.ph(*xs, { a: "s" }))
      dump_type(s.ph(*xs, a: 1))
    RUBY
  end

  # A double splat's keys are unknown, so neither overload is proven and the returns join.
  it "joins the overloads a double splat behind a splat may reach" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[Integer | String]"])
      dump_type(s.ph(*xs, **s.opts, a: "s"))
    RUBY
  end

  it "joins every overload some count of the splat's elements reaches" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[Integer | String]", "Dynamic[Integer | String]"])
      dump_type(s.two(*xs))
      dump_type(s.none(*xs))
    RUBY
  end

  # The arguments beside the splat still rule overloads out, wherever the splat's count puts them.
  it "keeps ruling out the overloads the other arguments do not fit" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer String String Symbol])
      dump_type(s.two(1, *xs))
      dump_type(s.two("x", *xs))
      dump_type(s.tail(*xs, "x"))
      dump_type(s.tail(*xs, :x))
    RUBY
  end

  # Three splats against `rest3` pass the cap on spelled-out counts; the other arguments must still fit a parameter.
  it "keeps type-checking the other arguments past the cap on spelled-out counts" do
    expect(dumped_types(<<~RUBY)).to eq(%w[String Integer])
      dump_type(s.rest3("s", *xs, *xs, *xs))
      dump_type(s.rest3(1, *xs, *xs, *xs))
    RUBY
  end

  # A block parameter has one type per binding, so it binds only where every overload the splat may reach agrees.
  it "binds block parameters only where the overloads a splat may reach agree" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Dynamic[top] Integer Integer])
      s.each_two(*xs) { |v| dump_type(v) }
      s.each_same(*xs) { |v| dump_type(v) }
      s.each_two(1) { |v| dump_type(v) }
    RUBY
  end
end
