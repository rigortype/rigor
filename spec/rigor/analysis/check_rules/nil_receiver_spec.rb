# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::NilReceiver} on a parsed snippet and its scope index, with no runner. The runner
# specs (`remaining_rule_families_spec.rb`, `safe_navigation_undefined_method_spec.rb`,
# `union_undefined_method_spec.rb`) pin the rule through the whole run.
#
# The snippet is indexed against an empty scope, so a call is judged on what the snippet itself records, with the core
# RBS the empty scope carries.
#
# Mutation-proved: each guard line (a `return` / `next` modifier) of `diagnostic`, `nil_receiver_withheld?`,
# `union_has_nameable_non_nil_arm?`, `union_method_present_on_non_nil?` and `nil_class_has_method?` was blanked in turn
# and an example here failed, except these, which no input here distinguishes (one line on what was tried each):
#
# - `return nil if call_node.receiver.nil?`: a receiver-less call fails the next line's `LocalVariableReadNode` test.
# - `return nil if scope.nil?`: every call of an indexed snippet has a scope.
# - `return nil if scope.inferred_param?(...)`: true only for a parameter whose type the whole-project run infers from
#   its call sites; `def t(x) = x.upcase` with `t(nil)` and `t("s")` callers in the one file leaves `x` untyped.
# - `return nil unless Rigor::Reflection.rbs_class_known?("NilClass", ...)`: the empty scope has the core RBS.
# - `next false if class_name.nil?` in `union_has_nameable_non_nil_arm?`: the `rbs_class_known?` / `discovered_classes`
#   test after it answers false for a nil class name too (tried an untyped arm with nil; both orders agree).
# - `return false if non_nil_members.empty?` in `union_method_present_on_non_nil?`: a union with no non-nil arm fails
#   the earlier `union_has_nameable_non_nil_arm?` first.
# - `return false if definition.nil?` in `nil_class_has_method?`: the core RBS always has a `NilClass` definition.
RSpec.describe Rigor::Analysis::CheckRules::NilReceiver do
  def calls_in(node, found = [])
    found << node if node.is_a?(Prism::CallNode)
    node.compact_child_nodes.each { |child| calls_in(child, found) }
    found
  end

  def scope_index_of(program)
    Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
  end

  # `[line, message]` for each call of `source` the rule reports.
  def fired(source)
    program = Prism.parse(source).value
    scope_index = scope_index_of(program)
    sites = Rigor::Analysis::CheckRules::LexicalMethodSites.new(program)
    calls_in(program).filter_map do |call|
      facts = Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index)
      row = described_class.diagnostic("mem.rb", call, facts, sites)
      [call.location.start_line, row.message] if row
    end
  end

  let(:nilable) { "def t(c)\n  x = c ? \"s\" : nil\n" }

  describe "a nilable local" do
    it "reports a call NilClass does not define" do
      expect(fired("#{nilable}  x.upcase\nend\n")).to eq(
        [[3, "possible nil receiver: `upcase' is undefined on NilClass"]]
      )
    end

    it "carries the rule id, the error severity and the method name" do
      program = Prism.parse("#{nilable}  x.upcase\nend\n").value
      call = calls_in(program).find { |c| c.name == :upcase }
      facts = Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index_of(program))
      row = described_class.diagnostic("mem.rb", call, facts)

      expect([row.rule, row.severity, row.method_name, row.path, row.line, row.column]).to eq(
        [Rigor::Analysis::CheckRules::RULE_NIL_RECEIVER, :error, "upcase", "mem.rb", 3, 5]
      )
    end

    it "reports a call that is the receiver of a further call, at the inner one" do
      expect(fired("#{nilable}  x.upcase.size\nend\n").map(&:first)).to eq([3])
    end

    it "reports a union of two non-nil arms and nil when every non-nil arm has the method" do
      expect(fired("def t(c)\n  x = c ? \"s\" : (c ? 1 : nil)\n  x.succ\nend\n").map(&:first)).to eq([3])
    end

    it "is silent for a method NilClass defines" do
      expect([fired("#{nilable}  x.to_s\nend\n"), fired("#{nilable}  x.nil?\nend\n")]).to eq([[], []])
    end

    it "is silent for a method no non-nil arm has" do
      expect(fired("#{nilable}  x.zzz\nend\n")).to eq([])
    end

    it "is silent for a method only some non-nil arm has" do
      expect(fired("def t(c)\n  x = c ? \"s\" : (c ? 1 : nil)\n  x.upcase\nend\n")).to eq([])
    end

    it "is silent after a nil guard narrows the local" do
      expect(fired("#{nilable}  return if x.nil?\n  x.upcase\nend\n")).to eq([])
    end

    it "is silent for a safe-navigation call" do
      expect(fired("#{nilable}  x&.upcase\nend\n")).to eq([])
    end

    it "is silent under a refinement of NilClass in effect" do
      source = "module R\n  refine NilClass do\n    def upcase = 1\n  end\nend\nusing R\n#{nilable}  x.upcase\nend\n"

      expect(fired(source)).to eq([])
    end
  end

  describe "other receivers" do
    it "is silent for an instance variable" do
      expect(fired("class A\n  def t(c)\n    @x = c ? \"s\" : nil\n    @x.upcase\n  end\nend\n")).to eq([])
    end

    it "is silent for a method-call receiver" do
      expect(fired("def t(c)\n  (c ? \"s\" : nil).upcase\nend\n")).to eq([])
    end

    it "is silent for an implicit-self call" do
      expect(fired("def t\n  upcase\nend\n")).to eq([])
    end

    it "is silent for a local that is only nil (not a union)" do
      expect(fired("x = nil\nx.upcase\n")).to eq([])
    end

    it "is silent when the other arm names no class (an untyped value)" do
      expect(fired("def t(c, d)\n  x = c ? d : nil\n  x.upcase\nend\n")).to eq([])
    end

    it "is silent for a read a `key?` guard on the same computed key rules out" do
      source = "MAP = { integer: { type: :integer }, string: { type: :string } }.freeze\n" \
               "def by_local(prop)\n  k = prop.column_type\n  if MAP.key?(k)\n    r = MAP[k].dup\n    " \
               "r[:a] = 1\n  end\nend\n"

      expect(fired(source)).to eq([])
    end

    it "is silent for a local copied from an ivar a constructor seeds with nil" do
      source = "class A\n  def initialize\n    @r = nil\n  end\n  def set = @r = \"s\"\n  " \
               "def t\n    r = @r\n    r.upcase\n  end\nend\n"

      expect(fired(source)).to eq([])
    end

    it "reports a local whose nil the method itself writes" do
      source = "class A\n  def t(c)\n    r = c ? \"s\" : nil\n    r.upcase\n  end\nend\n"

      expect(fired(source).map(&:first)).to eq([4])
    end
  end

  describe ".union_contains_nil?" do
    let(:combinator) { Rigor::Type::Combinator }

    it "is true for a union with a `nil` member and for one with a `NilClass` member" do
      with_constant = combinator.union(combinator.nominal_of("String"), combinator.constant_of(nil))
      with_nominal = combinator.union(combinator.nominal_of("String"), combinator.nominal_of("NilClass"))

      expect([with_constant, with_nominal].map { |u| described_class.union_contains_nil?(u) }).to eq([true, true])
    end

    it "is false for a union without a nil member" do
      union = combinator.union(combinator.nominal_of("String"), combinator.nominal_of("Integer"))

      expect(described_class.union_contains_nil?(union)).to be(false)
    end
  end

  describe ".nil_class_has_method?" do
    let(:scope) { Rigor::Scope.empty }

    it "is true for a method NilClass defines, given as a string or a symbol" do
      expect([described_class.nil_class_has_method?("to_s", scope),
              described_class.nil_class_has_method?(:nil?, scope)])
        .to eq([true, true])
    end

    it "is false for a method it does not" do
      expect(described_class.nil_class_has_method?(:upcase, scope)).to be(false)
    end
  end

  it "keeps its helpers private" do
    names = %i[nil_receiver_withheld? nil_bearing_union_witnesses? union_has_nameable_non_nil_arm?
               union_method_present_on_non_nil? build_nil_receiver_diagnostic]

    expect(names.map { |m| described_class.respond_to?(m) }).to eq([false] * 5)
  end
end
