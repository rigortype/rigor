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
      # `1` parses as Program > Statements > IntegerNode; the two wrappers are non-expressions and must not be counted.
      result = scan("1\n")
      expect(result.total).to eq(1)
      expect(result.tier_counts.fetch(:constant)).to eq(1)
      expect(result.precision_ratio).to eq(1.0)
    end

    it "skips the ArgumentsNode container but counts the call and its arguments" do
      # `foo(1, 2)` => Call + Arguments + two Integers (+ Program / Statements). Counted: the CallNode (opaque — foo is
      # unknown) and the two Integer literals (constant). Arguments / Program / Statements are skipped.
      result = scan("foo(1, 2)\n")
      expect(result.total).to eq(3)
      expect(result.tier_counts.fetch(:constant)).to eq(2)
      expect(result.dynamic_top_count).to eq(1)
    end

    it "does not count parameter declarations in a method definition" do
      # The def's parameter list and each RequiredParameterNode are non-expressions; the parameter *reads* in the body
      # are not.
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
      # A source containing only comments has no expression nodes — totals will be 0 and both ratios must not divide by
      # zero.
      result = scan("# no expressions\n")
      expect(result.total).to eq(0)
      expect(result.precision_ratio).to eq(1.0)
      expect(result.opaque_ratio).to eq(0.0)
    end
  end

  # Issue #523 — every precisely-folded carrier must land in a precise tier. These five fell through
  # `classify`'s `else` arm to `:dynamic_top`, so 810 ADR-48 Data / Struct and bound-method sites on this
  # repository's own `lib` were counted OPAQUE by the ratio `rigor coverage` and the `make coverage`
  # gate report. The spec enumerates them so a future carrier addition fails loud instead of silently
  # diluting the ratio.
  describe "carrier classification" do
    let(:scanner) { described_class.new }

    it "classifies DataClass and StructClass as nominal (class-side carriers, like Singleton)" do
      data_class = Rigor::Type::Combinator.data_class_of(members: %i[x y], class_name: "Point")
      struct_class = Rigor::Type::Combinator.struct_class_of(members: %i[a], class_name: "Row")
      expect(scanner.send(:classify, data_class)).to eq(:nominal)
      expect(scanner.send(:classify, struct_class)).to eq(:nominal)
    end

    it "classifies DataInstance, StructInstance, and BoundMethod as shaped" do
      int = Rigor::Type::Combinator.constant_of(1)
      data_instance = Rigor::Type::Combinator.data_instance_of(members: { x: int }, class_name: "Point")
      struct_instance = Rigor::Type::Combinator.struct_instance_of(members: { a: int }, class_name: "Row")
      bound = Rigor::Type::Combinator.bound_method_of(Rigor::Type::Combinator.nominal_of("String"), :upcase)
      expect(scanner.send(:classify, data_instance)).to eq(:shaped)
      expect(scanner.send(:classify, struct_instance)).to eq(:shaped)
      expect(scanner.send(:classify, bound)).to eq(:shaped)
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

    it "classifies an Intersection by its most precise member (best_of)" do
      scanner = described_class.new
      inter = Rigor::Type::Combinator.intersection(
        Rigor::Type::Combinator.nominal_of("String"), Rigor::Type::Combinator.constant_of(1)
      )
      expect(scanner.send(:classify, inter)).to eq(:constant)
    end

    it "classifies a Difference by its base type" do
      scanner = described_class.new
      diff = Rigor::Type::Combinator.difference(
        Rigor::Type::Combinator.nominal_of("String"), Rigor::Type::Combinator.constant_of(1)
      )
      expect(scanner.send(:classify, diff)).to eq(:nominal)
    end
  end

  describe "FileResult tier accessors (exact per-tier counts)" do
    # The existing helper tests assert ratios and self-referential sums, so the per-tier `tier_counts.fetch` reads
    # survive mutation. Pin the exact counts to bite a wrong key / default.
    let(:result) do
      described_class::FileResult.new(
        total: 9,
        tier_counts: {
          constant: 2, nominal: 1, shaped: 1, refined: 1, bot: 1,
          dynamic_top: 1, dynamic_specific: 1, top: 1
        }
      )
    end

    it "precise_count sums exactly the precise tiers (constant/nominal/shaped/refined/bot)" do
      expect(result.precise_count).to eq(6)
    end

    it "reads dynamic_top_count and dynamic_specific_count from their own tiers" do
      expect(result.dynamic_top_count).to eq(1)
      expect(result.dynamic_specific_count).to eq(1)
    end

    it "opaque_count sums the dynamic_top and top tiers" do
      expect(result.opaque_count).to eq(2)
    end

    it "defaults absent tiers to zero across every accessor" do
      # An empty count map exercises each `fetch(tier, 0)` default — the present-key cases above never reach it, so the
      # default survives mutation unless a key is genuinely absent.
      empty = described_class::FileResult.new(total: 0, tier_counts: {})

      expect(empty.precise_count).to eq(0)
      expect(empty.dynamic_top_count).to eq(0)
      expect(empty.dynamic_specific_count).to eq(0)
      expect(empty.opaque_count).to eq(0)
    end
  end
end
