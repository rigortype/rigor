# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::BudgetTrace do
  before do
    described_class.disable!
    described_class.reset
  end

  after do
    described_class.disable!
    described_class.reset
  end

  describe "when disabled" do
    it "is a no-op so normal runs pay nothing" do
      expect(described_class.enabled?).to be(false)
      described_class.hit(described_class::RECURSION_GUARD)
      expect(described_class.snapshot.values.sum).to eq(0)
    end
  end

  describe "when enabled" do
    before { described_class.enable! }

    it "counts each category independently" do
      described_class.hit(described_class::RECURSION_GUARD)
      described_class.hit(described_class::RECURSION_GUARD)
      described_class.hit(described_class::ANCESTOR_WALK_LIMIT)

      snap = described_class.snapshot
      expect(snap[described_class::RECURSION_GUARD]).to eq(2)
      expect(snap[described_class::ANCESTOR_WALK_LIMIT]).to eq(1)
      expect(snap[described_class::HKT_FUEL_EXHAUSTED]).to eq(0)
    end

    it "zero-fills every known category in the snapshot" do
      expect(described_class.snapshot.keys).to match_array(described_class::CATEGORIES)
    end

    it "returns a frozen snapshot" do
      expect(described_class.snapshot).to be_frozen
    end

    it "reset clears the counters" do
      described_class.hit(described_class::HKT_FUEL_EXHAUSTED)
      described_class.reset
      expect(described_class.snapshot.values.sum).to eq(0)
    end
  end

  describe "integration with the guard sites" do
    before { described_class.enable! }

    it "records an HKT fuel-exhaustion firing" do
      body = Rigor::Inference::HktBody
      registry_class = Rigor::Inference::HktRegistry
      int_nominal = Rigor::Type::Combinator.nominal_of(Integer)
      str_nominal = Rigor::Type::Combinator.nominal_of(String)

      # union::deep[K] = K | K | … (six arms) costs more than fuel=3,
      # so the reducer unwinds to app.bound — the cutoff we count.
      registry = registry_class.new(
        registrations: [registry_class::Registration.new(uri: :"union::deep", arity: 1, variance: [:out],
                                                         bound: int_nominal)],
        definitions: [
          registry_class.definition_with_body_tree(
            uri: :"union::deep", params: [:K],
            body_tree: body::Union.new(arms: Array.new(6) { body::Param.new(name: :K) })
          )
        ]
      )
      app = Rigor::Type::App.new(:"union::deep", [str_nominal], bound: int_nominal)
      registry.reduce(app, fuel: 3)

      expect(described_class.snapshot[described_class::HKT_FUEL_EXHAUSTED]).to be >= 1
    end
  end
end
