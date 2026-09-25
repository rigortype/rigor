# frozen_string_literal: true

require "spec_helper"

# Issue #1350 — a `Dynamic` argument whose static facet is not `top` is not imprecise: the internal spec says its facet
# discriminates, so the strict overload passes must judge it by that facet. Acceptance short-circuits on the `Dynamic`
# wrapper and accepts it against any parameter, so the receiver-affinity pre-sort's `(Money)` arm took
# `Money#add(Integer(v))`, typed the call `Money`, and `.even?` reported `call.undefined-method` on correct code.
RSpec.describe "strict overload pass on a Dynamic[T] argument", type: :runner do
  let(:sig) do
    { "money.rbs" => <<~RBS }
      class Money
        def add: (Integer) -> Integer
               | (Money) -> Money
               | (Object) -> String
      end
    RBS
  end

  def dumped_and_rules(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
    dumps = result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
    [dumps, result.diagnostics.map(&:rule)]
  end

  it "picks the arm the facet's class names, not the receiver's own class or ancestor" do
    # Runtime: `Integer(v)` is an Integer, so `add` returns it and `even?` answers. The facet `Integer | nil` leaves
    # `nil` out, and the Integer takes the `(Integer)` arm its RBS declares first.
    dumps, rules = dumped_and_rules(<<~RUBY)
      class Money
        def add(x) = x.is_a?(Integer) ? x : "s"
      end
      def run(v)
        n = Integer(v)
        dump_type(Money.new.add(n))
        Money.new.add(n).even?
      end
    RUBY
    expect(dumps).to eq(["Integer"])
    expect(rules).not_to include("call.undefined-method")
  end

  it "keeps a facet's nil from choosing an overload the value never reaches" do
    # Runtime: a Complex. Chosen by the facet's `nil`, `Kernel#Complex` took its `nil`-returning form.
    dumps, = dumped_and_rules(<<~RUBY)
      def run(v) = dump_type(Complex(Integer(v), 1))
    RUBY
    expect(dumps).to eq(["Complex"])
  end

  it "keeps one unwrapped arm when the facet's other members take none" do
    # Runtime: an Integer. `Integer#+` has no arm for the facet's `nil`, which drops out.
    dumps, = dumped_and_rules(<<~RUBY)
      def run(v) = dump_type(1 + Integer(v))
    RUBY
    expect(dumps).to eq(["Integer"])
  end

  it "picks the Float arm for a Float facet the affinity order used to hand the receiver's own arm" do
    # Runtime: `1 + Float(v)` is a Float.
    dumps, = dumped_and_rules(<<~RUBY)
      def run(v) = dump_type(1 + Float(v))
    RUBY
    expect(dumps).to eq(["Float"])
  end

  it "keeps the wrapper when a member, such as a supertype, reaches no overload" do
    # Runtime: `1 + 2 ** n` is an Integer for a non-negative Integer `n`. `2 ** n` is `Dynamic[Complex | Numeric]`,
    # and no `Integer#+` overload names `Numeric`; dropped, it left `Complex` precise and `even?` undefined on it.
    dumps, rules = dumped_and_rules(<<~RUBY)
      def pow_sum(n)
        dump_type(1 + 2 ** n)
        (1 + 2 ** n).even?
      end
    RUBY
    expect(dumps).to eq(["Integer"])
    expect(rules).not_to include("call.undefined-method")
  end

  it "keeps the wrapper when a member is a supertype of a class some overload names" do
    # Runtime: `1 <=> 2 ** n` is an Integer. `2 ** n`'s `Numeric` member skips `Integer#<=>`'s `(Integer)` arm and
    # lands on `(untyped) -> Integer?`, a catch-all a runtime Integer never reaches; read so, `c + 1` reported a
    # possible-nil receiver.
    result = analyze(<<~RUBY)
      def cmp(n)
        c = 1 <=> 2 ** n
        c + 1
      end
    RUBY
    expect(result.diagnostics.map(&:rule)).not_to include("call.possible-nil-receiver")
  end

  context "with an overload that names a member's subclass through an alias" do
    let(:sig) do
      { "calc.rbs" => <<~RBS }
        type num = Integer | Float

        class Calc
          def initialize: () -> void
          def scale: (real) -> Float
                   | (untyped) -> nil
          def scale_num: (num) -> Float
                       | (untyped) -> nil
        end
      RBS
    end

    it "keeps the wrapper for a member whose runtime value may be of a subclass" do
      # Runtime: `2 ** v` is an Integer for a non-negative Integer `v`, and both `real` and `num` name `Integer`, so
      # each call answers a Float. `2 ** v` is `Dynamic[Complex | Numeric]`; read member by member, `Numeric` skipped
      # the alias arm for the `(untyped) -> nil` catch-all, and `.floor` reported `call.undefined-method`.
      dumps, rules = dumped_and_rules(<<~RUBY)
        def run(v)
          dump_type(Calc.new.scale(2 ** v))
          dump_type(Calc.new.scale_num(2 ** v))
          Calc.new.scale(2 ** v).floor + Calc.new.scale_num(2 ** v).floor
        end
      RUBY
      expect(dumps).to eq(%w[Float Float])
      expect(rules).not_to include("call.undefined-method")
    end
  end

  it "keeps joining every arm for an untyped argument" do
    # The #521 join: an untyped argument cannot tell the arms apart.
    dumps, = dumped_and_rules(<<~RUBY)
      class Money
        def add(x) = x
      end
      def run(v) = dump_type(Money.new.add(v))
    RUBY
    expect(dumps.first).to start_with("Dynamic[")
  end
end
