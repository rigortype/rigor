# frozen_string_literal: true

require "rigor/rbs_extended/reporter"

RSpec.describe Rigor::RbsExtended::Reporter do
  subject(:reporter) { described_class.new }

  describe "#record_unresolved / #unresolved_payloads" do
    it "accumulates payload + location pairs in insertion order" do
      reporter.record_unresolved(payload: "rigor:v1:return: bogus", source_location: nil)
      reporter.record_unresolved(payload: "rigor:v1:return: also", source_location: nil)

      payloads = reporter.unresolved_payloads.map(&:payload)
      expect(payloads).to eq(["rigor:v1:return: bogus", "rigor:v1:return: also"])
    end

    it "deduplicates entries by (payload, source_location)" do
      reporter.record_unresolved(payload: "rigor:v1:return: bogus", source_location: nil)
      reporter.record_unresolved(payload: "rigor:v1:return: bogus", source_location: nil)

      expect(reporter.unresolved_payloads.size).to eq(1)
    end

    it "freezes the snapshot returned by the reader" do
      reporter.record_unresolved(payload: "x", source_location: nil)

      expect(reporter.unresolved_payloads).to be_frozen
    end
  end

  describe "#record_lossy_projection / #lossy_projections" do
    it "accumulates (head, location) pairs in insertion order" do
      reporter.record_lossy_projection(head: "pick_of", source_location: nil)
      reporter.record_lossy_projection(head: "omit_of", source_location: nil)

      heads = reporter.lossy_projections.map(&:head)
      expect(heads).to eq(%w[pick_of omit_of])
    end

    it "deduplicates entries by (head, source_location)" do
      reporter.record_lossy_projection(head: "pick_of", source_location: nil)
      reporter.record_lossy_projection(head: "pick_of", source_location: nil)

      expect(reporter.lossy_projections.size).to eq(1)
    end
  end

  describe "#empty?" do
    it "is true on construction" do
      expect(reporter).to be_empty
    end

    it "is false after any event lands" do
      reporter.record_unresolved(payload: "x", source_location: nil)
      expect(reporter).not_to be_empty
    end
  end
end
