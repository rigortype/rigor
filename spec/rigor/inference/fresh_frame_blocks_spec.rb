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

  describe ".fresh_entry?" do
    it "names a root block and a `define_method` / `define_singleton_method` block on any receiver" do
      ["Thread.new { }", "Fiber.new { }", "define_method(:x) { }", "klass.define_method(:x) { }",
       "obj.define_singleton_method(:x) { }"].each do |source|
        expect(described_class.fresh_entry?(call(source), scope)).to be(true), source
      end
    end

    it "does not name an iterator, `Enumerator.new`, `lambda` or a missing call" do
      ["items.each { }", "Enumerator.new { |y| y << 1 }", "lambda { }", "MyThread.new { }"].each do |source|
        expect(described_class.fresh_entry?(call(source), scope)).to be(false), source
      end
      expect(described_class.fresh_entry?(nil, scope)).to be(false)
    end
  end

  describe ".entry" do
    let(:narrowed) do
      string = Rigor::Type::Combinator.nominal_of("String")
      scope.with_global(:$1, string).with_global(:$~, Rigor::Type::Combinator.nominal_of("MatchData"))
           .with_global(:$_, string)
    end

    it "unbinds the match globals and `$_` for a root block, which reads a slot of its own" do
      thread = call("Thread.new { }")
      entry = described_class.entry(narrowed, thread)

      expect(entry.global(:$1)).to be_nil
      expect(entry.global(:$~)).to be_nil
      expect(entry.global(:$_)).to be_nil
      expect(described_class.entry(scope, thread)).to equal(scope)
    end

    # A definer body reads the definer's slot whenever the method is called: neither narrowed nor flagged.
    it "reads a narrowed global as `Dynamic[top]` in a definer body, and leaves an unbound one unbound" do
      definer = call("define_singleton_method(:x) { }")
      entry = described_class.entry(narrowed, definer)

      expect(entry.global(:$1)).to eq(Rigor::Type::Combinator.untyped)
      expect(entry.global(:$~)).to eq(Rigor::Type::Combinator.untyped)
      expect(entry.global(:$_)).to eq(Rigor::Type::Combinator.untyped)
      expect(entry.global(:$2)).to be_nil
      expect(described_class.entry(scope, definer)).to equal(scope)
    end

    # Issue #1360 — a root block runs in an execution context of its own: `$!` and `$@` are nil there. `$?` is the
    # thread's, so a thread's or ractor's root block starts without one, while a fiber shares its thread's.
    describe "the rescue and status specials" do
      let(:error) { Rigor::Type::Combinator.nominal_of("StandardError") }
      let(:status) { Rigor::Type::Combinator.nominal_of("Process::Status") }
      let(:rescuing) do
        scope.with_global(:$!, error).with_global(:$@, Rigor::Type::Combinator.nominal_of("Array"))
             .with_global(:$?, status)
      end

      it "unbinds `$!`, `$@` and `$?` for a thread's or ractor's root block" do
        ["Thread.new { }", "Thread.start { }", "Ractor.new { }", "::Thread.fork(&blk)"].each do |source|
          entry = described_class.entry(rescuing, call(source))

          expect([entry.global(:$!), entry.global(:$@), entry.global(:$?)]).to eq([nil, nil, nil]), source
        end
      end

      it "keeps `$?` for a fiber's root block, which shares its thread's" do
        entry = described_class.entry(rescuing, call("Fiber.new { }"))

        expect(entry.global(:$!)).to be_nil
        expect(entry.global(:$?)).to eq(status)
      end

      it "reads each as `Dynamic[top]` in a definer body" do
        entry = described_class.entry(rescuing, call("define_method(:x) { }"))
        untyped = Rigor::Type::Combinator.untyped

        expect([entry.global(:$!), entry.global(:$@), entry.global(:$?)]).to eq([untyped, untyped, untyped])
      end
    end
  end

  # Issue #1360 — a closure's body runs whenever it is called: after the rescue clause it is written in, or on another
  # thread.
  describe ".closure_entry" do
    let(:error) { Rigor::Type::Combinator.nominal_of("StandardError") }
    let(:status) { Rigor::Type::Combinator.nominal_of("Process::Status") }
    let(:rescuing) { scope.with_global(:$!, error).with_global(:$?, status).with_global(:$_, error) }

    it "unbinds `$!`, `$@` and `$?` in a lambda literal's body and a kept block's" do
      lambda_node = call("-> { }")
      expect(described_class.closure_entry(rescuing, lambda_node, nil).global(:$!)).to be_nil
      ["lambda { }", "proc { }", "Proc.new { }", "Kernel.proc { }", "Enumerator.new { }", "Hash.new { }"]
        .each do |source|
          node = call(source)
          entry = described_class.closure_entry(rescuing, node.block, node)

          expect([entry.global(:$!), entry.global(:$?)]).to eq([nil, nil]), source
          expect(entry.global(:$_)).to eq(error), source
        end
    end

    it "leaves an iterator's block, and a block with no owning call, as it is written" do
      ["items.each { }", "obj.lambda { }", "tap { }"].each do |source|
        node = call(source)
        expect(described_class.closure_entry(rescuing, node.block, node)).to equal(rescuing), source
      end
      expect(described_class.closure_entry(rescuing, call("items.each { }").block, nil)).to equal(rescuing)
    end
  end
end
