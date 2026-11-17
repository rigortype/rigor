# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::UnresolvedToplevel.diagnostic} on a parsed snippet and its scope index, with no
# runner. `runner_check_rules_spec.rb` pins the rule through the whole run.
RSpec.describe Rigor::Analysis::CheckRules::UnresolvedToplevel do
  # `Reflection.instance_method_definition("Object", ...)` in `diagnostic` is a guard no example here isolates: the
  # Kernel methods it admits are also admitted by the `ObjectMixins` and `main`-singleton probes.
  def diagnostic_for(source, name)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    call = find_call(program, name)
    eval_ranges = Rigor::Analysis::CheckRules.send(:receiver_eval_block_ranges, program)
    described_class.diagnostic("mem.rb", call, scope_index, eval_ranges)
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

  it "reports an implicit-self toplevel call that resolves to nothing" do
    row = diagnostic_for("no_such_helper\n", :no_such_helper)

    expect(row.rule).to eq(Rigor::Analysis::CheckRules::RULE_UNRESOLVED_TOPLEVEL)
    expect(row.message).to include("unresolved toplevel call to `no_such_helper`")
  end

  it "is silent for a Kernel method" do
    expect(diagnostic_for("puts 1\n", :puts)).to be_nil
  end

  it "is silent for a toplevel def in the same file" do
    expect(diagnostic_for("def helper = 1\nhelper\n", :helper)).to be_nil
  end

  it "is silent inside a class body, where ADR-24's lenient default holds" do
    expect(diagnostic_for("class Foo\n  no_such_helper\nend\n", :no_such_helper)).to be_nil
  end

  it "is silent for an explicit-receiver call" do
    expect(diagnostic_for("obj.no_such_helper\n", :no_such_helper)).to be_nil
  end

  it "is silent inside a `class_eval` block, which is morally a class body" do
    expect(diagnostic_for("Target.class_eval { no_such_helper }\n", :no_such_helper)).to be_nil
  end

  it "is silent for a method `main` has as a singleton method (`using`)" do
    expect(diagnostic_for("using Foo\n", :using)).to be_nil
  end
end
