# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::StatementEvaluator do
  let(:scope) { Rigor::Scope.empty }

  def parse_program(source)
    Prism.parse(source).value
  end

  def evaluate(source, base_scope: scope)
    base_scope.evaluate(parse_program(source))
  end

  describe ".evaluate (Scope#evaluate delegate)" do
    it "returns a [type, scope] pair" do
      type, post = evaluate("1 + 2")
      expect(type).to be_a(Rigor::Type::Constant)
      expect(post).to be_a(Rigor::Scope)
    end

    it "leaves scope unchanged for pure expressions" do
      _, post = evaluate("1 + 2")
      expect(post).to eq(scope)
    end
  end

  describe "sequential statements" do
    it "binds local-variable writes into the post-scope" do
      _, post = evaluate("x = 1")
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "threads bindings across statements" do
      type, post = evaluate(<<~RUBY)
        x = 1
        y = x + 2
        y
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(3))
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:y)).to eq(Rigor::Type::Combinator.constant_of(3))
    end

    it "produces Constant[nil] for an empty program" do
      type, post = evaluate("")
      expect(type).to eq(Rigor::Type::Combinator.constant_of(nil))
      expect(post).to eq(scope)
    end

    it "discards intermediate types but preserves their scope effects" do
      _, post = evaluate(<<~RUBY)
        x = 1
        :ignore_this
        y = x
      RUBY
      expect(post.local(:y)).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "does not mutate the receiver scope" do
      bound = scope.with_local(:seed, Rigor::Type::Combinator.constant_of(7))
      _, _post = bound.evaluate(parse_program("x = 1"))
      expect(bound.local(:seed)).to eq(Rigor::Type::Combinator.constant_of(7))
      expect(bound.local(:x)).to be_nil
    end
  end

  describe "if/unless branching" do
    it "unions branch types and binds names defined in both branches" do
      type, post = evaluate(<<~RUBY)
        if cond
          x = 1
        else
          x = 2
        end
        x
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, 2)
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2)
    end

    it "nil-injects names bound in only one branch (then-only)" do
      _, post = evaluate(<<~RUBY)
        if cond
          x = 1
        end
      RUBY
      expect(post.local(:x)).to be_a(Rigor::Type::Union)
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, nil)
    end

    it "nil-injects names bound in only one branch (else-only)" do
      _, post = evaluate(<<~RUBY)
        unless cond
          x = 1
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, nil)
    end

    it "nil-injects on each side independently when branches bind disjoint names" do
      _, post = evaluate(<<~RUBY)
        if cond
          x = 1
        else
          y = 2
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, nil)
      expect(post.local(:y).members.map(&:value)).to contain_exactly(2, nil)
    end

    it "handles elsif chains as nested IfNodes" do
      type, _post = evaluate(<<~RUBY)
        if cond1
          1
        elsif cond2
          2
        else
          3
        end
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, 2, 3)
    end
  end

  describe "case/when branching" do
    it "unions every when-clause type and the else-clause type" do
      type, _post = evaluate(<<~RUBY)
        case kind
        when 1 then "a"
        when 2 then "b"
        else        "c"
        end
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly("a", "b", "c")
    end

    it "nil-injects names bound in some but not all branches" do
      _, post = evaluate(<<~RUBY)
        case kind
        when 1 then x = 1
        when 2 then x = 2; y = 9
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2, nil)
      expect(post.local(:y).members.map(&:value)).to contain_exactly(9, nil)
    end
  end

  describe "begin/rescue/ensure" do
    it "joins the body and rescue-chain scopes" do
      _, post = evaluate(<<~RUBY)
        begin
          x = 1
        rescue
          x = 2
        end
      RUBY
      expect(post.local(:x).members.map(&:value)).to contain_exactly(1, 2)
    end

    it "propagates the ensure-clause's scope effects to the post-scope" do
      _, post = evaluate(<<~RUBY)
        begin
          x = 1
        ensure
          y = 2
        end
      RUBY
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      expect(post.local(:y)).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "uses the else-clause's value when present" do
      type, _post = evaluate(<<~RUBY)
        begin
          1
        rescue
          2
        else
          3
        end
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(2, 3)
    end
  end

  describe "loops" do
    it "types as Constant[nil] and nil-injects loop-bound names" do
      type, post = evaluate(<<~RUBY)
        x = 0
        while cond
          x = 1
        end
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.constant_of(nil))
      expect(post.local(:x).members.map(&:value)).to contain_exactly(0, 1)
    end

    it "until-loop nil-injects body-bound names" do
      _, post = evaluate(<<~RUBY)
        until cond
          y = "hi"
        end
      RUBY
      expect(post.local(:y).members.map(&:value)).to contain_exactly("hi", nil)
    end
  end

  describe "and/or short-circuit" do
    it "joins post-scopes of both operands with nil-injection" do
      _, post = evaluate(<<~RUBY)
        (x = 1) && (y = 2)
      RUBY
      # `x = 1` always runs, so x is preserved straight through.
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
      # `y = 2` runs only when LHS is truthy, so y is nil-injected.
      expect(post.local(:y).members.map(&:value)).to contain_exactly(2, nil)
    end

    it "unions the two operand types" do
      type, _post = evaluate("1 || \"hi\"")
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, "hi")
    end
  end

  describe "parentheses thread scope through their body" do
    it "binds locals declared inside the parentheses" do
      _, post = evaluate("(x = 1; x + 1)")
      expect(post.local(:x)).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "fall-through to ExpressionTyper" do
    it "leaves scope unchanged for unrecognised statement-y nodes" do
      _, post = evaluate("[1, 2, 3].first")
      expect(post).to eq(scope)
    end

    it "does not record fallback events for recognised statement-y nodes" do
      tracer = Rigor::Inference::FallbackTracer.new
      scope.evaluate(parse_program("x = 1"), tracer: tracer)
      expect(tracer).to be_empty
    end

    it "carries the tracer into ExpressionTyper for inner expressions" do
      tracer = Rigor::Inference::FallbackTracer.new
      scope.evaluate(parse_program("foo()"), tracer: tracer)
      expect(tracer).not_to be_empty
    end
  end

  describe "downstream inference benefits" do
    it "lets methods on bound locals resolve through RBS" do
      type, _post = evaluate(<<~RUBY)
        x = 1
        x.succ
      RUBY
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "lets shape-typed locals resolve through dispatch" do
      type, _post = evaluate(<<~RUBY)
        xs = [1, 2, 3]
        xs.first
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, 2, 3)
    end

    it "propagates HashShape locals through fetch" do
      type, _post = evaluate(<<~RUBY)
        h = { a: 1, b: 2 }
        h.fetch(:a)
      RUBY
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(1, 2)
    end
  end
end
