# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::AST::TypeNode do
  let(:integer_type) { Rigor::Type::Combinator.nominal_of(Integer) }
  let(:string_const) { Rigor::Type::Combinator.constant_of("hi") }

  describe "construction" do
    it "wraps a Rigor::Type" do
      node = described_class.new(integer_type)
      expect(node.type).to eq(integer_type)
    end

    it "rejects a nil type" do
      expect { described_class.new(nil) }.to raise_error(ArgumentError)
    end

    it "is frozen" do
      expect(described_class.new(integer_type)).to be_frozen
    end

    it "carries the Node marker" do
      expect(described_class.new(integer_type)).to be_a(Rigor::AST::Node)
    end
  end

  describe "structural equality" do
    it "is reflexive across instances with equal types" do
      a = described_class.new(integer_type)
      b = described_class.new(Rigor::Type::Combinator.nominal_of(Integer))
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when wrapped types differ" do
      a = described_class.new(integer_type)
      b = described_class.new(string_const)
      expect(a).not_to eq(b)
    end
  end
end
