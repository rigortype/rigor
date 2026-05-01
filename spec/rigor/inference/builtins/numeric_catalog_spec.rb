# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::Builtins::NumericCatalog do
  describe ".safe_for_folding?" do
    it "approves prelude :leaf-marked methods" do
      # Integer#abs, #even?, #odd? are prelude `Primitive.attr! :leaf`
      # (numeric.rb) and surface as `leaf` in the catalog.
      expect(described_class.safe_for_folding?("Integer", :abs)).to be(true)
      expect(described_class.safe_for_folding?("Integer", :even?)).to be(true)
      expect(described_class.safe_for_folding?("Integer", :odd?)).to be(true)
    end

    it "approves C-body leaf methods promoted by static analysis" do
      # Integer#** -> rb_int_pow (no rb_funcall*; classified `leaf`).
      expect(described_class.safe_for_folding?("Integer", :**)).to be(true)
      # Integer#& / | / ^ / << / >> -> rb_int_and / int_or / rb_int_xor / ...
      expect(described_class.safe_for_folding?("Integer", :&)).to be(true)
      expect(described_class.safe_for_folding?("Integer", :|)).to be(true)
      expect(described_class.safe_for_folding?("Integer", :^)).to be(true)
      expect(described_class.safe_for_folding?("Integer", :<<)).to be(true)
      expect(described_class.safe_for_folding?("Integer", :>>)).to be(true)
    end

    it "approves leaf_when_numeric methods (Integer#+ etc.)" do
      expect(described_class.safe_for_folding?("Integer", :+)).to be(true)
      expect(described_class.safe_for_folding?("Float", :+)).to be(true)
      expect(described_class.safe_for_folding?("Float", :<)).to be(true)
    end

    it "approves prelude trivial methods (literal returns)" do
      expect(described_class.safe_for_folding?("Integer", :integer?)).to be(true)
      expect(described_class.safe_for_folding?("Integer", :to_int)).to be(true)
      expect(described_class.safe_for_folding?("Float", :to_f)).to be(true)
    end

    it "rejects dispatch-classified methods (callout into user Ruby)" do
      # Numeric#abs delegates via `num_funcall0` -> dispatch -> rejected.
      expect(described_class.safe_for_folding?("Numeric", :abs)).to be(false)
      # Numeric#coerce dispatches into user-defined #coerce.
      expect(described_class.safe_for_folding?("Numeric", :coerce)).to be(false)
    end

    it "rejects block-dependent methods" do
      expect(described_class.safe_for_folding?("Integer", :upto)).to be(false)
      expect(described_class.safe_for_folding?("Integer", :downto)).to be(false)
      expect(described_class.safe_for_folding?("Integer", :times)).to be(false)
    end

    it "returns false for an unknown class or selector" do
      expect(described_class.safe_for_folding?("NoSuchClass", :foo)).to be(false)
      expect(described_class.safe_for_folding?("Integer", :no_such_method)).to be(false)
    end

    it "distinguishes singleton from instance methods" do
      # Integer.try_convert is a leaf singleton method.
      expect(described_class.safe_for_folding?("Integer", :try_convert, kind: :singleton)).to be(true)
      # The same selector is not registered as an instance method.
      expect(described_class.safe_for_folding?("Integer", :try_convert, kind: :instance)).to be(false)
    end
  end

  describe ".method_entry" do
    it "returns the full record for a known method" do
      entry = described_class.method_entry("Integer", :abs)
      expect(entry).to be_a(Hash)
      expect(entry["purity"]).to eq("leaf")
      expect(entry["cfunc"]).to eq("rb_int_abs")
    end

    it "returns nil for an unknown method" do
      expect(described_class.method_entry("Integer", :no_such)).to be_nil
    end
  end
end
