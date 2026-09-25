# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1360 — `$!` is the exception the running rescue clause rescued and `$@` its backtrace; past the clause's
# `begin` they are what they were before it.
RSpec.describe Rigor::Inference::ErrorInfo do
  let(:scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }
  let(:error_t) { Rigor::Type::Combinator.nominal_of("StandardError") }
  let(:trace_t) do
    Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")])
  end

  # The binding of `name` at its last read in `source`, through the per-node scope index.
  def last_read(source, name)
    tree = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: scope)
    reads = []
    tree.breadth_first_search do |node|
      reads << node if node.is_a?(Prism::GlobalVariableReadNode) && node.name == name
      false
    end
    index[reads.last].global(name)
  end

  describe ".rescue_entry" do
    it "binds `$!` to the rescued type and `$@` to an `Array[String]`" do
      entered = described_class.rescue_entry(scope, error_t)

      expect(entered.global(:$!)).to eq(error_t)
      expect(entered.global(:$@)).to eq(trace_t)
    end

    it "reads a rescue list's members below `Exception` as themselves, a project class's through its superclass" do
      expect(last_read("begin; x; rescue ArgumentError, TypeError; $!; end", :$!).describe(:short))
        .to eq("ArgumentError | TypeError")
      expect(last_read("class AppError < RuntimeError; end\nbegin; x; rescue AppError; $!; end", :$!))
        .to eq(Rigor::Type::Combinator.nominal_of("AppError"))
    end

    # A module's own `===` lets `rescue` match exceptions that are not its instances, and a class outside `Exception`
    # or one the analyzer cannot place may be such an object too.
    it "reads any other member as `Dynamic[top]`" do
      untyped = Rigor::Type::Combinator.untyped
      expect(last_read("module Any; def self.===(e) = true; end\nbegin; x; rescue Any; $!; end", :$!)).to eq(untyped)
      expect(last_read("class Plain; end\nbegin; x; rescue Plain; $!; end", :$!)).to eq(untyped)
      expect(last_read("begin; x; rescue Unknown::Thing; $!; end", :$!)).to eq(untyped)
      expect(last_read("begin; x; rescue *ERRORS; $!; end", :$!)).to eq(untyped)
      expect(last_read("module Any; def self.===(e) = true; end\nbegin; x; rescue Any, TypeError; $!; end", :$!)
        .describe(:short)).to eq("Dynamic[top] | TypeError")
    end

    # `$@` calls the exception's `backtrace`, which a program may define to return anything.
    it "leaves `$@` unbound, dropping an outer clause's, in a program that defines `backtrace`" do
      source = "class Quiet < StandardError; def backtrace = nil; end\n" \
               "begin; x; rescue; begin; y; rescue Quiet; $@; end; end"
      expect(last_read(source, :$@)).to be_nil
      expect(last_read(source.sub("$@", "$!"), :$!)).to eq(Rigor::Type::Combinator.nominal_of("Quiet"))
      expect(last_read("begin; x; rescue; $@; end", :$@)).to eq(trace_t)

      tree = Prism.parse("class Quiet < StandardError; def backtrace = nil; end\nx").value
      defining = Rigor::Inference::ScopeIndexer.index(tree, default_scope: scope)[tree.statements.body.last]
      entered = described_class.rescue_entry(defining.with_global(:$@, trace_t), error_t)
      expect(entered.global(:$@)).to be_nil
      expect(entered.global(:$!)).to eq(error_t)
    end
  end

  describe ".modifier_entry" do
    it "binds the fallback of a rescue modifier to a rescued `StandardError`" do
      expect(described_class.modifier_entry(scope).global(:$!)).to eq(error_t)
      expect(last_read("y = (x rescue $!)\n$!", :$!)).to be_nil
    end
  end

  describe ".restore" do
    let(:argument_t) { Rigor::Type::Combinator.nominal_of("ArgumentError") }

    it "puts back what the entry binds and drops what it leaves unbound" do
      rescuing = scope.with_global(:$!, error_t).with_global(:$@, trace_t).with_global(:$?, error_t)
      outer = scope.with_global(:$!, argument_t)

      restored = described_class.restore(rescuing, outer)
      expect(restored.global(:$!)).to eq(argument_t)
      expect(restored.global(:$@)).to be_nil
      expect(restored.global(:$?)).to eq(error_t)
      expect(described_class.restore(rescuing, scope).global(:$!)).to be_nil
    end

    it "answers the same scope when it already binds what the entry does" do
      expect(described_class.restore(scope, scope)).to equal(scope)
      bound = scope.with_global(:$!, error_t)
      expect(described_class.restore(bound.with_local(:x, error_t), bound).global(:$!)).to eq(error_t)
    end
  end

  describe ".read_in?" do
    it "answers whether a `$!` or `$@` read sits anywhere in the node" do
      read = ->(source) { described_class.read_in?(Prism.parse(source).value) }

      expect(read.call("log($!.message)")).to be(true)
      expect(read.call("[1].map { $@ }")).to be(true)
      expect(read.call("nil")).to be(false)
      expect(read.call("$? || $_")).to be(false)
      expect(described_class.read_in?(nil)).to be(false)
    end
  end
end
