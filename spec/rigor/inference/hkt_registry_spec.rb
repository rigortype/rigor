# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::HktRegistry do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:int_nominal) { Rigor::Type::Combinator.nominal_of(Integer) }

  describe Rigor::Inference::HktRegistry::Registration do
    it "stores uri, arity, variance, bound" do
      r = described_class.new(uri: :"json::value", arity: 1, variance: [:out], bound: untyped)
      expect(r.uri).to eq(:"json::value")
      expect(r.arity).to eq(1)
      expect(r.variance).to eq([:out])
      expect(r.bound).to eq(untyped)
    end

    it "freezes the variance list" do
      r = described_class.new(uri: :"json::value", arity: 1, variance: [:out], bound: untyped)
      expect(r.variance).to be_frozen
    end

    it "rejects non-Symbol uri" do
      expect { described_class.new(uri: "json::value", arity: 1, variance: [:out], bound: untyped) }
        .to raise_error(ArgumentError, /uri must be a Symbol/)
    end

    it "rejects un-namespaced uri" do
      expect { described_class.new(uri: :value, arity: 1, variance: [:out], bound: untyped) }
        .to raise_error(ArgumentError, /uri must be namespaced/)
    end

    it "rejects non-positive arity" do
      expect { described_class.new(uri: :"json::value", arity: 0, variance: [], bound: untyped) }
        .to raise_error(ArgumentError, /arity must be a positive Integer/)
    end

    it "rejects variance with wrong arity" do
      expect { described_class.new(uri: :"json::value", arity: 2, variance: [:out], bound: untyped) }
        .to raise_error(ArgumentError, /variance must have 2 entries/)
    end

    it "rejects unknown variance entries" do
      expect { described_class.new(uri: :"json::value", arity: 1, variance: [:weird], bound: untyped) }
        .to raise_error(ArgumentError, /variance entries must be/)
    end

    it "rejects nil bound" do
      expect { described_class.new(uri: :"json::value", arity: 1, variance: [:out], bound: nil) }
        .to raise_error(ArgumentError, /bound must not be nil/)
    end
  end

  describe Rigor::Inference::HktRegistry::Definition do
    it "stores uri, params, body, and optional source attribution" do
      d = described_class.new(
        uri: :"json::value",
        params: [:K],
        body: "nil | bool",
        source_path: "sig/json.rbs",
        source_line: 3
      )
      expect(d.uri).to eq(:"json::value")
      expect(d.params).to eq([:K])
      expect(d.body).to eq("nil | bool")
      expect(d.source_path).to eq("sig/json.rbs")
      expect(d.source_line).to eq(3)
    end

    it "freezes the params list" do
      d = described_class.new(uri: :"json::value", params: [:K], body: "_")
      expect(d.params).to be_frozen
    end

    it "rejects non-Symbol params entries" do
      expect { described_class.new(uri: :"json::value", params: ["K"], body: "_") }
        .to raise_error(ArgumentError, /params entries must be Symbols/)
    end

    it "rejects non-String body" do
      expect { described_class.new(uri: :"json::value", params: [:K], body: :something) }
        .to raise_error(ArgumentError, /body must be a String/)
    end
  end

  describe ".new" do
    it "indexes registrations and definitions by URI" do
      reg = described_class::Registration.new(uri: :"json::value", arity: 1, variance: [:out], bound: untyped)
      defn = described_class::Definition.new(uri: :"json::value", params: [:K], body: "_")

      registry = described_class.new(registrations: [reg], definitions: [defn])
      expect(registry).to be_registered(:"json::value")
      expect(registry).to be_defined(:"json::value")
      expect(registry.registration(:"json::value")).to eq(reg)
      expect(registry.definition(:"json::value")).to eq(defn)
    end

    it "returns nil for unknown URIs" do
      registry = described_class.new
      expect(registry).not_to be_registered(:"json::value")
      expect(registry).not_to be_defined(:"json::value")
      expect(registry.registration(:"json::value")).to be_nil
      expect(registry.definition(:"json::value")).to be_nil
    end

    it "is empty when constructed without arguments" do
      expect(described_class.new).to be_empty
    end

    it "freezes itself" do
      expect(described_class.new).to be_frozen
    end
  end

  describe "#merge" do
    let(:reg_a) { described_class::Registration.new(uri: :"json::value", arity: 1, variance: [:out], bound: untyped) }
    let(:reg_b) do
      described_class::Registration.new(uri: :"json::value", arity: 1, variance: [:out], bound: int_nominal)
    end
    let(:reg_c) { described_class::Registration.new(uri: :"yaml::value", arity: 1, variance: [:out], bound: untyped) }

    it "unions disjoint entries" do
      a = described_class.new(registrations: [reg_a])
      b = described_class.new(registrations: [reg_c])
      merged = a.merge(b)
      expect(merged.registration(:"json::value")).to eq(reg_a)
      expect(merged.registration(:"yaml::value")).to eq(reg_c)
    end

    it "lets the other side win on URI collision (last-write-wins per OQ3 tentative)" do
      a = described_class.new(registrations: [reg_a])
      b = described_class.new(registrations: [reg_b])
      merged = a.merge(b)
      expect(merged.registration(:"json::value")).to eq(reg_b)
    end

    it "rejects merging non-HktRegistry values" do
      expect { described_class.new.merge(:not_a_registry) }
        .to raise_error(ArgumentError, /merge target must be/)
    end
  end

  describe "EMPTY constant" do
    it "is a frozen empty registry" do
      expect(described_class::EMPTY).to be_empty
      expect(described_class::EMPTY).to be_frozen
    end
  end
end
