# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `ExpressionTyper::ControlFlow` types the control-flow nodes in value position: `if` / `unless` and
# `and` / `or` (delegated to the statement evaluator), `case` with its three-valued `when` certainty, and `begin` /
# `rescue` / `expr rescue fallback`. The examples parse a snippet and call the entry with a scope that binds the
# locals the snippet reads and a real typer over it, the module's callbacks being `type_of`, `statements_or_nil`,
# `typer_under` and `block_level_jump?`.
#
# Three guards no example distinguishes: `case_when_branch_certainty`'s `return :maybe if results.empty?` (a `when` clause
# always has a condition, so `results` is never empty); `type_of_case`'s `return type_of_case_simple_union(node, typer) if
# node.is_a?(CaseMatchNode)` (a `case ... in` through the predicate path types the same arms and the same `nil`, tried with
# class, literal and binding patterns); and `type_of_loop`'s `return constant_of(nil) if break_free_condition_loop?` (a
# loop nothing breaks out of evaluates to `nil` either way; the guard only skips evaluating the body).
RSpec.describe Rigor::Inference::ExpressionTyper::ControlFlow do
  let(:combinator) { Rigor::Type::Combinator }
  let(:integer) { combinator.nominal_of("Integer") }
  let(:string) { combinator.nominal_of("String") }
  let(:bool) { combinator.union(combinator.constant_of(true), combinator.constant_of(false)) }
  let(:scope) { Rigor::Scope.empty.with_local(:n, integer).with_local(:s, string).with_local(:u, combinator.union(integer, string)).with_local(:b, bool) }
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope) }

  def node_of(source) = Prism.parse(source, scopes: [%i[n s u b]]).value.statements.body.first

  def typer_over(over) = Rigor::Inference::ExpressionTyper.new(scope: over)

  def case_type(source, over = scope)
    described_class.type_of_case(node_of(source), over, nil, Rigor::Inference::ExpressionTyper.new(scope: over))
  end

  describe ".type_of_conditional and .type_of_and_or" do
    it "types a value-position `if` as the union of its branches" do
      expect(described_class.type_of_conditional(node_of("b ? 1 : :a"), scope, nil).describe).to eq("1 | :a")
    end

    it "elides the arm a decided predicate never takes" do
      expect(described_class.type_of_conditional(node_of("n ? 1 : :a"), scope, nil).describe).to eq("1")
    end

    it "narrows by the predicate, as the statement form does" do
      nilable = scope.with_local(:n, combinator.union(integer, combinator.constant_of(nil)))

      expect(described_class.type_of_conditional(node_of("n ? n : 0"), nilable, nil).describe).to eq("0 | Integer")
    end

    it "types `and` / `or` through the statement evaluator's short-circuit" do
      expect(described_class.type_of_and_or(node_of("n && s"), scope, nil)).to equal(string)
      expect(described_class.type_of_and_or(node_of("b && s"), scope, nil).describe).to eq("String | false")
      expect(described_class.type_of_and_or(node_of("b || s"), scope, nil).describe).to eq("String | true")
    end
  end

  describe ".type_of_case" do
    it "keeps only the arm a class pattern certainly matches, and drops the `else`" do
      expect(case_type("case n when Integer then 1 else 2 end").describe).to eq("1")
    end

    it "drops an arm a class pattern certainly misses" do
      expect(case_type("case s when Integer then 1 else 2 end").describe).to eq("2")
    end

    it "keeps both arms and the `else` when a pattern may match" do
      expect(case_type("case u when Integer then 1 when String then :a else 3 end").describe).to eq("1 | 3 | :a")
    end

    it "decides a literal `when` against a Constant subject" do
      one = scope.with_local(:n, combinator.constant_of(1))

      expect(case_type("case n when 2 then :no when 1 then :yes else :else end", one).describe).to eq(":yes")
    end

    it "adds nil for an absent `else` when no clause certainly matches" do
      expect(case_type("case u when Integer then 1 end").describe).to eq("1?")
    end

    it "types each arm under the subject's clause narrowing" do
      expect(case_type("case u when Integer then u else :other end").describe).to eq(":other | Integer")
    end

    it "types a predicate-less `case` as its `if` chain" do
      expect(case_type("case when n then 1 else 2 end").describe).to eq("1 | 2")
    end

    it "keeps the arms after a decided one that a later `when` may still reach, until the first certain match" do
      expect(case_type("case n when Integer then 1 when foo then 2 end").describe).to eq("1")
    end

    it "types a predicate-less `case` through the evaluator, which narrows each arm by its condition" do
      expect(case_type("case when u.is_a?(String) then u else 0 end").describe).to eq("0 | String")
    end

    it "keeps a Regexp `when` against a Constant subject as undecided" do
      one = scope.with_local(:n, combinator.constant_of("abc"))

      expect(case_type("case n when /a/ then 1 else 2 end", one).describe).to eq("1 | 2")
    end

    it "keeps a `when` whose pattern is typed but not a Constant as undecided" do
      expect(case_type("case u when n then 1 else 2 end").describe).to eq("1 | 2")
    end

    it "types a `case ... in` as the union of its clauses and the `else`" do
      expect(case_type("case n\nin Integer then 1\nin String then :a\nend").describe).to eq("1 | :a | nil")
    end
  end

  describe ".type_of_begin" do
    def begin_type(source) = described_class.type_of_begin(node_of(source), scope, typer)

    it "types the body joined with every rescue body" do
      expect(begin_type("begin; n; rescue ArgumentError; s; rescue; 1; end").describe)
        .to eq("1 | Integer | String")
    end

    it "lets an `else` clause replace the body's value" do
      expect(begin_type("begin; n; rescue; s; else; 1; end").describe).to eq("1 | String")
    end

    it "forgets the `$!` an enclosing clause bound and reads a written local as Dynamic[top] in a rescue arm" do
      entered = scope.with_global(:"$!", string)

      expect(described_class.type_of_begin(node_of("begin; 1; rescue; $!; end"), entered, typer_over(entered)).describe)
        .to eq("1 | Dynamic[top]")
      expect(begin_type("begin; n = s; rescue; n; end").describe).to eq("Dynamic[top] | String")
    end

    it "types an empty body as nil and leaves `ensure` out of the value" do
      expect(begin_type("begin; ensure; n; end").describe).to eq("nil")
      expect(begin_type("begin; s; ensure; n; end").describe).to eq("String")
    end

    it "reads `$!` unbound by an enclosing clause and a body-written name as Dynamic[top] inside a rescue" do
      expect(begin_type("begin; c = 1; rescue; c; end").describe).to eq("1 | Dynamic[top]")
    end
  end

  describe ".type_of_rescue and .type_of_rescue_modifier" do
    it "types a rescue clause as its statements, typed under the arm scope" do
      rescue_node = node_of("begin; 1; rescue; s; end").rescue_clause

      expect(described_class.type_of_rescue(rescue_node, scope, typer)).to equal(string)
    end

    it "types `expr rescue fallback` as the union of both" do
      expect(described_class.type_of_rescue_modifier(node_of("n rescue s"), scope, typer).describe)
        .to eq("Integer | String")
    end

    it "binds `$!` to the rescued StandardError inside the fallback" do
      type = described_class.type_of_rescue_modifier(node_of("n rescue $!"), scope, typer)

      expect(type.describe).to eq("Integer | StandardError")
    end
  end

  describe ".type_of_loop" do
    it "types a loop no `break` leaves as nil without evaluating its body" do
      expect(described_class.type_of_loop(node_of("while b do 1 end"), scope, nil, typer).describe).to eq("nil")
    end

    it "types a `while` with a `break` as nil or the break value" do
      expect(described_class.type_of_loop(node_of("while b do break 2 end"), scope, nil, typer).describe).to eq("2?")
    end

    it "types a `for` loop as its collection" do
      expect(described_class.type_of_loop(node_of("for i in [1] do i end"), scope, nil, typer).describe).to eq("[1]")
    end
  end
end
