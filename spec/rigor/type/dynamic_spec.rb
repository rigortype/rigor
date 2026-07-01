# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Dynamic do
  def nominal_of(name) = Rigor::Type::Combinator.nominal_of(name)

  describe "construction" do
    it "stores the given static facet" do
      facet = nominal_of("String")
      d = described_class.new(facet)
      expect(d.static_facet).to eq(facet)
    end

    it "is frozen" do
      expect(described_class.new(nominal_of("String"))).to be_frozen
    end
  end

  describe "describe" do
    it "wraps the static facet's describe output" do
      d = described_class.new(nominal_of("String"))
      expect(d.describe).to eq("Dynamic[String]")
    end

    it "passes verbosity through to the static facet" do
      d = described_class.new(Rigor::Type::Top.instance)
      expect(d.describe(:short)).to eq("Dynamic[top]")
      expect(d.describe(:long)).to eq("Dynamic[top]")
    end
  end

  describe "erase_to_rbs" do
    it "always erases to untyped, regardless of the static facet" do
      expect(described_class.new(nominal_of("String")).erase_to_rbs).to eq("untyped")
      expect(described_class.new(Rigor::Type::Top.instance).erase_to_rbs).to eq("untyped")
    end
  end

  describe "lattice membership" do
    it "is the dynamic lattice point and nothing else" do
      d = described_class.new(nominal_of("String"))
      expect(d.top).to eq(Rigor::Trinary.no)
      expect(d.bot).to eq(Rigor::Trinary.no)
      expect(d.dynamic).to eq(Rigor::Trinary.yes)
    end
  end

  describe "the untyped alias (Dynamic[top])" do
    it "is Combinator.untyped, a Dynamic wrapping Top" do
      untyped = Rigor::Type::Combinator.untyped
      expect(untyped).to be_a(described_class)
      expect(untyped.static_facet).to eq(Rigor::Type::Top.instance)
      expect(untyped.describe).to eq("Dynamic[top]")
    end

    it "collapses Combinator.dynamic(top) to the untyped instance" do
      expect(Rigor::Type::Combinator.dynamic(Rigor::Type::Top.instance)).to equal(Rigor::Type::Combinator.untyped)
    end
  end

  describe "idempotent collapse (Dynamic[Dynamic[T]] -> Dynamic[T])" do
    it "unwraps a nested Dynamic passed as the static facet via Combinator.dynamic" do
      inner = described_class.new(nominal_of("String"))
      collapsed = Rigor::Type::Combinator.dynamic(inner)
      expect(collapsed).to be_a(described_class)
      expect(collapsed.static_facet).to eq(nominal_of("String"))
    end
  end

  describe "value semantics" do
    it "is equal to another Dynamic with the same static_facet" do
      a = described_class.new(nominal_of("String"))
      b = described_class.new(nominal_of("String"))
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when the static_facet differs" do
      a = described_class.new(nominal_of("String"))
      b = described_class.new(nominal_of("Integer"))
      expect(a).not_to eq(b)
    end

    it "is not equal to a bare Top or Bot lattice extreme" do
      d = described_class.new(Rigor::Type::Top.instance)
      expect(d).not_to eq(Rigor::Type::Top.instance)
      expect(d).not_to eq(Rigor::Type::Bot.instance)
    end
  end

  describe "inspect" do
    it "includes the short describe form" do
      d = described_class.new(nominal_of("String"))
      expect(d.inspect).to eq("#<Rigor::Type::Dynamic Dynamic[String]>")
    end
  end
end
