# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::SelfUndefinedMethod.diagnostics} over a hand-built miss and the scope index of the
# class it sits in, with no runner. The recorder that produces real misses is `SelfCallResolutionRecorder`.
RSpec.describe Rigor::Analysis::CheckRules::SelfUndefinedMethod do
  def rows_for(source, class_name: "Foo")
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    call = find_call(program, :helper)
    miss = Rigor::Analysis::SelfCallResolutionRecorder::UnresolvedSelfCall.new(
      class_name: class_name, method_name: :helper, node: call, path: "mem.rb", line: 2, column: 11
    )
    described_class.diagnostics("mem.rb", [miss], program, scope_index)
  end

  def find_call(node, name)
    found = nil
    walk = lambda do |n|
      found = n if n.is_a?(Prism::CallNode) && n.name == name
      n.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(node)
    found
  end

  it "reports an implicit-self call no method of a standalone closed class answers" do
    rows = rows_for("class Foo\n  def a = helper\nend\n")

    expect(rows.map(&:rule)).to eq([Rigor::Analysis::CheckRules::RULE_SELF_UNDEFINED_METHOD])
    expect(rows.first.message).to include("implicit-self call to `helper` resolves to no method on `Foo`")
  end

  it "is silent when a project subclass defines the method (a template-method hook)" do
    expect(rows_for("class Foo\n  def a = helper\nend\nclass Bar < Foo\n  def helper = 1\nend\n")).to be_empty
  end

  it "is silent when the class has a superclass the engine may not read" do
    expect(rows_for("class Foo < Base\n  def a = helper\nend\n")).to be_empty
  end

  it "is silent when the class includes a mixin" do
    expect(rows_for("class Foo\n  include Mixin\n  def a = helper\nend\n")).to be_empty
  end

  it "is silent when the class defines `method_missing`" do
    expect(rows_for("class Foo\n  def method_missing(*) = nil\n  def a = helper\nend\n")).to be_empty
  end

  it "is silent for a class whose surface a dynamic `attr_*` accessor synthesizes" do
    expect(rows_for("class Foo\n  attr_reader(*NAMES)\n  def a = helper\nend\n")).to be_empty
  end

  it "answers nothing for no misses" do
    program = Prism.parse("class Foo; end\n").value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)

    expect(described_class.diagnostics("mem.rb", [], program, scope_index)).to eq([])
  end
end
