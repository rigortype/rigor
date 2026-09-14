# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1017 — a conditional used as the condition of another conditional narrows exactly as its `&&` / `||`
# equivalent does. `p ? q : r` is truthy through `p ∧ q` or `¬p ∧ r` and falsey through `p ∧ ¬q` or `¬p ∧ ¬r`,
# so `(s.nil? ? false : x.finite?) ? x : 0.0` narrows `x` to `finite-float` in its truthy arm, as
# `(!s.nil? && x.finite?) ? x : 0.0` always did.
#
# Every example types the nested guard and its equivalent in both arms, in statement position, in value position,
# and inside the arm as `ScopeIndexer` records it, against one pinned expected type per arm, so two guards that are
# equally wide cannot pass as "agreeing".
RSpec.describe "a conditional used as a condition" do
  seed = <<~RUBY
    x = Float(ARGV[0])
    s = (ARGV.first if rand < 0.5)
    v = if rand < 0.5 then 1 else "str" end
    sym = if rand < 0.5 then :a else :b end
    key = ARGV[0].to_sym
    uniform = { a: 1, b: 1 }
    table = { a: "x", b: "y" }
    missable = table[key]
  RUBY

  def empty_scope
    Rigor::Scope.empty(environment: Rigor::Environment.default)
  end

  # Types `subject` in one arm of `(guard) ? … : …`: the conditional's value as a statement and as a value, and the
  # subject itself inside the arm through the scope `ScopeIndexer` recorded for it.
  define_method(:arm_types) do |guard, subject, arm|
    fragment = arm == :truthy ? "(#{guard}) ? #{subject} : :no" : "(#{guard}) ? :no : #{subject}"
    program = Prism.parse("#{seed}#{fragment}\n").value
    statements = program.statements.body
    scope = statements[0..-2].reduce(empty_scope) { |acc, statement| acc.evaluate(statement).last }
    conditional = statements.last
    arm_node = (arm == :truthy ? conditional.statements : conditional.subsequent.statements).body.first
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: empty_scope)
    {
      statement: scope.evaluate(conditional).first.describe(:short),
      value: scope.type_of(conditional).describe(:short),
      arm: index[arm_node].type_of(arm_node).describe(:short)
    }
  end

  # Every guard — the nested spellings and, last, the `&&` / `||` equivalent — MUST type the subject inside each arm
  # as pinned, and the whole conditional identically in statement and value position and to the equivalent.
  def expect_guards(guards, subject:, truthy:, falsey:)
    { truthy: truthy, falsey: falsey }.each do |arm, expected|
      reference = arm_types(guards.last, subject, arm)
      guards.each do |guard|
        types = arm_types(guard, subject, arm)
        expect(types[:arm]).to eq(expected), "#{arm} arm of `#{guard}`: got #{types[:arm]}, expected #{expected}"
        expect(types[:statement]).to eq(types[:value]), "#{arm} arm of `#{guard}` (statement vs value)"
        expect(types[:value]).to eq(reference[:value]), "#{arm} arm of `#{guard}` (value vs `#{guards.last}`)"
      end
    end
  end

  it "seeds the entry types the families below narrow from" do
    expect(arm_types("true", "[x, s, v, sym, missable]", :truthy)[:arm])
      .to eq('[Float, String?, "str" | 1, :a | :b, "x" | "y"]')
  end

  describe "the issue #1017 reproduction" do
    it "narrows `finite?` behind a `nil?` guard with a literal `false` arm, like `!p && q`" do
      expect_guards(
        [
          "s.nil? ? false : x.finite?",
          "if s.nil? then false else x.finite? end",
          "unless s.nil? then x.finite? else false end",
          "!(s.nil? ? true : !x.finite?)",
          "!s.nil? && x.finite?"
        ],
        subject: "[s, x]", truthy: "[String, finite-float]", falsey: "[String?, Float]"
      )
    end
  end

  describe "Float predicates and comparisons (ADR-109 WD5)" do
    it "narrows `nan?` on the edge its `&&` / `||` equivalent narrows" do
      expect_guards(["x.nan? ? false : s.nil?", "!x.nan? && s.nil?"],
                    subject: "[s, x]", truthy: "[nil, non-nan-float]", falsey: "[String?, Float]")
      expect_guards(["x.nan? ? true : s.nil?", "x.nan? || s.nil?"],
                    subject: "[s, x]", truthy: "[String?, Float]", falsey: "[String, non-nan-float]")
    end

    it "keeps the entry type on a comparison's falsey edge, which admits NaN" do
      expect_guards(["s.nil? ? false : x > 0.0", "!s.nil? && x > 0.0"],
                    subject: "[s, x]", truthy: "[String, Float[0.0..]]", falsey: "[String?, Float]")
      expect_guards(["x > 0.0 ? s.nil? : false", "x > 0.0 && s.nil?"],
                    subject: "[s, x]", truthy: "[nil, Float[0.0..]]", falsey: "[String?, Float]")
      expect_guards(["x > 0.0 ? true : s.nil?", "x > 0.0 || s.nil?"],
                    subject: "[s, x]", truthy: "[String?, Float]", falsey: "[String, Float]")
    end
  end

  describe "class guards and literal equality" do
    it "narrows `is_a?` and `==` on the edge the `&&` / `||` equivalent narrows" do
      expect_guards(["v.is_a?(Integer) ? sym == :a : false", "v.is_a?(Integer) && sym == :a"],
                    subject: "[v, sym]", truthy: "[1, :a]", falsey: '["str" | 1, :a | :b]')
      expect_guards(["v.is_a?(Integer) ? true : sym == :a", "v.is_a?(Integer) || sym == :a"],
                    subject: "[v, sym]", truthy: '["str" | 1, :a | :b]', falsey: '["str", :b]')
    end
  end

  describe "literal arms fall out of the general rule" do
    it "reads `p ? q : nil` and an `if` with no `else` as `p && q`" do
      expect_guards(["s ? x.finite? : nil", "if s then x.finite? end", "s && x.finite?"],
                    subject: "[s, x]", truthy: "[String, finite-float]", falsey: "[String?, Float]")
    end

    it "reads `p ? true : q` as `p || q` and `p ? q : true` as `!p || q`" do
      expect_guards(["s ? true : x.finite?", "s || x.finite?"],
                    subject: "[s, x]", truthy: "[String?, Float]", falsey: "[nil, Float]")
      expect_guards(["s ? x.finite? : true", "!s || x.finite?"],
                    subject: "[s, x]", truthy: "[String?, Float]", falsey: "[String, Float]")
    end
  end

  describe "non-literal arms" do
    it "joins `p ∧ q` with `¬p ∧ r` on each edge" do
      expect_guards(["s.nil? ? x.finite? : x.finite?", "(s.nil? && x.finite?) || (!s.nil? && x.finite?)"],
                    subject: "[s, x]", truthy: "[String?, finite-float]", falsey: "[String?, Float]")
    end
  end

  # ADR-101 / issue #313 — an arm, or the inner predicate, whose truthiness rests on an optimistically nil-free
  # lookup is not proof that an edge is dead. Without the decline the nested guard over-narrows `s`; the `&&` / `||`
  # equivalent never concluded on it.
  describe "the optimistic-carrier decline" do
    it "does not read an optimistic arm as always truthy" do
      expect_guards(["s.nil? ? uniform[key] : false", "s.nil? && uniform[key]"],
                    subject: "s", truthy: "nil", falsey: "String?")
    end

    it "does not read an optimistic inner predicate as always falsey" do
      expect_guards(["missable.nil? ? true : s.nil?", "missable.nil? || s.nil?"],
                    subject: "s", truthy: "String?", falsey: "String")
    end
  end

  describe "the nesting cap" do
    it "narrows a conditional nested two deep in condition position" do
      expect_guards(["(s.nil? ? true : false) ? false : x.finite?", "!s.nil? && x.finite?"],
                    subject: "[s, x]", truthy: "[String, finite-float]", falsey: "[String?, Float]")
    end

    it "contributes no facts once the nesting exceeds the cap" do
      expect(Rigor::Inference::Narrowing::CONDITIONAL_GUARD_DEPTH).to eq(2)
      expect_guards(["((s.nil? ? true : false) ? true : false) ? false : x.finite?"],
                    subject: "[s, x]", truthy: "[String?, Float]", falsey: "[String?, Float]")
    end
  end
end
