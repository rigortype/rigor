# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1003 — a predicate guard narrows its subject identically whichever way the conditional is spelled
# (`if` / ternary / `unless` block / `unless` modifier) and wherever it sits: in statement position, where
# `StatementEvaluator#eval_if` owns it, and in value position (an argument, a receiver, a literal element,
# the `type-of` of a write node), where `ExpressionTyper` types it. The value position used to type both arms
# in the entry scope, so `f.finite? ? f : 0.0` read `0.0 | Float`.
#
# Every family pins the precise expected arm type as well as the agreement, so two spellings that are wide
# together cannot pass as "agreeing".
RSpec.describe "conditional narrowing across spellings and positions" do
  seed = <<~RUBY
    x = Float(ARGV[0])
    s = (ARGV.first if rand < 0.5)
    a = ARGV
    v = if rand < 0.5 then 1 else "str" end
    sym = if rand < 0.5 then :a else :b end
  RUBY

  # Evaluates the seed, then types the fragment's single statement both ways: the value the statement
  # evaluator produces and the value `Scope#type_of` produces. The fragment is parsed after the seed so its
  # identifiers are local reads.
  define_method(:types_of) do |fragment|
    statements = Prism.parse("#{seed}#{fragment}\n").value.statements.body
    scope = Rigor::Scope.empty(environment: Rigor::Environment.default)
    statements[0..-2].each { |statement| scope = scope.evaluate(statement).last }
    node = statements.last
    node = node.body.body.first if node.is_a?(Prism::ParenthesesNode)
    {
      statement: scope.evaluate(node).first.describe(:short),
      value: scope.type_of(node).describe(:short)
    }
  end

  def spellings(guard, subject)
    {
      "if (truthy arm)" => "if #{guard} then #{subject} else :no end",
      "ternary (truthy arm)" => "#{guard} ? #{subject} : :no",
      "if (falsey arm)" => "if #{guard} then :no else #{subject} end",
      "ternary (falsey arm)" => "#{guard} ? :no : #{subject}"
    }
  end

  def expect_spellings_agree(guard, subject, truthy:, falsey:)
    spellings(guard, subject).each do |label, fragment|
      expected = label.include?("truthy") ? truthy : falsey
      expect(types_of(fragment)).to eq({ statement: expected, value: expected }), "#{label}: #{fragment}"
    end
  end

  it "seeds the entry types the families below narrow from" do
    expect(types_of("[x, s, a, v, sym]")[:value]).to eq('[Float, String?, Array[String], "str" | 1, :a | :b]')
  end

  describe "Float predicates and comparisons (ADR-109 WD5)" do
    it "narrows `finite?` on the truthy arm only" do
      expect_spellings_agree("x.finite?", "x", truthy: ":no | finite-float", falsey: ":no | Float")
    end

    it "narrows `nan?` on the falsey arm only" do
      expect_spellings_agree("x.nan?", "x", truthy: ":no | Float", falsey: ":no | non-nan-float")
    end

    it "keeps the entry type on a comparison's falsey arm, which admits NaN" do
      expect_spellings_agree("x > 0.0", "x", truthy: ":no | Float[0.0..]", falsey: ":no | Float")
      expect_spellings_agree("x.between?(0.0, 1.0)", "x", truthy: ":no | Float[0.0..1.0]", falsey: ":no | Float")
    end

    it "hands the narrowed receiver to a projection inside the arm" do
      expect_spellings_agree("x.finite?", "x.to_s", truthy: ":no | numeric-string", falsey: ":no | non-empty-string")
    end
  end

  describe "nil checks and truthiness" do
    it "narrows `nil?`, `== nil`, and `!`" do
      expect_spellings_agree("s.nil?", "s", truthy: ":no?", falsey: ":no | String")
      expect_spellings_agree("s == nil", "s", truthy: ":no?", falsey: ":no | String")
      expect_spellings_agree("!s", "s", truthy: ":no?", falsey: ":no | String")
    end

    it "narrows a bare truthiness guard" do
      expect_spellings_agree("s", "s", truthy: ":no | String", falsey: ":no?")
    end
  end

  describe "class guards" do
    it "narrows `is_a?`, `kind_of?`, and `instance_of?` on both arms" do
      expect_spellings_agree("v.is_a?(Integer)", "v", truthy: "1 | :no", falsey: '"str" | :no')
      expect_spellings_agree("v.kind_of?(String)", "v", truthy: '"str" | :no', falsey: "1 | :no")
      expect_spellings_agree("v.instance_of?(Integer)", "v", truthy: "1 | :no", falsey: '"str" | :no')
    end
  end

  describe "`respond_to?`" do
    it "proves the receiver non-nil on the truthy arm and keeps the entry type on the falsey arm" do
      expect_spellings_agree("s.respond_to?(:upcase)", "s", truthy: ":no | String", falsey: ":no | String | nil")
    end
  end

  describe "`empty?`" do
    it "refines the receiver to a non-empty array on the falsey arm" do
      expect_spellings_agree("a.empty?", "a", truthy: ":no | Array[String]", falsey: ":no | non-empty-array[String]")
    end
  end

  describe "literal equality" do
    it "narrows a finite literal domain on both arms" do
      expect_spellings_agree("sym == :a", "sym", truthy: ":a | :no", falsey: ":b | :no")
    end
  end

  describe "compound conditions" do
    it "narrows the conjunction of an `&&` guard on its truthy arm" do
      expect_spellings_agree("s && x > 0.0", "[s, x]",
                             truthy: ":no | [String, Float[0.0..]]", falsey: ":no | [String?, Float]")
    end

    it "narrows the conjunction of an `||` guard on its falsey arm" do
      expect_spellings_agree("s.nil? || !x.finite?", "[s, x]",
                             truthy: ":no | [String?, Float]", falsey: ":no | [String, finite-float]")
    end
  end

  describe "`unless`" do
    it "agrees between the modifier, the block form, and the negated `if`" do
      expected = "non-nan-float?"
      ["(x unless x.nan?)", "unless x.nan? then x end", "if !x.nan? then x end"].each do |fragment|
        expect(types_of(fragment)).to eq({ statement: expected, value: expected }), fragment
      end
    end
  end

  describe "a conditional nested inside the condition" do
    # Issue #1017 — a conditional used AS a predicate narrows like its `&&` equivalent
    # (`nested_conditional_guard_narrowing_spec.rb` pairs the families); what this pins is that the ternary and the
    # `if` spelling of the nested predicate agree with each other and with `!s.nil? && x.finite?`.
    it "types the ternary and the `if` spelling of the nested predicate identically" do
      ternary = types_of("(s.nil? ? false : x.finite?) ? [s, x] : :no")
      if_form = types_of("(if s.nil? then false else x.finite? end) ? [s, x] : :no")
      expect(ternary).to eq(if_form)
      expect(ternary).to eq(types_of("(!s.nil? && x.finite?) ? [s, x] : :no"))
      expect(ternary).to eq({ statement: ":no | [String, finite-float]", value: ":no | [String, finite-float]" })
    end

    it "narrows the arms of a ternary nested inside another conditional's arm" do
      expect(types_of("x.nan? ? :no : (x.finite? ? x : :inf)"))
        .to eq({ statement: ":inf | :no | finite-float", value: ":inf | :no | finite-float" })
    end
  end
end
