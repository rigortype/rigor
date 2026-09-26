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

  describe ".may_rebind?" do
    # A call's literal block is one of its children, so the scan reaches every node once: a chain of nested blocks
    # costs its size. Scanning the block through the call and again as a child doubled the work per level, which
    # made a live guard exponential in the nesting depth.
    it "visits each node of a nested block chain at most once" do
      depth = 12
      source = "#{'list.each { ' * depth}puts 1#{' }' * depth}"
      node = call(source)
      size = 0
      counter = lambda do |current|
        size += 1
        current.rigor_each_child { |child| counter.call(child) }
      end
      counter.call(node)
      allow(described_class).to receive(:may_rebind?).and_call_original

      expect(described_class.may_rebind?(node, scope)).to be(false)
      expect(described_class).to have_received(:may_rebind?).at_most(size).times
    end

    it "counts a compound write and a `for` loop whose implicit method may run project code" do
      ["s += s", "list[0] ||= 1", "for x in list do x end"].each do |source|
        expect(described_class.may_rebind?(call(source), scope)).to be(false), source
      end
      # The operator runs on what the reader returns; an element the scope cannot type may be any object.
      expect(described_class.may_rebind?(call("list[0] += 1"), scope)).to be(true)
      expect(described_class.may_rebind?(call("unknown.val += 1"), scope)).to be(true)
      expect(described_class.may_rebind?(call("Object.const_set(:A, 1)"), scope)).to be(true)
    end
  end

  describe "ScanScope.block_parameter_scope" do
    let(:untyped) { Rigor::Type::Combinator.untyped }

    def parameter_scope(source)
      node = call(source)
      [node, described_class::ScanScope.block_parameter_scope(node, node.block, scope)]
    end

    # A plain required parameter reads what the method yields at its position in `requireds`, a destructured one
    # before it included; every other name the list declares reads untyped, so no outer binding shows through.
    it "binds each required parameter by its position and every other parameter name to untyped" do
      _, bound = parameter_scope("[%w[a b]].each_with_object(s) { |(a, b), memo, c = 1, *d, e, f:, g: 2, **h, &i; j| " \
                                 "memo.length }")
      expect(bound.local(:memo)).to eq(string_t)
      %i[a b c d e f g h i j].each { |name| expect(bound.local(name)).to eq(untyped), name.to_s }
    end

    # The bindings change nothing when the body reads no parameter where the scan types it: a bare argument of a
    # statement calling a method on `self` without a block is never typed.
    it "binds nothing when the body reads its parameters only as bare arguments of a self call" do
      node, bound = parameter_scope("list.each { |x, y| puts x; format('%s', y) }")
      expect(bound).to equal(scope)
      ["list.each { |x| x.length }", "list.each { |x| r = x }", "list.each { |x| puts x.length }",
       "list.each { |x| puts(*x) }", "list.each { |x| helper(x) { } }", "list.each { |x| x += 1 }"].each do |source|
        node, bound = parameter_scope(source)
        expect(bound).not_to equal(scope), source
        expect(bound.local(node.block.parameters.parameters.requireds.first.name)).not_to be_nil, source
      end
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
