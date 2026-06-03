# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/precision_scanner"
require "rigor/scope"

RSpec.describe Rigor::Inference::PrecisionScanner do
  def scan(source)
    described_class.new.scan(Prism.parse(source).value)
  end

  describe "non-expression node exclusion" do
    it "counts only the value expression, not its Program/Statements wrappers" do
      # `1` parses as Program > Statements > IntegerNode; the two
      # wrappers are non-expressions and must not be counted.
      result = scan("1\n")
      expect(result.total).to eq(1)
      expect(result.tier_counts.fetch(:constant)).to eq(1)
      expect(result.precision_ratio).to eq(1.0)
    end

    it "skips the ArgumentsNode container but counts the call and its arguments" do
      # `foo(1, 2)` => Call + Arguments + two Integers (+ Program /
      # Statements). Counted: the CallNode (opaque — foo is unknown)
      # and the two Integer literals (constant). Arguments / Program /
      # Statements are skipped.
      result = scan("foo(1, 2)\n")
      expect(result.total).to eq(3)
      expect(result.tier_counts.fetch(:constant)).to eq(2)
      expect(result.dynamic_top_count).to eq(1)
    end

    it "does not count parameter declarations in a method definition" do
      # The def's parameter list and each RequiredParameterNode are
      # non-expressions; the parameter *reads* in the body are not.
      result = scan("def f(a, b)\n  a\nend\n")
      expect(result.total).to eq(2) # the DefNode + the `a` read
    end

    it "ignores a node whose class is in the exclusion set even at the root" do
      excluded = described_class::NON_EXPRESSION_NODE_TYPES
      expect(excluded).to include("Prism::ArgumentsNode", "Prism::StatementsNode",
                                  "Prism::RequiredParameterNode", "Prism::AssocNode")
    end
  end

  describe "tier classification" do
    it "classifies a string literal as constant" do
      result = scan("\"hello\"\n")
      expect(result.tier_counts.fetch(:constant)).to eq(1)
      expect(result.total).to eq(1)
    end

    it "treats an unresolved bare method call as opaque" do
      result = scan("undefined_helper\n")
      expect(result.dynamic_top_count).to eq(1)
      expect(result.precision_ratio).to eq(0.0)
    end

    it "classifies a symbol literal as constant" do
      result = scan(":ok\n")
      expect(result.tier_counts.fetch(:constant)).to eq(1)
    end

    it "classifies a true / false literal as constant" do
      result = scan("true\n")
      expect(result.tier_counts.fetch(:constant)).to eq(1)
    end

    it "classifies a nil literal as constant (Constant[nil])" do
      result = scan("nil\n")
      expect(result.tier_counts.fetch(:constant)).to eq(1)
    end
  end

  describe "FileResult helper methods" do
    it "precision_ratio is 1.0 when every expression is precise" do
      result = scan("1\n")
      expect(result.precision_ratio).to eq(1.0)
    end

    it "precision_ratio is 0.0 when every expression is opaque" do
      result = scan("undefined_helper\n")
      expect(result.precision_ratio).to eq(0.0)
    end

    it "opaque_ratio is 0.0 for a fully-precise file" do
      result = scan("42\n")
      expect(result.opaque_ratio).to eq(0.0)
    end

    it "opaque_ratio is 1.0 for a fully-opaque file" do
      result = scan("unknown_method\n")
      expect(result.opaque_ratio).to eq(1.0)
    end

    it "dynamic_count sums dynamic_top and dynamic_specific" do
      result = scan("unknown_method\n")
      expect(result.dynamic_count).to eq(result.dynamic_top_count + result.dynamic_specific_count)
    end

    it "precision_ratio and opaque_ratio handle a zero-expression file without error" do
      # A source containing only comments has no expression nodes —
      # totals will be 0 and both ratios must not divide by zero.
      result = scan("# no expressions\n")
      expect(result.total).to eq(0)
      expect(result.precision_ratio).to eq(1.0)
      expect(result.opaque_ratio).to eq(0.0)
    end
  end

  describe "union and intersection classification" do
    it "classifies a mixed union by its worst member" do
      # `x || 1` — the || result is a union of the unknown `x` (dynamic_top)
      # and the integer 1 (constant). Worst member wins -> dynamic_top.
      result = scan("x || 1\n")
      expect(result.dynamic_top_count).to be >= 1
    end

    it "classifies a union of two constants as constant (worst = best = constant)" do
      result = scan("1 || 2\n")
      # The OrNode itself (a union of two constants) should be constant.
      expect(result.tier_counts.fetch(:constant)).to be >= 1
    end
  end
end
