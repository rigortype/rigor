# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::RigorTesting}: `dump.type` and `assert.type-mismatch` on a parsed snippet and its
# scope index, with no runner.
RSpec.describe Rigor::Analysis::CheckRules::RigorTesting do
  def call_for(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    [program.statements.body.last, scope_index]
  end

  def innermost_call(node, name)
    found = nil
    walk = lambda do |n|
      found = n if n.is_a?(Prism::CallNode) && n.name == name
      n.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(node)
    found
  end

  describe ".dump_diagnostic" do
    it "reports the type of the dumped expression" do
      call, scope_index = call_for("Rigor::Testing.dump_type(1)\n")
      row = described_class.dump_diagnostic("mem.rb", call, scope_index)

      expect(row.rule).to eq(Rigor::Analysis::CheckRules::RULE_DUMP_TYPE)
      expect(row.message).to eq("dump_type: 1")
    end

    it "is silent for another method on the same receiver" do
      call, scope_index = call_for("Rigor::Testing.other(1)\n")

      expect(described_class.dump_diagnostic("mem.rb", call, scope_index)).to be_nil
    end

    it "is silent for a `dump_type` with no argument" do
      call, scope_index = call_for("Rigor::Testing.dump_type\n")

      expect(described_class.dump_diagnostic("mem.rb", call, scope_index)).to be_nil
    end

    it "is silent inside Rigor's own Testing module, where the call is the implementation" do
      source = "module Rigor\n  module Testing\n    def self.go = Testing.dump_type(1)\n  end\nend\n"
      call, scope_index = call_for(source)
      inner = innermost_call(call, :dump_type)

      expect(described_class.dump_diagnostic("mem.rb", inner, scope_index)).to be_nil
    end

    it "is silent for a `dump_type` on an unrelated receiver" do
      call, scope_index = call_for("Elsewhere.dump_type(1)\n")

      expect(described_class.dump_diagnostic("mem.rb", call, scope_index)).to be_nil
    end
  end

  describe ".assert_diagnostic" do
    it "reports a mismatch between the expected string and the inferred type" do
      call, scope_index = call_for(%(Rigor::Testing.assert_type("String", 1)\n))
      row = described_class.assert_diagnostic("mem.rb", call, scope_index)

      expect(row.rule).to eq(Rigor::Analysis::CheckRules::RULE_ASSERT_TYPE)
      expect(row.message).to include(%(expected "String", got "1"))
    end

    it "is silent inside Rigor's own Testing module, where the call is the implementation" do
      source = "module Rigor\n  module Testing\n    def self.go = Testing.assert_type(\"String\", 1)\n  end\nend\n"
      call, scope_index = call_for(source)
      inner = innermost_call(call, :assert_type)

      expect(described_class.assert_diagnostic("mem.rb", inner, scope_index)).to be_nil
    end

    it "is silent for an `assert_type` on an unrelated receiver" do
      call, scope_index = call_for(%(Elsewhere.assert_type("String", 1)\n))

      expect(described_class.assert_diagnostic("mem.rb", call, scope_index)).to be_nil
    end

    it "is silent when the expected string is the inferred type" do
      call, scope_index = call_for(%(Rigor::Testing.assert_type("1", 1)\n))

      expect(described_class.assert_diagnostic("mem.rb", call, scope_index)).to be_nil
    end

    it "is silent when the expected argument is not a string literal" do
      call, scope_index = call_for("Rigor::Testing.assert_type(:sym, 1)\n")

      expect(described_class.assert_diagnostic("mem.rb", call, scope_index)).to be_nil
    end

    it "is silent with fewer than two arguments" do
      call, scope_index = call_for(%(Rigor::Testing.assert_type("1")\n))

      expect(described_class.assert_diagnostic("mem.rb", call, scope_index)).to be_nil
    end
  end
end
