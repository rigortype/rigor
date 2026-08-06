# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/optimistic_origin"

# ADR-101. Every decline assertion here is paired with a case that MUST still elide: a decline is the
# easiest expectation in this repo to pass by accident, because any construction error also widens the
# type. The proof-side examples are the control, not decoration — if they stop eliding, the gate has
# become a blanket "never elide" and the declines below prove nothing.
RSpec.describe Rigor::Inference::OptimisticOrigin do
  let(:scope) { Rigor::Scope.empty }

  def evaluate(source)
    scope.evaluate(Prism.parse(source).value)
  end

  # Bind a carrier directly rather than reaching for a stdlib expression that happens to produce it. The
  # gemspec supports `rbs >= 3.0, < 5.0` and the two lines disagree on some core signatures (`ENV` among
  # them), so a fixture that infers its own carrier can fail for a reason that has nothing to do with the
  # behaviour under test. `Array` is used because `Array#first` carries the annotation on both lines.
  def evaluate_with(locals, source)
    base = locals.reduce(scope) { |acc, (name, type)| acc.with_local(name, type) }
    base.evaluate(Prism.parse(source, scopes: [locals.keys]).value)
  end

  def array_of_string
    Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")])
  end

  def arms_of(type)
    return [type.value] if type.is_a?(Rigor::Type::Constant)

    type.members.map { |member| member.is_a?(Rigor::Type::Constant) ? member.value : member.describe }
  end

  describe "the cause it carries" do
    it "names the core-RBS annotation the dispatcher reads past" do
      expect(described_class::ANNOTATION).to eq("implicitly-returns-nil")
      expect(described_class::IMPLICITLY_RETURNS_NIL).to eq(:implicitly_returns_nil)
    end
  end

  describe "declines the elision when nil-freeness is a bet" do
    it "keeps both arms on a Union from a dynamic-key Hash read" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "keeps both arms when the read yields a single Constant, which no carrier-shape gate can see" do
      # Every value of the hash shares one type, so `V` is a lone `Constant["x"]` — exactly as optimistic
      # as the union above, and indistinguishable from a genuine constant without provenance.
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "x" }
        v = h[key]
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "keeps both arms on a Nominal from `Array#first`" do
      type, = evaluate_with({ xs: array_of_string }, <<~RUBY)
        v = xs.first
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines when the predicate is the read itself, with no intervening binding" do
      # A distinct path from the cases around it: the mark is read off the call node rather than off a
      # binding, so this pins the node-keyed side of the channel.
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        if h[key] then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "propagates the mark through an instance variable" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        @v = h[key]
        if @v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "propagates the mark through a local-to-local copy" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        w = v
        if w then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end

    it "declines `unless` on the same carrier" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        unless v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end
  end

  describe "still elides when nil-freeness is a property of the value (the control)" do
    it "elides on a Nominal whose class excludes nil — the same carrier class as the declining case" do
      # The pair that carries this ADR: `xs.first` above and `xs` here are the same carrier class, and only
      # provenance separates them. If this stops eliding, the gate has become a blanket "never elide".
      type, = evaluate_with({ xs: array_of_string }, <<~RUBY)
        if xs then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "elides on a genuine Constant" do
      type, = evaluate(<<~RUBY)
        v = "abc".upcase
        if v then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "elides on a literal predicate" do
      type, = evaluate('if true then 1 else "none" end')

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "elides on a static-key read, which `ShapeDispatch` resolves precisely rather than optimistically" do
      type, = evaluate(<<~RUBY)
        h = { a: "x" }
        v = h[:a]
        if v then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "elides on `Array#first` over a Tuple, where the receiver proves the read cannot miss" do
      type, = evaluate(<<~RUBY)
        v = ["a", "b"].first
        if v then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "rebinding a local to a proof-carrying value clears the mark" do
      type, = evaluate(<<~RUBY)
        h = { a: "x", b: "y" }
        v = h[key]
        v = "abc".upcase
        if v then 1 else "none" end
      RUBY

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "a carrier that is honestly optional still declines, for its own reason" do
    it "keeps both arms on an RBS-declared optional return" do
      type, = evaluate(<<~RUBY)
        v = "abc".match(/x/)
        if v then 1 else "none" end
      RUBY

      expect(arms_of(type)).to contain_exactly(1, "none")
    end
  end
end
