# frozen_string_literal: true

require "spec_helper"

# Issue #2379 — overload selection reads a union or supertype argument per runtime value.
#
# Selecting once for the whole argument took the first overload it matched: `Integer#+` with an `Integer | Float`
# argument read `(Integer) -> Integer`, though Ruby answers a Float for `1 + 1.5`, and a `Numeric` argument took the
# same overload by list position. A precise union argument now selects per member and a nominal argument wider than
# the selected parameter takes every overload it overlaps; the returns join.
RSpec.describe "Union and supertype arguments in overload selection (#2379)", type: :runner do
  let(:sig) do
    { "calc.rbs" => <<~RBS }
      class Calc
        def add: (Integer a, Integer | Float b) -> untyped
        def mul: (Integer a, Integer | Float b) -> untyped
        def sub: (Integer a, Numeric n) -> untyped
        def div: (Integer a, Numeric n) -> untyped
        def index: (Array[Integer] arr, Integer | Range[Integer] i) -> untyped
        def str_index: (String s, Integer | Range[Integer] i) -> untyped
        def literal: () -> untyped
        def receiver: (Integer a, Integer | Float b) -> untyped
        def predicate: (Integer a, Integer | Float b) -> untyped
        def precise: (Integer a, Integer b) -> untyped
        def nine: (Pick p, Integer | String | Symbol a, Integer | String | Symbol b) -> untyped
        def wide: (Pick p, 1 | 2 | 3 | 4 | 5 | 6 | 7 | "a" | "b" u) -> untyped
        def narrow: (Pick p, Integer i) -> untyped
        def typed: (Pick p, Array[Numeric] xs) -> untyped
        def sh: (Pick p, Integer | String | :a | :b | :c | :d | :e | :f | :g u) -> untyped
        def num: (Pick p, Integer | String | :a | :b | :c | :d | :e | :f | :g u) -> untyped
        def al: (Pick p, 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | Range[Integer] u) -> untyped
        def miss_small: (Pick p, Integer | :z u) -> untyped
        def miss_large: (Pick p, 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | :z u) -> untyped
        def sh_size: (Pick p, Integer | String | :a | :b | :c | :d | :e | :f | :g u) -> untyped
      end

      class Pick
        def pair: (Integer, Integer) -> :ii
                | (String, String) -> :ss
                | (Symbol, Symbol) -> :yy
        def one: (Integer) -> :i
               | (String) -> :s
        def nar: (Numeric) -> :num
               | (Integer) -> :int
        def arr: (Array[Integer]) -> :ai
               | (untyped) -> :any
        def sh: (Integer) -> Integer
              | (Integer) -> nil
              | (String) -> String
        def num: (Numeric) -> :num
               | (Integer) -> :int
               | (String) -> :str
        def al: (int) -> :int
              | (Range[Integer]) -> :range
        def two: (String) -> :s
               | (Integer) -> :i
      end
    RBS
  end

  let(:source) do
    <<~RUBY
      require "rigor/testing"
      include Rigor::Testing

      class Calc
        def add(a, b) = dump_type(a + b)
        def mul(a, b) = dump_type(a * b)
        def sub(a, n) = dump_type(a - n)
        def div(a, n) = dump_type(a / n)
        def index(arr, i) = dump_type(arr[i])
        def str_index(s, i) = dump_type(s[i])
        def literal = dump_type(1 + 2)
        def receiver(a, b) = dump_type(b + a)
        def precise(a, b) = dump_type(a + b)

        def predicate(a, b)
          if (a + b).integer?
            1
          else
            2
          end
        end

        def nine(p, a, b) = dump_type(p.pair(a, b))
        def wide(p, u) = dump_type(p.one(u))
        def narrow(p, i) = dump_type(p.nar(i))
        def typed(p, xs) = dump_type(p.arr(xs))
        def sh(p, u) = dump_type(p.sh(u))
        def num(p, u) = dump_type(p.num(u))
        def al(p, u) = dump_type(p.al(u))
        def miss_small(p, u) = dump_type(p.two(u))
        def miss_large(p, u) = dump_type(p.two(u))
        def sh_size(p, u) = p.sh(u).size
      end
    RUBY
  end

  let(:result) { analyze(source, sig: sig) }

  def dumped(line)
    result.diagnostics.find { |d| d.line == line && d.message.start_with?("dump_type") }&.message
  end

  it "joins the overloads a union argument's members select" do
    expect(dumped(5)).to eq("dump_type: Float | Integer")
    expect(dumped(6)).to eq("dump_type: Float | Integer")
  end

  it "joins every overload a supertype argument overlaps" do
    expect(dumped(7)).to eq("dump_type: Complex | Float | Integer | Rational")
    expect(dumped(8)).to eq("dump_type: Complex | Float | Integer | Rational")
  end

  it "joins an index and a range overload" do
    expect(dumped(9)).to eq("dump_type: Array[Integer] | Integer | nil")
  end

  # Guards: answers the change must not move.
  it "keeps a precise argument, a folded constant, a receiver union and a single-overload union" do
    expect(dumped(10)).to eq("dump_type: String?")
    expect(dumped(11)).to eq("dump_type: 3")
    expect(dumped(12)).to eq("dump_type: Float | Integer")
    expect(dumped(13)).to eq("dump_type: Integer")
  end

  # One union argument selects per member however many it has, through the selector itself: the first matching
  # overload wins (`(Integer) -> nil` after `(Integer) -> Integer` is never taken, nor `(Integer)` after `(Numeric)`),
  # and the alias pass still reads `(int)`.
  it "selects per member of one union argument past eight members, by the selector's own rules" do
    expect(dumped(24)).to eq("dump_type: :i | :s")
    expect(dumped(27)).to eq("dump_type: Integer | String")
    expect(dumped(28)).to eq("dump_type: :num | :str")
    expect(dumped(29)).to eq("dump_type: :int | :range")
    expect(result.diagnostics.map(&:rule)).not_to include("call.possible-nil-receiver")
  end

  # A member no overload takes keeps the first-overload fallback, with or without eight members to spare.
  it "lends a member no overload takes the first-overload fallback at any member count" do
    expect(dumped(30)).to eq("dump_type: :i | :s")
    expect(dumped(31)).to eq("dump_type: :i | :s")
  end

  # Two union arguments that combine past eight lists answer `Dynamic[top]`, never the first overload alone.
  it "answers untyped when union arguments combine past the list limit" do
    expect(dumped(23)).to eq("dump_type: Dynamic[top]")
  end

  # An argument no wider than the selected parameter keeps the one overload: `Integer` is taken by `(Numeric)`.
  it "keeps the selected overload when the argument is not wider than its parameter" do
    expect(dumped(25)).to eq("dump_type: :num")
  end

  # Only strictly typed overloads join a wider argument's overlap: the `(untyped)` arm does not. This pins the filter
  # the approval entry names; whether the catch-all arm should join is a separate question.
  it "leaves an untyped catch-all overload out of the overlap" do
    expect(dumped(26)).to eq("dump_type: :ai")
  end

  it "does not fold a predicate on the sum to a constant" do
    expect(result.diagnostics.map(&:rule)).not_to include("flow.always-truthy-condition")
  end
end
