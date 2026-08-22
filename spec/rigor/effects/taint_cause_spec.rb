# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Effects::TaintCause do
  # The enum as ADR-103 WD14 fixed it and `docs/type-specification/effect-labels.md` records it.
  # Spelled out here rather than derived, so widening the enum is a deliberate two-file edit.
  let(:enum) do
    %w[
      dynamic-receiver
      dynamic-send
      method-missing
      unresolved-self-call
      unresolved-super
      opaque-callable
      unknown-ownership
      plugin-attribution
      template-not-analysed
      collector-error
      budget
    ]
  end

  it "lists exactly the normative enum" do
    expect(described_class::ALL).to eq(enum)
  end

  it "is frozen, members included" do
    expect(described_class::ALL).to be_frozen
    expect(described_class::ALL).to all(be_frozen)
  end

  describe ".valid?" do
    it "accepts every member" do
      enum.each { |cause| expect(described_class.valid?(cause)).to be(true) }
    end

    it "accepts a symbol spelling of a member" do
      expect(described_class.valid?(:budget)).to be(true)
    end

    it "rejects anything outside the closed enum" do
      # Closed: a new cause is a spec change, not a producer's free choice.
      expect(described_class.valid?("dynamic")).to be(false)
      expect(described_class.valid?("unknown")).to be(false)
      expect(described_class.valid?(nil)).to be(false)
    end
  end
end
