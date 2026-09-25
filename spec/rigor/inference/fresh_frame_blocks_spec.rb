# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1361 — a thread's, fiber's or ractor's root block reads a special-variable slot of its own, and a
# `define_method` body reads the definer's slot whenever the method is called, so neither reads the narrowing where
# it is written.
RSpec.describe Rigor::Inference::FreshFrameBlocks do
  let(:scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

  def call(source) = Prism.parse(source).value.statements.body.last

  describe ".root_call?" do
    it "names the core constructors whose block runs as a thread's, fiber's or ractor's root" do
      ["Thread.new { }", "Thread.start { }", "Thread.fork { }", "::Thread.new { }", "Fiber.new { }",
       "::Fiber.new(blocking: true) { }", "Ractor.new { }", "Thread.new(&handler)"].each do |source|
        expect(described_class.root_call?(call(source), scope)).to be(true), source
        expect(described_class.root_call?(call(source))).to be(true), source
      end
    end

    it "does not name another receiver, another method, a call without a block, or `Enumerator.new`" do
      ["MyThread.new { }", "Pool::Thread.new { }", "Thread.current", "Thread.new", "Thread.list.each { }",
       "Fiber.schedule { }", "Enumerator.new { |y| y << 1 }", "Proc.new { }", "thread.new { }"].each do |source|
        expect(described_class.root_call?(call(source), scope)).to be(false), source
      end
    end

    # A project's own `Thread` shares the name, not the frame: `Pool::Thread.new { … }` may run the block right away.
    it "requires the receiver to resolve to the core class where a scope is at hand" do
      source = <<~RUBY
        module Pool
          class Thread
            def self.new = yield
          end

          def self.run = Thread.new { 1 }
        end
      RUBY
      root = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
      node = root.breadth_first_search { |n| n.is_a?(Prism::CallNode) && n.name == :new && !n.block.nil? }

      expect(described_class.root_call?(node, index[node])).to be(false)
      expect(described_class.root_call?(node)).to be(true)
    end
  end

  describe ".root_block" do
    it "answers the root block, a literal or a `&expr` argument, and nil for any other call" do
      literal = call("Thread.new { 1 }")
      argument = call("Fiber.new(&handler)")

      expect(described_class.root_block(literal, scope)).to equal(literal.block)
      expect(described_class.root_block(argument, scope)).to equal(argument.block)
      expect(described_class.root_block(call("items.each { 1 }"), scope)).to be_nil
    end
  end

  describe ".unbound_entry?" do
    it "names a root block and a `define_method` / `define_singleton_method` block on any receiver" do
      ["Thread.new { }", "Fiber.new { }", "define_method(:x) { }", "klass.define_method(:x) { }",
       "obj.define_singleton_method(:x) { }"].each do |source|
        expect(described_class.unbound_entry?(call(source), scope)).to be(true), source
      end
    end

    it "does not name an iterator, `Enumerator.new`, `lambda` or a missing call" do
      ["items.each { }", "Enumerator.new { |y| y << 1 }", "lambda { }", "MyThread.new { }"].each do |source|
        expect(described_class.unbound_entry?(call(source), scope)).to be(false), source
      end
      expect(described_class.unbound_entry?(nil, scope)).to be(false)
    end
  end

  describe ".entry" do
    it "unbinds the match globals" do
      string = Rigor::Type::Combinator.nominal_of("String")
      narrowed = scope.with_global(:$1, string).with_global(:$~, Rigor::Type::Combinator.nominal_of("MatchData"))
      entry = described_class.entry(narrowed)

      expect(entry.global(:$1)).to be_nil
      expect(entry.global(:$~)).to be_nil
      expect(described_class.entry(scope)).to equal(scope)
    end
  end
end
