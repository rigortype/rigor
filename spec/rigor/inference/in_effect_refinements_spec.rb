# frozen_string_literal: true

require "spec_helper"

# A query and its source, answering at the first occurrence of a marker string.
InEffectRefinementsAtMarker = Struct.new(:refinements, :source) do
  def offset(marker) = source.index(marker) || raise("no #{marker.inspect} in the source")

  def at(marker, declared = Rigor::Inference::InEffectRefinements::EMPTY, &)
    refinements.at(offset(marker), declared, &)
  end
end

# Issue #1673 (ADR-121 WD1) — the ordered in-effect refinements of one file, which the check rules and the typer
# both read.
RSpec.describe Rigor::Inference::InEffectRefinements do
  let(:unknown) { described_class::UNKNOWN }

  # A query over `source` whose `at(marker, …)` answers at the first occurrence of `marker`.
  def query(source)
    InEffectRefinementsAtMarker.new(described_class.new(Prism.parse(source).value), source)
  end

  describe "lexical `using`" do
    it "keeps a re-activated module at its first position, so `using A; using B; using A` leaves B last" do
      refinements = query(<<~RUBY)
        using A
        using B
        using A
        :probe
      RUBY

      expect(refinements.at(":probe")).to eq(%w[A B])
    end

    it "orders two modules refining the same method by textual order" do
      refinements = query(<<~RUBY)
        module First; refine(String) { def shout = 1 }; end
        module Second; refine(String) { def shout = 2 }; end
        using Second
        using First
        :probe
      RUBY

      expect(refinements.at(":probe")).to eq(%w[Second First])
    end

    it "takes effect after the call and ends with the body that holds it" do
      refinements = query(<<~RUBY)
        :before
        class Box
          using Inner
          :inside
        end
        :after
      RUBY

      expect(refinements.at(":before")).to be_empty
      expect(refinements.at(":inside")).to eq(%w[Box::Inner Inner])
      expect(refinements.at(":after")).to be_empty
    end

    it "appends a nested class body's `using`s to the file's list, each spelling's candidates innermost first" do
      refinements = query(<<~RUBY)
        using A
        class Box
          using B
          :inside
        end
        :outside
      RUBY

      expect(refinements.at(":inside")).to eq(%w[A Box::B B])
      expect(refinements.at(":outside")).to eq(%w[A])
    end

    it "ignores a `using` inside a `def`, which raises in Ruby" do
      refinements = query(<<~RUBY)
        def m
          using A
          :inside
        end
        :after
      RUBY

      expect(refinements.at(":inside")).to be_empty
      expect(refinements.at(":after")).to be_empty
    end

    it "puts a `using`'d module's included modules ahead of it through the caller's expansion" do
      refinements = query(<<~RUBY)
        using Base
        using Outer
        :probe
      RUBY
      expansion = { "Outer" => %w[Base Mixin Outer], "Base" => %w[Base] }

      expect(refinements.at(":probe") { |name| expansion.fetch(name) }).to eq(%w[Base Mixin Outer])
    end

    it "contributes the unknown marker where the expansion cannot tell" do
      refinements = query(<<~RUBY)
        using A
        :probe
      RUBY

      expect(refinements.at(":probe") { nil }).to eq([unknown])
    end
  end

  describe "a `refine` block" do
    it "has its own module in effect after the enclosing `using`s" do
      refinements = query(<<~RUBY)
        using A
        module Shout
          refine String do
            :inside
          end
          :beside
        end
      RUBY

      expect(refinements.at(":inside")).to eq(%w[A Shout])
      expect(refinements.at(":beside")).to eq(%w[A])
    end

    it "names the module a `Module.new` constant write creates, and nothing it cannot name" do
      refinements = query(<<~RUBY)
        module Outer
          Named = Module.new do
            refine(String) { :named }
          end
          [1].each do
            refine(String) { :blocked }
          end
        end
      RUBY

      expect(refinements.at(":named")).to eq(%w[Outer::Named])
      expect(refinements.at(":blocked")).to eq([unknown])
    end

    it "records the defs the body defines on the refined class" do
      source = <<~RUBY
        module Shout
          refine(String) { def shout = upcase }
        end
        def shout = 1
      RUBY
      refinements = query(source).refinements
      defs = Prism.parse(source).value.statements.body
      refined = defs.first.body.body.first.block.body.body.first

      # A def node is identified by offset, so a re-parse of the same source answers alike.
      expect(refinements.refinement_def?(refined)).to be(true)
      expect(refinements.refinement_def?(defs.last)).to be(false)
    end
  end

  describe "a non-constant `using`" do
    it "contributes the unknown marker throughout its file" do
      refinements = query(<<~RUBY)
        :before
        using Module.new { refine(String) { def shout = 1 } }
        :after
      RUBY

      expect(refinements.at(":before")).to eq([unknown])
      expect(refinements.at(":after")).to eq([unknown])
    end
  end

  describe "block sources" do
    it "appends a block's declared modules after its lexical list, each once" do
      refinements = query(<<~RUBY)
        using A
        :probe
      RUBY

      expect(refinements.at(":probe", %w[B A C])).to eq(%w[A B C])
    end
  end

  describe "#for_node" do
    it "answers a node of its own file by position and another file's node with no lexical refinement" do
      source = <<~RUBY
        using A
        :probe
      RUBY
      root = Prism.parse(source).value
      refinements = described_class.new(root)
      own = root.statements.body.last
      foreign = Prism.parse(source).value.statements.body.last

      expect(refinements.for_node(own)).to eq(%w[A])
      expect(refinements.for_node(foreign)).to be_empty
      expect(refinements.for_node(foreign, %w[B])).to eq(%w[B])
    end
  end

  describe "the derived check-rule answers" do
    it "keeps the silencing answers broader than the list inside a `refine` block and under the unknown marker" do
      refinements = query(<<~RUBY)
        module Shout
          refine(String) { :inside }
        end
        using Shout
        :after
      RUBY
      inside = refinements.offset(":inside")
      after = refinements.offset(":after")

      query = refinements.refinements
      expect(query.refinement_active?(inside, %w[Unrelated])).to be(true)
      expect(query.refinement_active?(after, %w[Unrelated])).to be(false)
      expect(query.refinement_active?(after, %w[Shout])).to be(true)
      expect(query.any_at?(after)).to be(true)
      expect(query.any_at?(0)).to be(false)
    end
  end

  describe "Scope#in_effect_refinements" do
    it "reads the query the file's index stamps, with each `using` expanded through the file's includes" do
      source = <<~RUBY
        module Mixin
          refine(String) { def shout = 1 }
        end
        module Outer
          include Mixin
          refine(String) { def shout = 2 }
        end
        using Outer
        "x".shout
      RUBY
      root = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)
      call = root.statements.body.last

      expect(index[call].in_effect_refinements(call)).to eq(%w[Mixin Outer])
      expect(Rigor::Scope.empty.in_effect_refinements(call)).to be_empty
    end
  end
end
