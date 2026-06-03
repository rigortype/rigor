# frozen_string_literal: true

require "spec_helper"
require "rigor/testing"

RSpec.describe Rigor::Testing do
  describe ".dump_type" do
    it "returns the value unchanged" do
      expect(described_class.dump_type(42)).to eq(42)
      expect(described_class.dump_type("hello")).to eq("hello")
      expect(described_class.dump_type(nil)).to be_nil
    end
  end

  describe ".assert_type" do
    it "returns the value unchanged regardless of the expected string" do
      expect(described_class.assert_type("Integer", 1)).to eq(1)
      expect(described_class.assert_type("String", "x")).to eq("x")
      expect(described_class.assert_type("nil", nil)).to be_nil
    end
  end

  describe "Rigor convenience delegates" do
    it "Rigor.dump_type delegates to Testing.dump_type and returns the value" do
      expect(Rigor.dump_type(99)).to eq(99)
    end

    it "Rigor.assert_type delegates to Testing.assert_type and returns the value" do
      expect(Rigor.assert_type("Constant[99]", 99)).to eq(99)
    end
  end
end
