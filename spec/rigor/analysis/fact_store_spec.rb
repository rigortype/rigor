# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Analysis::FactStore do
  let(:target_x) { described_class::Target.local(:x) }
  let(:literal_a) { Rigor::Type::Combinator.constant_of("a") }
  let(:fact) do
    described_class::Fact.new(
      bucket: :local_binding,
      target: target_x,
      predicate: :==,
      payload: literal_a,
      polarity: :positive
    )
  end

  it "starts empty and frozen" do
    store = described_class.empty
    expect(store).to be_empty
    expect(store).to be_frozen
  end

  it "adds facts immutably" do
    store = described_class.empty
    next_store = store.with_fact(fact)

    expect(store).to be_empty
    expect(next_store.facts_for(target: target_x)).to eq([fact])
  end

  it "deduplicates structurally equal facts" do
    store = described_class.empty.with_fact(fact).with_fact(fact)
    expect(store.facts).to eq([fact])
  end

  it "invalidates facts that mention a target" do
    store = described_class.empty.with_fact(fact)
    expect(store.invalidate_target(target_x)).to be_empty
  end

  it "joins by retaining only facts present on both edges" do
    other_fact = described_class::Fact.new(
      bucket: :local_binding,
      target: described_class::Target.local(:y),
      predicate: :==,
      payload: Rigor::Type::Combinator.constant_of(1)
    )
    left = described_class.empty.with_fact(fact).with_fact(other_fact)
    right = described_class.empty.with_fact(fact)

    expect(left.join(right).facts).to eq([fact])
  end
end
