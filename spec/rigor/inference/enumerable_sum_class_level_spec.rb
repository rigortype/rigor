# frozen_string_literal: true

require "spec_helper"

# Every overload of `Enumerable#sum` returns a union of its sides: `() -> (E | Integer)`,
# `[T] () { (E) -> T } -> (Integer | T)`, `[T] (?T) -> (E | T)` and `[U] (?U) { (E) -> U } -> U`. The
# method adds those sides together, so a value on either side is not closed under it. `[1, 2].each.sum(0.0)`
# is `3.0`, which is in neither `0.0` nor `1 | 2`. The issue #303 argument binding and the receiver's element
# binding each pin a literal, so the declared return read `0.0 | 1 | 2` and `s == 3.0` folded always-falsey on
# correct code. Classes are closed under the addition, and the seed promotes every value it absorbs
# (Integer < Rational < Float < Complex), so the return reads as the classes the accumulator can reach.
RSpec.describe "Enumerable#sum's return read at class level", type: :runner do
  def run(source)
    analyze(<<~RUBY)
      require "rigor/testing"
      include Rigor::Testing
      #{source}
    RUBY
  end

  def dumped_types(result)
    result.diagnostics.filter_map { |d| d.message.delete_prefix("dump_type: ") if d.message.start_with?("dump_type") }
  end

  def rules(result, *names)
    result.diagnostics.map { |d| d.rule.to_s }.select { |rule| names.include?(rule) }
  end

  describe "the blockless overload with a seed, [T] (?T) -> (E | T)" do
    it "does not fold a comparison against a Float seed over Integer literals" do
      # Runtime: 3.0.
      result = run(<<~RUBY)
        s = [1, 2].each.sum(0.0)
        dump_type(s)
        puts "three" if s == 3.0
      RUBY
      expect(dumped_types(result)).to eq(["Float"])
      expect(rules(result, "flow.always-truthy-condition")).to be_empty
    end

    it "reads a Float seed over a bounded integer element as Float" do
      # Runtime: a Float for every ARGV, 0.0 for an empty one.
      expect(dumped_types(run("dump_type(ARGV.map(&:size).each.sum(0.0))"))).to eq(["Float"])
    end

    it "promotes a Rational element to a Float seed" do
      # Runtime: 3.0.
      expect(dumped_types(run("dump_type([1r, 2r].each.sum(0.0))"))).to eq(["Float"])
    end

    it "declines to Dynamic[top] for a Rational seed, which an Integer range reads as a Float" do
      # Runtime: a Float for a non-empty range, since CRuby adds the Gauss sum through Integer#coerce.
      result = run(<<~RUBY)
        x = (1..ARGV.size).sum(0r)
        dump_type(x)
        puts x.nan?
        puts ARGV.size.to_r.nan?
      RUBY
      expect(dumped_types(result)).to eq(["Dynamic[top]"])
      expect(result.diagnostics.select { |d| d.rule.to_s == "call.undefined-method" }.map(&:line)).to eq([6])
    end

    it "keeps an Integer seed over an Integer range" do
      expect(dumped_types(run("dump_type((1..ARGV.size).sum(0))"))).to eq(["Integer"])
    end

    it "does not reject a declared Float return over an Integer receiver" do
      result = analyze(<<~RUBY, sig: { "totals.rbs" => <<~RBS })
        class Totals
          def float_total(sizes) = sizes.each.sum(0.0)
          def string_total(sizes) = sizes.each.sum(0.0)
        end
      RUBY
        class Totals
          def float_total: (Array[Integer]) -> Float
          def string_total: (Array[Integer]) -> String
        end
      RBS
      mismatches = result.diagnostics.select { |d| d.rule.to_s == "def.return-type-mismatch" }
      expect(mismatches.map(&:line)).to eq([3])
    end

    it "widens the receiver's literal elements as well as the seed" do
      # Runtime: 4.0, and `0` for a receiver that yields nothing. Widening the seed alone reads
      # `Integer | 1.5 | 2.5`, which still misses 4.0.
      result = run(<<~RUBY)
        v = [1.5, 2.5].each.sum(0)
        dump_type(v)
        if v.is_a?(Float)
          puts "four" if v == 4.0
        end
      RUBY
      expect(dumped_types(result)).to eq(["Float | Integer"])
      expect(rules(result, "flow.always-truthy-condition")).to be_empty
    end

    it "reads an all-Integer sum as Integer" do
      # Runtime: 6.
      result = run(<<~RUBY)
        w = [1, 2].each.sum(3)
        dump_type(w)
        puts "six" if w == 6
      RUBY
      expect(dumped_types(result)).to eq(["Integer"])
      expect(rules(result, "flow.always-truthy-condition")).to be_empty
    end

    it "reads a String seed over String literals as String" do
      # Runtime: "ab".
      result = run(<<~RUBY)
        d = %w[a b].each.sum("")
        dump_type(d)
        puts "ab" if d == "ab"
      RUBY
      expect(dumped_types(result)).to eq(["String"])
      expect(rules(result, "flow.always-truthy-condition")).to be_empty
    end

    it "widens the sum of a user class that includes Enumerable" do
      result = analyze(<<~RUBY, sig: { "bag.rbs" => <<~RBS })
        require "rigor/testing"
        include Rigor::Testing
        class Bag
          include Enumerable

          def each
            yield 1
            yield 2
          end
        end
        dump_type(Bag.new.sum(0.0))
      RUBY
        class Bag
          include Enumerable[Integer]
          def each: () { (Integer) -> void } -> void
        end
      RBS
      expect(dumped_types(result)).to eq(["Float"])
    end
  end

  describe "the other overloads" do
    it "widens the receiver's literal elements on the parameterless overload" do
      # Runtime: 4.0, a Float the declared `1.5 | 2.5 | Integer` narrowed to `1.5 | 2.5` misses.
      result = run(<<~RUBY)
        u = [1.5, 2.5].each.sum
        dump_type(u)
        if u.is_a?(Float)
          puts "four" if u == 4.0
        end
      RUBY
      expect(dumped_types(result)).to eq(["Float | Integer"])
      expect(rules(result, "flow.always-truthy-condition")).to be_empty
    end

    it "widens the block's literal type on the block-only overload" do
      # Runtime: 1.0, which `0.5` misses.
      result = run(<<~RUBY)
        b = [1, 2].each.sum { 0.5 }
        dump_type(b)
        if b.is_a?(Float)
          puts "one" if b == 1.0
        end
      RUBY
      expect(dumped_types(result)).to eq(["Float | Integer"])
      expect(rules(result, "flow.always-truthy-condition")).to be_empty
    end
  end

  describe "sides with no class to widen to" do
    it "declines to Dynamic[top] for a sum that concatenates tuples" do
      # Runtime: `[1, 2]`, which is none of `[1] | [2] | []`, and no value class states it.
      expect(dumped_types(run("dump_type([[1], [2]].each.sum([]))"))).to eq(["Dynamic[top]"])
    end

    it "declines to Dynamic[top] for a generic class" do
      # Runtime: the seed's Integers and the elements' Strings in one Array, which neither
      # Array[String] nor Array[Integer] contains.
      expect(dumped_types(run("dump_type(ARGV.map(&:chars).each.sum(ARGV.map(&:size)))"))).to eq(["Dynamic[top]"])
    end

    it "declines to Dynamic[top] for a String subclass" do
      # `Name + Name` is a plain String, so the `when String` clause is reachable.
      result = run(<<~RUBY)
        class Name < String; end
        n = ARGV.map { |a| Name.new(a) }.each.sum(Name.new(""))
        dump_type(n)
        case n
        when Name then puts "name"
        when String then puts "string"
        end
      RUBY
      expect(dumped_types(result)).to eq(["Dynamic[top]"])
      expect(rules(result, "flow.unreachable-clause")).to be_empty
    end

    it "declines to Dynamic[top] for a nil member rather than carry a nil arm" do
      # A nil element raises inside `sum`, so a result that reaches `abs` is never nil.
      result = run(<<~RUBY)
        n = ARGV.map { |a| a.to_i if a.size > 1 }.each.sum(0)
        dump_type(n)
        puts n.abs
      RUBY
      expect(dumped_types(result)).to eq(["Dynamic[top]"])
      expect(rules(result, "call.possible-nil-receiver")).to be_empty
    end
  end

  # Issue #303 binds an argument's type as it stands, which is sound for a parametric signature: the method
  # returns the argument or one of the same type. `Array#fetch`'s `(E | T)` is spelled exactly as
  # `Enumerable#sum`'s, and it returns the default object itself, so it keeps the literal.
  describe "controls" do
    it "keeps an identity signature's literal binding" do
      expect(dumped_types(run('dump_type(Ractor.make_shareable("x"))'))).to eq(['"x"'])
    end

    it "keeps Array#fetch's literal default, whose return is spelled like sum's" do
      expect(dumped_types(run("dump_type(ARGV.fetch(3, :none))"))).to eq([":none | String"])
    end

    it "keeps ENV.fetch's literal default" do
      expect(dumped_types(run('dump_type(ENV.fetch("X", :none))'))).to eq([":none | String"])
    end

    it "keeps the literal return of an Enumerable method other than sum" do
      expect(dumped_types(run("dump_type([1, 2].each.min)"))).to eq(["1 | 2 | nil"])
    end
  end

  # The widening is keyed to the declaration `Enumerable` owns, not to the method name.
  describe "RbsDispatch" do
    let(:rbs) do
      <<~RBS
        class RigorSpecTally
          def sum: [T] (?T seed) -> (::Integer | T)
        end

        class RigorSpecBag
          include ::Enumerable[::Integer]
          def each: () { (::Integer) -> void } -> void
        end

        class RigorSpecGappy
          include ::Enumerable[::NilClass | ::Integer]
          def each: () { (::NilClass | ::Integer) -> void } -> void
        end
      RBS
    end
    let(:environment) do
      Rigor::Environment.new(
        rbs_loader: Rigor::Environment::RbsLoader.new(virtual_rbs: [["(spec: Enumerable#sum)", rbs]])
      )
    end
    let(:call_node) { Prism.parse("receiver.sum(0.0)").value.statements.body.first }

    # A permitting call site, so the #303 gate lets the argument bind.
    def sum(class_name, args)
      context = cc(
        receiver: Rigor::Type::Combinator.nominal_of(class_name), method_name: :sum, args: args,
        environment: environment, scope: Rigor::Scope.empty(environment: environment), call_node: call_node
      )
      Rigor::Inference::MethodDispatcher::RbsDispatch.try_dispatch(context)
    end

    it "widens the seed of the sum a class inherits from Enumerable" do
      type = sum("RigorSpecBag", [Rigor::Type::Combinator.constant_of(0.0)])
      expect(type.describe(:short)).to eq("Float")
    end

    it "declines to Dynamic[top] for a NilClass element" do
      type = sum("RigorSpecGappy", [Rigor::Type::Combinator.constant_of(0)])
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end

    it "keeps the literal seed of a sum the class declares itself" do
      type = sum("RigorSpecTally", [Rigor::Type::Combinator.constant_of(0.0)])
      expect(type.describe(:short)).to eq("0.0 | Integer")
    end
  end
end
