# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1016 — a bare `&&` / `||` narrows its right operand under the left operand's edge identically in statement
# position, where `StatementEvaluator#eval_and_or` owns it, and in value position (an array element, a receiver, the
# value `type-of` reports for a write), where `ExpressionTyper` types it. The value position used to type both
# operands in the entry scope, so `x.finite? && x` read `Float | false` while the statement bound
# `false | finite-float`. It also carried its own constant short-circuit, which the statement position lacked.
#
# Every example pins the precise expected type in all four positions, so two positions that are wide together cannot
# pass as "agreeing".
RSpec.describe "and/or narrowing across positions" do
  seed = <<~RUBY
    x = Float(ARGV[0])
    s = (ARGV.first if rand < 0.5)
    a = ARGV
    v = if rand < 0.5 then 1 else "str" end
    sym = if rand < 0.5 then :a else :b end
    key = ARGV[0].to_sym
    missable = table[key]
  RUBY

  # `uniform` and `table` are bound as `Hash[Symbol, V]` rather than seeded as literals: a literal's closed shape
  # answers a computed key with the nil arm the miss produces, while this carrier's read is the one `RbsDispatch`
  # types past `%a{implicitly-returns-nil}` — the optimistic lookup the issue #313 declines below are about.
  seed_locals = %i[uniform table]

  # Evaluates the seed, then types `expression` five ways: the value the statement evaluator produces for it as a
  # statement, the value `Scope#type_of` produces for it, the element of a one-element array literal around it, the
  # value of `probe = expression` as `Scope#type_of` reads the write node, and the receiver of a call as the checker
  # reads it — through the scope `ScopeIndexer` recorded for that receiver node. The array is unwrapped back to its
  # element so every position is compared against one string.
  define_method(:positions_of) do |expression|
    fragments = [expression, "[#{expression}]", "probe = #{expression}", "(#{expression}).itself"]
    program = Prism.parse("#{seed}#{fragments.join("\n")}\n", scopes: [seed_locals]).value
    statements = program.statements.body
    scope = statements[0..-5].reduce(empty_scope) { |acc, statement| acc.evaluate(statement).last }
    bare, array, write, call = statements.last(4)
    {
      statement: scope.evaluate(bare).first,
      value: scope.type_of(bare),
      element: scope.type_of(array).elements.first,
      receiver: indexed_type_of(program, call.receiver.body.body.first),
      write: scope.type_of(write)
    }.transform_values { |type| type.describe(:short) }
  end

  def empty_scope
    Rigor::Scope.empty(environment: Rigor::Environment.default)
                .with_local(:uniform, hash_of(1))
                .with_local(:table, hash_of("x", "y"))
  end

  def hash_of(*values)
    value = Rigor::Type::Combinator.union(*values.map { |v| Rigor::Type::Combinator.constant_of(v) })
    Rigor::Type::Combinator.nominal_of("Hash", type_args: [Rigor::Type::Combinator.nominal_of("Symbol"), value])
  end

  def indexed_type_of(program, node)
    Rigor::Inference::ScopeIndexer.index(program, default_scope: empty_scope)[node].type_of(node)
  end

  def expect_positions(expression, expected)
    positions = %i[statement value element receiver write]
    expect(positions_of(expression)).to eq(positions.to_h { |position| [position, expected] }), expression
  end

  it "seeds the entry types the families below narrow from" do
    expect(positions_of("[x, s, a, v, sym, missable]")[:value])
      .to eq('[Float, String?, Array[String], "str" | 1, :a | :b, "x" | "y"]')
  end

  describe "Float predicates and comparisons (ADR-109 WD5)" do
    it "narrows `finite?` on the `&&` edge" do
      expect_positions("x.finite? && x", "false | finite-float")
      expect_positions("!x.finite? || x", "finite-float | true")
    end

    it "narrows `nan?` on the `||` edge" do
      expect_positions("x.nan? || x", "non-nan-float | true")
    end

    it "narrows a comparison's truthy edge and keeps the entry type on its falsey edge, which admits NaN" do
      expect_positions("x > 0.0 && x", "Float[0.0..] | false")
      expect_positions("x > 0.0 || x", "Float | true")
    end

    it "hands the narrowed receiver to a projection in the right operand" do
      expect_positions("x.finite? && x.to_s", "false | numeric-string")
    end
  end

  describe "nil checks and truthiness" do
    it "narrows `nil?` and `!`" do
      expect_positions("s.nil? || s", "String | true")
      expect_positions("!s.nil? && s", "String | false")
      expect_positions("!s || s", "String | true")
    end

    it "narrows a bare truthiness operand" do
      expect_positions("s && s.upcase", "String?")
      expect_positions("s || s", "String?")
    end
  end

  describe "class guards" do
    it "narrows `is_a?` on both edges" do
      expect_positions("v.is_a?(Integer) && v", "1 | false")
      expect_positions("v.is_a?(Integer) || v", '"str" | true')
    end
  end

  describe "`respond_to?`" do
    it "proves the receiver non-nil on the `&&` edge" do
      expect_positions("s.respond_to?(:upcase) && s", "String | false")
    end
  end

  describe "`empty?`" do
    it "refines the receiver to a non-empty array on the `||` edge" do
      expect_positions("a.empty? || a", "non-empty-array[String] | true")
    end
  end

  describe "literal equality" do
    it "narrows a finite literal domain on both edges" do
      expect_positions("sym == :a && sym", ":a | false")
      expect_positions("sym == :a || sym", ":b | true")
    end
  end

  describe "nested compositions" do
    it "narrows the right operand of an `||` under the negated conjunction of a nested `&&`" do
      expect_positions("!(s && x.finite?) || [s, x]", "[String, finite-float] | true")
    end

    it "narrows a nested `&&` right operand under the falsey edge of the outer `||`" do
      expect_positions("s.nil? || (x.finite? && [s, x])", "bool | [String, finite-float]")
    end

    it "threads a binding made in the left operand into the right operand" do
      expect_positions("(y = s) && y.upcase", "String?")
    end
  end

  # Issue #313 — the constant short-circuit, which both positions now share, MUST decline an optimistically
  # nil-free left operand. Each decline is paired with a proof-carrying control that MUST still short-circuit,
  # because a decline passes by accident whenever the short-circuit stops working at all.
  describe "the constant short-circuit and its issue #313 decline" do
    it "short-circuits on a genuine constant left operand (the control)" do
      expect_positions("1 || s", "1")
      expect_positions("false && s", "false")
      expect_positions("nil && s", "nil")
      expect_positions('"abc".upcase.nil? && 5', "false")
      expect_positions('!"abc".upcase.nil? || 5', "true")
    end

    it "keeps the author's fallback when a uniform-valued lookup reads as a lone constant" do
      expect_positions("uniform[key] || 5", "1 | 5")
      expect_positions("uniform[key] || key", "1 | Symbol")
    end

    it "types the issue #313 composed nil guard identically, without concluding on the right operand's behalf" do
      # `x.nil? || y.nil?` over two optimistic lookups: each operand's `.nil?` answers `bool` since #1172
      # (the folded `Constant` is a bet, not a fact, and must not leak into a return summary), so the
      # short-circuit is not what is under test. What is pinned is that both positions agree, and
      # `optimistic_origin_spec.rb` / the runner's always-truthy specs pin that no consumer reads the
      # carrier's nil-freeness as proof.
      expect_positions("missable.nil? || table[key].nil?", "bool")
      expect_positions("!missable.nil? && !table[key].nil?", "bool")
    end

    it "keeps both arms of a conditional guarded by the composed #313 guard, in every position" do
      expect_positions("missable.nil? || table[key].nil? ? :none : 1", "1 | :none")
      expect_positions('"a".upcase.nil? || "b".upcase.nil? ? :none : 1', "1")
    end

    it "keeps the fallback when the optimistic lookup is bound inside the left operand" do
      expect_positions("(w = uniform[key]) || 5", "1 | 5")
    end

    it "keeps the right operand behind a `.nil?` or `!` guard over an optimistic lookup" do
      expect_positions("missable.nil? && 5", "5 | false")
      expect_positions("!missable.nil? || 5", "5 | true")
    end
  end
end
