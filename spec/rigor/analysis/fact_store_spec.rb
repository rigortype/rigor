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

  it "records a local-binding fact via with_local_fact" do
    store = described_class.empty.with_local_fact(:x, predicate: :==, payload: literal_a)

    recorded = store.facts_for(target: target_x)
    expect(recorded.size).to eq(1)
    expect(recorded.first).to have_attributes(bucket: :local_binding, predicate: :==, payload: literal_a)
  end

  it "coerces a string bucket name in facts_for" do
    store = described_class.empty.with_fact(fact)
    expect(store.facts_for(bucket: "local_binding")).to eq([fact])
  end

  it "coerces string bucket names in invalidate_target" do
    store = described_class.empty.with_fact(fact)
    expect(store.invalidate_target(target_x, buckets: ["local_binding"])).to be_empty
  end

  it "is value-equal and hash-equal to a store holding the same facts" do
    one = described_class.empty.with_fact(fact)
    two = described_class.empty.with_fact(fact)

    expect(one).to eq(two)
    expect(one).to eql(two)
    expect(one.hash).to eq(two.hash)
    expect(one).not_to eq(described_class.empty)
  end

  describe "input validation" do
    it "rejects an unknown fact bucket" do
      expect do
        described_class::Fact.new(bucket: :bogus, target: target_x, predicate: :==)
      end.to raise_error(ArgumentError)
    end

    it "rejects a non-Fact element at construction" do
      expect { described_class.new(facts: ["not a fact"]) }.to raise_error(ArgumentError)
    end

    it "rejects a join with a non-FactStore argument" do
      expect { described_class.empty.join("not a store") }.to raise_error(ArgumentError)
    end
  end
end
