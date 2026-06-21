# frozen_string_literal: true

RSpec.describe Rigor::Type::Nominal do
  describe "construction" do
    it "stores the class name with empty type_args by default" do
      n = described_class.new("String")
      expect(n.class_name).to eq("String")
      expect(n.type_args).to eq([])
    end

    it "stores type_args when supplied" do
      arg = Rigor::Type::Combinator.nominal_of("Integer")
      n = described_class.new("Array", [arg])
      expect(n.type_args).to eq([arg])
    end

    it "rejects a non-String class_name" do
      expect { described_class.new(:String) }.to raise_error(ArgumentError, /class_name/)
    end

    it "rejects an empty class_name" do
      expect { described_class.new("") }.to raise_error(ArgumentError, /must not be empty/)
    end

    it "rejects a non-Array type_args" do
      expect { described_class.new("String", :not_array) }.to raise_error(ArgumentError, /type_args/)
    end

    it "freezes the carrier and type_args" do
      n = described_class.new("String")
      expect(n).to be_frozen
      expect(n.type_args).to be_frozen
    end
  end

  describe "describe" do
    it "renders a bare nominal as its class name" do
      expect(described_class.new("String").describe).to eq("String")
    end

    it "renders a generic nominal with type_args" do
      int = described_class.new("Integer")
      arr = described_class.new("Array", [int])
      expect(arr.describe).to eq("Array[Integer]")
    end
  end

  describe "erase_to_rbs" do
    it "erases a bare nominal to its class name" do
      expect(described_class.new("String").erase_to_rbs).to eq("String")
    end

    it "erases a generic nominal including type_args" do
      int = described_class.new("Integer")
      arr = described_class.new("Array", [int])
      expect(arr.erase_to_rbs).to eq("Array[Integer]")
    end
  end

  describe "capability predicates" do
    it "answers top / bot / dynamic as no" do
      n = described_class.new("String")
      expect(n.top).to eq(Rigor::Trinary.no)
      expect(n.bot).to eq(Rigor::Trinary.no)
      expect(n.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "value semantics" do
    it "is equal to another Nominal with the same class_name" do
      a = described_class.new("String")
      b = described_class.new("String")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when type_args differ" do
      int = described_class.new("Integer")
      a = described_class.new("Array", [int])
      b = described_class.new("Array")
      expect(a).not_to eq(b)
    end

    it "differs when class_name differs" do
      expect(described_class.new("String")).not_to eq(described_class.new("Integer"))
    end
  end

  describe "inspect" do
    it "includes the short describe form" do
      expect(described_class.new("String").inspect).to eq("#<Rigor::Type::Nominal String>")
    end
  end
end
