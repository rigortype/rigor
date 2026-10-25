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

  it "does not fold a predicate on the sum to a constant" do
    expect(result.diagnostics.map(&:rule)).not_to include("flow.always-truthy-condition")
  end
end
