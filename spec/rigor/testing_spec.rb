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

  # The `sig/rigor/testing.rbs` contract: both helpers are `[A] (…, A value) -> A`, so a probed value
  # keeps its type when the helper's own result is read again. Under the former `-> untyped` return the
  # second read widened to `Dynamic[top]`.
  describe "signature passthrough" do
    def dump_types(source)
      runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
      result = guarded_run_source(runner, source: source, path: "mem.rb")
      result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
    end

    it "carries the argument type through Rigor::Testing.dump_type and Rigor.dump_type" do
      expect(dump_types(<<~RUBY)).to eq(['dump_type: "hello"', 'dump_type: "hello"', "dump_type: 42", "dump_type: 42"])
        require "rigor/testing"
        kept = Rigor::Testing.dump_type("hello")
        Rigor::Testing.dump_type(kept)
        n = Rigor.dump_type(42)
        Rigor.dump_type(n)
      RUBY
    end

    it "carries the argument type through assert_type" do
      expect(dump_types(<<~RUBY)).to eq(['dump_type: "hello"'])
        require "rigor/testing"
        asserted = Rigor::Testing.assert_type('"hello"', "hello")
        Rigor.dump_type(asserted)
      RUBY
    end
  end
end
