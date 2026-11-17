# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::UnreachableBranch.diagnostic} on a parsed snippet and its scope index, with no
# runner. `collector_diagnostic_builders_spec.rb` pins the rule's branch selection and builder through the whole run.
# This is `flow.unreachable-branch`, the literal-predicate rule; `unreachable_clause_collector_spec.rb` is the
# unrelated `flow.unreachable-clause` collector.
#
# Mutation-proved: each guard line (a `return` modifier) of `diagnostic` was blanked in turn and an example here failed,
# except this one, which no input here distinguishes:
#
# - `return nil if scope.nil?`: every `if` / `unless` of an indexed snippet has a scope.
#
# `literal_predicate_polarity`'s `nil` answer, `unreachable_branch_for`'s `nil` answers and the node-class lists are
# pinned by the examples below, one literal class each (each list entry was removed in turn and an example failed,
# except `Prism::RegularExpressionNode`: a regexp literal in a condition parses as a `MatchLastLineNode`, so no
# `IfNode` predicate is a `RegularExpressionNode` here; `if (/x/)` and `if /x/ ... end` both tried).
RSpec.describe Rigor::Analysis::CheckRules::UnreachableBranch do
  def branches_in(node, found = [])
    found << node if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
    node.compact_child_nodes.each { |child| branches_in(child, found) }
    found
  end

  # `[line, column, message]` for each `if` / `unless` of `source` the rule reports.
  def fired(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    branches_in(program).filter_map do |node|
      row = described_class.diagnostic("mem.rb", node, scope_index)
      [row.line, row.column, row.message] if row
    end
  end

  def always(polarity)
    "unreachable branch: literal predicate is always #{polarity}"
  end

  describe "an `if`" do
    it "reports the else branch of a truthy literal, at the else clause" do
      expect(fired("if true\n  a = 1\nelse\n  b = 2\nend\n")).to eq([[3, 1, always("truthy")]])
    end

    it "reports the body of a falsey literal, at its first statement" do
      expect([fired("if false\n  a = 1\nelse\n  b = 2\nend\n"), fired("if nil\n  a\nelse\n  b\nend\n")]).to eq(
        [[[2, 3, always("falsey")]], [[2, 3, always("falsey")]]]
      )
    end

    it "treats a number, a string and a symbol literal as truthy" do
      expect(["1", "0.5", '"s"', ":s"].map { |literal| fired("if #{literal}\n  a\nelse\n  b\nend\n") }).to eq(
        [[[3, 1, always("truthy")]]] * 4
      )
    end

    it "is silent when the dead branch is absent or empty" do
      expect([fired("if true\n  a\nend\n"), fired("if false\nend\n"), fired("if true\n  a\nelse\nend\n").size]).to eq(
        [[], [], 1]
      )
    end

    it "reports the first `elsif` of a truthy literal, and a falsey literal's body before a later `elsif`" do
      expect([fired("if true\n  a\nelsif x\n  b\nelse\n  c\nend\n"),
              fired("if nil\n  a\nelsif true\n  b\nend\n")]).to eq(
                [[[3, 1, always("truthy")]], [[2, 3, always("falsey")]]]
              )
    end

    it "is silent for a predicate that is not a literal" do
      sources = ["if x\n  a\nelse\n  b\nend\n", "if (true)\n  a\nelse\n  b\nend\n",
                 "if !true\n  a\nelse\n  b\nend\n", "if [1]\n  a\nelse\n  b\nend\n"]

      expect(sources.map { |source| fired(source) }).to eq([[]] * 4)
    end

    it "reports a one-line `if`, and a ternary" do
      expect([fired("if false then a else b end\n"), fired("x = (false ? 1 : 2)\n"), fired("x = (true ? 1 : 2)\n")])
        .to eq([[[1, 15, always("falsey")]], [[1, 14, always("falsey")]], [[1, 15, always("truthy")]]])
    end
  end

  describe "an `unless`" do
    it "reports the body of a truthy literal, and the else branch of a falsey one" do
      expect([fired("unless true\n  a\nelse\n  b\nend\n"), fired("unless false\n  a\nelse\n  b\nend\n")]).to eq(
        [[[2, 3, always("truthy")]], [[3, 1, always("falsey")]]]
      )
    end

    it "is silent when the dead branch is absent or empty" do
      expect([fired("unless nil\n  a\nend\n"), fired("unless true\nend\n")]).to eq([[], []])
    end
  end

  describe "a modifier" do
    it "reports the statement a falsey `if` or a truthy `unless` guards, and not the live one" do
      expect([fired("a if false\n"), fired("a unless true\n"), fired("a if true\n"), fired("a unless false\n")]).to eq(
        [[[1, 1, always("falsey")]], [[1, 1, always("truthy")]], [], []]
      )
    end
  end

  it "carries the rule id, the warning severity and the path, with no method or receiver" do
    program = Prism.parse("if false\n  a\nend\n").value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    row = described_class.diagnostic("mem.rb", branches_in(program).first, scope_index)

    expect([row.rule, row.severity, row.path, row.method_name, row.receiver_type]).to eq(
      [Rigor::Analysis::CheckRules::RULE_UNREACHABLE_BRANCH, :warning, "mem.rb", nil, nil]
    )
  end
end
