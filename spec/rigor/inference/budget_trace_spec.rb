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

  describe "distributions (Slice 2a)" do
    before { described_class.enable! }

    it "is a no-op when disabled" do
      described_class.disable!
      described_class.observe(described_class::UNION_ARITY, 99)
      expect(described_class.distribution(described_class::UNION_ARITY)).to be_empty
    end

    it "accumulates a {value => count} histogram" do
      [3, 3, 5, 12].each { |v| described_class.observe(described_class::UNION_ARITY, v) }
      expect(described_class.distribution(described_class::UNION_ARITY)).to eq({ 3 => 2, 5 => 1, 12 => 1 })
    end

    it "summarises count / max / percentiles / over-thresholds" do
      # 90 unions of arity 2, 9 of arity 12, 1 of arity 50.
      90.times { described_class.observe(described_class::UNION_ARITY, 2) }
      9.times { described_class.observe(described_class::UNION_ARITY, 12) }
      described_class.observe(described_class::UNION_ARITY, 50)

      s = described_class.summarize(described_class::UNION_ARITY, over: [10, 24, 40])
      expect(s[:count]).to eq(100)
      expect(s[:max]).to eq(50)
      expect(s[:percentiles][:p50]).to eq(2)
      expect(s[:percentiles][:p90]).to eq(2)
      expect(s[:percentiles][:p99]).to eq(12)
      expect(s[:over]).to eq({ 10 => 10, 24 => 1, 40 => 1 })
    end

    it "summarises an empty distribution without dividing by zero" do
      s = described_class.summarize(described_class::UNION_ARITY, over: [10])
      expect(s).to eq({ count: 0, max: 0, percentiles: {}, over: { 10 => 0 } })
    end

    it "reset clears distributions too" do
      described_class.observe(described_class::UNION_ARITY, 7)
      described_class.reset
      expect(described_class.distribution(described_class::UNION_ARITY)).to be_empty
    end

    it "is fed by Combinator.union with the produced union's arity" do
      int = Rigor::Type::Combinator.nominal_of(Integer)
      str = Rigor::Type::Combinator.nominal_of(String)
      sym = Rigor::Type::Combinator.nominal_of(Symbol)
      Rigor::Type::Combinator.union(int, str, sym)

      hist = described_class.distribution(described_class::UNION_ARITY)
      expect(hist[3]).to be >= 1
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
