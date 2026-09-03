# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Result do
  let(:int_type) { Rigor::Type::Combinator.nominal_of(Integer) }
  let(:str_type) { Rigor::Type::Combinator.nominal_of(String) }

  describe "construction" do
    it "carries ok_type and err_type" do
      result = described_class.new(int_type, str_type)
      expect(result.ok_type).to eq(int_type)
      expect(result.err_type).to eq(str_type)
      expect(result.success_type).to eq(int_type)
      expect(result.failure_type).to eq(str_type)
    end

    it "rejects nil types" do
      expect { described_class.new(nil, str_type) }.to raise_error(ArgumentError, /ok_type must not be nil/)
      expect { described_class.new(int_type, nil) }.to raise_error(ArgumentError, /err_type must not be nil/)
    end

    it "freezes itself" do
      expect(described_class.new(int_type, str_type)).to be_frozen
    end
  end

  describe "describe and erase_to_rbs" do
    it "describes itself as Result[T, E]" do
      result = described_class.new(int_type, str_type)
      expect(result.describe).to eq("Result[Integer, String]")
    end

    it "erases to Dry::Monads::Result[T, E]" do
      result = described_class.new(int_type, str_type)
      expect(result.erase_to_rbs).to eq("::Dry::Monads::Result[Integer, String]")
    end
  end

  describe "structural equality" do
    it "is equal when ok_type and err_type match" do
      r1 = described_class.new(int_type, str_type)
      r2 = described_class.new(int_type, str_type)
      expect(r1).to eq(r2)
      expect(r1.hash).to eq(r2.hash)
    end

    it "is not equal when ok_type or err_type differs" do
      r1 = described_class.new(int_type, str_type)
      r2 = described_class.new(str_type, int_type)
      expect(r1).not_to eq(r2)
    end
  end

  describe "acceptance / subtyping" do
    it "accepts covariant Results" do
      super_res = described_class.new(Rigor::Type::Combinator.top, Rigor::Type::Combinator.top)
      sub_res = described_class.new(int_type, str_type)
      expect(super_res.accepts(sub_res).yes?).to be true
    end

    it "rejects Results with incompatible type parameters" do
      r1 = described_class.new(int_type, str_type)
      r2 = described_class.new(str_type, str_type)
      expect(r1.accepts(r2).yes?).to be false
    end

    it "accepts compatible Nominal Result" do
      r = described_class.new(int_type, str_type)
      nom = Rigor::Type::Combinator.nominal_of("Dry::Monads::Result", type_args: [int_type, str_type])
      expect(r.accepts(nom).yes?).to be true
    end
  end

  describe "Combinator.result_of" do
    it "constructs a Result carrier" do
      res = Rigor::Type::Combinator.result_of(int_type, str_type)
      expect(res).to be_a(described_class)
      expect(res.ok_type).to eq(int_type)
      expect(res.err_type).to eq(str_type)
    end
  end
end
