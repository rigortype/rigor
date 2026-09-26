# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1429 — where a guard's narrowing of a global or constant stops holding: code that may run project, gem or
# unresolved Ruby code may rebind the global, and core or standard-library code on core values may not.
RSpec.describe Rigor::Inference::GuardRebinding do
  let(:string_t) { Rigor::Type::Combinator.nominal_of("String") }
  let(:nil_t) { Rigor::Type::Combinator.constant_of(nil) }
  let(:scope) do
    Rigor::Scope.empty(environment: Rigor::Environment.default)
                .with_local(:s, string_t).with_local(:list, Rigor::Type::Combinator.nominal_of("Array"))
  end

  # `s` and `list` parse as the locals the scope binds.
  def call(source) = Prism.parse(source, scopes: [%i[s list]]).value.statements.body.last

  describe ".call_may_rebind?" do
    it "keeps a core or standard-library method on a core receiver, and a Kernel method on implicit self" do
      ["s.strip", "s.length", "list.first", "puts s", "format('%s', s)", "File.read(s)", "list.each { puts 1 }",
       "s.frozen?"].each do |source|
        expect(described_class.call_may_rebind?(call(source), scope)).to be(false), source
      end
    end

    it "counts an unresolved callee, a code-running name, a code object, a block argument and a rebinding block" do
      ["helper", "unknown.anything", "s.send(:strip)", "list.each(&blk)", "list.each { $g = nil }",
       "list.each { helper }", "require 'set'", "proc { }.call", "list.each { yield }"].each do |source|
        expect(described_class.call_may_rebind?(call(source), scope)).to be(true), source
      end
    end
  end

  describe ".operands_may_rebind?" do
    it "reads the receiver chain and the arguments" do
      expect(described_class.operands_may_rebind?(call("puts(helper)"), scope)).to be(true)
      expect(described_class.operands_may_rebind?(call("helper.length"), scope)).to be(true)
      expect(described_class.operands_may_rebind?(call("puts(s.strip)"), scope)).to be(false)
    end
  end

  describe ".block_entry" do
    let(:guarded) { scope.with_guarded_global(:$g, string_t, Rigor::Type::Combinator.union(string_t, nil_t)) }

    def block_of(source)
      node = call(source)
      [node.is_a?(Prism::LambdaNode) ? node : node.block, node.is_a?(Prism::CallNode) ? node : nil]
    end

    it "keeps the narrowing in a core iterator's block and restores it in a lambda, a kept block and a helper's" do
      block, owner = block_of("list.each { $g.length }")
      expect(described_class.block_entry(guarded, block, owner).global(:$g)).to eq(string_t)

      ["-> { $g.length }", "proc { $g.length }", "helper { $g.length }", "list.each { helper }"].each do |source|
        block, owner = block_of(source)
        restored = described_class.block_entry(guarded, block, owner)
        expect(restored.global(:$g)).to eq(Rigor::Type::Combinator.union(string_t, nil_t)), source
        expect(restored.guard_narrowed?).to be(false), source
      end
    end
  end
end
