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
    it "binds `$!` to the rescued type and `$@` to an `Array[String]`, and unbinds `$?`" do
      status = Rigor::Type::Combinator.nominal_of("Process::Status")
      entered = described_class.rescue_entry(scope.with_global(:$?, status), error_t)

      expect(entered.global(:$!)).to eq(error_t)
      expect(entered.global(:$@)).to eq(trace_t)
      expect(entered.global(:$?)).to be_nil
    end

    # A class guard does not narrow a global receiver yet (#1429): a bound `$!` would report against the guard.
    it "binds neither `$!` nor `$@` for a body that guards `$!` by its class" do
      outer = scope.with_global(:$!, error_t).with_global(:$@, trace_t)
      ["$!.key if $!.is_a?(KeyError)", "$!.kind_of?(KeyError)", "$!.instance_of?(KeyError)",
       "$!.respond_to?(:key)", "KeyError === $!", "case $!\nwhen KeyError then 1\nend",
       "case $!\nin KeyError then 1\nend", "[1].each { next unless $!.is_a?(KeyError) }"].each do |body|
        entered = described_class.rescue_entry(outer, error_t, Prism.parse(body).value)

        expect([entered.global(:$!), entered.global(:$@)]).to eq([nil, nil]), body
      end
    end

    # `rescue => e` binds `e` to the same object as `$!`.
    it "binds neither for a body that guards the clause's reference local" do
      ["$!.key if e.is_a?(KeyError)", "case e\nwhen KeyError then $!.key\nend", "$!.key if KeyError === e"]
        .each do |body|
          entered = described_class.rescue_entry(scope, error_t, Prism.parse("e = nil\n#{body}").value, :e)

          expect(entered.global(:$!)).to be_nil, body
        end
      unrelated = Prism.parse("e = nil\nother = e\nother.is_a?(KeyError)").value
      expect(described_class.rescue_entry(scope, error_t, unrelated, :e).global(:$!)).to eq(error_t)
      guarded = Prism.parse("e = nil\ne.is_a?(KeyError)").value
      expect(described_class.rescue_entry(scope, error_t, guarded).global(:$!)).to eq(error_t)
    end

    it "binds `$!` for a body whose guards are on something else" do
      ["$!.message", "e.is_a?(KeyError)", "$@.is_a?(Array)", "KeyError === e", "case e\nwhen KeyError then 1\nend",
       "$!.class == KeyError"].each do |body|
        entered = described_class.rescue_entry(scope, error_t, Prism.parse(body).value)

        expect(entered.global(:$!)).to eq(error_t), body
      end
    end

    it "leaves `$@` unbound for a body that calls `set_backtrace`, and still binds `$!`" do
      entered = described_class.rescue_entry(scope, error_t, Prism.parse("$!.set_backtrace(nil)").value)

      expect(entered.global(:$@)).to be_nil
      expect(entered.global(:$!)).to eq(error_t)
      expect(described_class.rescue_entry(scope, error_t, Prism.parse("$!.backtrace").value).global(:$@))
        .to eq(trace_t)
    end

    # `rescue` calls `===` to match, and a project class may redefine it to accept anything.
    it "reads a class that it or a project ancestor gives a singleton `===` as `Dynamic[top]`" do
      untyped = Rigor::Type::Combinator.untyped
      expect(last_read("class Matchy < StandardError; def self.===(o) = true; end\n" \
                       "begin; x; rescue Matchy; $!; end", :$!)).to eq(untyped)
      expect(last_read("class Base < StandardError; def self.===(o) = true; end\nclass Leaf < Base; end\n" \
                       "begin; x; rescue Leaf; $!; end", :$!)).to eq(untyped)
      expect(last_read("class Leaf < StandardError; def self.other = 1; end\n" \
                       "begin; x; rescue Leaf; $!; end", :$!)).to eq(Rigor::Type::Combinator.nominal_of("Leaf"))
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

  describe ".defines_case_equality?" do
    it "names a `define_method` or `define_singleton_method` whose literal name is `===`" do
      names = ->(source) { described_class.defines_case_equality?(Prism.parse(source).value.statements.body.last) }

      expect(names.call("define_singleton_method(:===) { true }")).to be(true)
      expect(names.call("singleton_class.define_method('===') { true }")).to be(true)
      expect(names.call("define_singleton_method(:call) { true }")).to be(false)
      expect(names.call("define_singleton_method(name) { true }")).to be(false)
      expect(names.call("foo(:===)")).to be(false)
    end

    it "is gathered for the file, and declines every rescued class there" do
      source = "class M < StandardError; define_singleton_method(:===) { |o| true }; end\n" \
               "begin; x; rescue ArgumentError; $!; end"
      expect(last_read(source, :$!)).to eq(Rigor::Type::Combinator.untyped)
      expect(last_read("begin; x; rescue ArgumentError; $!; end", :$!))
        .to eq(Rigor::Type::Combinator.nominal_of("ArgumentError"))
    end
  end

  describe ".modifier_entry" do
    it "binds the fallback of a rescue modifier to a rescued `StandardError`, unless the fallback guards it" do
      expect(described_class.modifier_entry(scope).global(:$!)).to eq(error_t)
      guard = Prism.parse("$!.is_a?(KeyError) ? $! : nil").value
      expect(described_class.modifier_entry(scope, guard).global(:$!)).to be_nil
      expect(last_read("y = (x rescue $!)\n$!", :$!)).to be_nil
    end
  end

  # The evaluator binds `$!` in a clause it enters; the scope index and the expression typer read a clause or fallback
  # they reach without it with `$!` unbound, never the enclosing clause's.
  describe "an unentered clause" do
    let(:outer) { "begin; raise ArgumentError; rescue ArgumentError\n%s\nend" }

    it "reads `$!` unbound in a modifier's fallback and a value-position `begin`'s clause and `ensure`" do
      ["h.fetch(:a) rescue $!", "warn(begin; x; rescue KeyError; $!; end)", "warn(begin; x; ensure; $!; end)",
       "warn(xs.map do |x| x; rescue KeyError; $! end)"].each do |inner|
        expect(last_read(format(outer, inner), :$!)).to be_nil, inner
      end
      expect(last_read(format(outer, "warn($!)"), :$!)).to eq(Rigor::Type::Combinator.nominal_of("ArgumentError"))
    end

    it "types a value-position `begin`'s clauses, and a clause typed directly, with `$!` unbound" do
      rescuing = scope.with_global(:$!, error_t).with_global(:$?, error_t)
      begin_node = Prism.parse("begin; :ok; rescue KeyError; $!; end").value.statements.body.first

      expect(rescuing.type_of(begin_node).describe(:short)).to eq(":ok | Dynamic[top]")
      expect(rescuing.type_of(begin_node.rescue_clause)).to eq(Rigor::Type::Combinator.untyped)
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
    it "answers whether a `$!`, `$@` or `$?` read sits anywhere in the node" do
      read = ->(source) { described_class.read_in?(Prism.parse(source).value) }

      expect(read.call("log($!.message)")).to be(true)
      expect(read.call("[1].map { $@ }")).to be(true)
      expect(read.call("$?.to_i")).to be(true)
      expect(read.call("nil")).to be(false)
      expect(read.call("$_ || $stdout")).to be(false)
      expect(described_class.read_in?(nil)).to be(false)
    end
  end
end
