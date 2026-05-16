# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/analysis/dependency_source_inference/return_type_heuristic"

RSpec.describe Rigor::Analysis::DependencySourceInference::ReturnTypeHeuristic do
  def extract_from(source)
    result = Prism.parse("class Fake\n#{source}\nend")
    expect(result.errors).to be_empty
    def_node = result.value.statements.body.first.body.body.first
    described_class.extract(def_node)
  end

  describe ".extract" do
    it "folds a single Integer-literal tail into Constant<value>" do
      type = extract_from("def n; 42; end")
      expect(type).to eq(Rigor::Type::Combinator.constant_of(42))
    end

    it "folds a single Float-literal tail into Constant<value>" do
      type = extract_from("def f; 3.14; end")
      expect(type).to eq(Rigor::Type::Combinator.constant_of(3.14))
    end

    it "folds a single Symbol-literal tail into Constant<value>" do
      type = extract_from("def s; :foo; end")
      expect(type).to eq(Rigor::Type::Combinator.constant_of(:foo))
    end

    it "folds TrueNode / FalseNode / NilNode into their Constant" do
      expect(extract_from("def t; true; end")).to eq(Rigor::Type::Combinator.constant_of(true))
      expect(extract_from("def f; false; end")).to eq(Rigor::Type::Combinator.constant_of(false))
      expect(extract_from("def n; nil; end")).to eq(Rigor::Type::Combinator.constant_of(nil))
    end

    it "folds a String literal into Nominal[String] (NOT Constant<\"x\">)" do
      type = extract_from('def s; "hello"; end')
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "folds an Array literal into Nominal[Array]" do
      type = extract_from("def a; [1, 2]; end")
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("Array"))
    end

    it "folds a Hash literal into Nominal[Hash]" do
      type = extract_from("def h; { a: 1 }; end")
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("Hash"))
    end

    it "uses the tail statement of a multi-statement body" do
      type = extract_from(<<~RUBY)
        def m
          x = 1
          y = 2
          "result"
        end
      RUBY
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "returns nil for non-literal tail expressions (method call)" do
      type = extract_from("def m; some_other_method; end")
      expect(type).to be_nil
    end

    it "returns nil for empty method bodies" do
      type = extract_from("def empty; end")
      expect(type).to be_nil
    end

    it "returns nil for explicit `return some_expr` (heuristic doesn't track return statements)" do
      type = extract_from("def r; return 42; end")
      expect(type).to be_nil
    end

    it "returns nil for `self` tails (receiver context not available to walker)" do
      type = extract_from("def s; self; end")
      expect(type).to be_nil
    end

    it "returns nil for instance-variable tails" do
      type = extract_from("def i; @ivar; end")
      expect(type).to be_nil
    end
  end
end
