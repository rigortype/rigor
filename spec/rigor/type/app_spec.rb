# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::App do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:int_nominal) { Rigor::Type::Combinator.nominal_of(Integer) }
  let(:str_nominal) { Rigor::Type::Combinator.nominal_of(String) }

  describe "construction" do
    it "stores uri, args, and bound" do
      app = described_class.new(:"json::value", [str_nominal], bound: untyped)
      expect(app.uri).to eq(:"json::value")
      expect(app.args).to eq([str_nominal])
      expect(app.bound).to eq(untyped)
    end

    it "freezes the args list" do
      app = described_class.new(:"json::value", [str_nominal], bound: untyped)
      expect(app.args).to be_frozen
    end

    it "freezes the carrier itself" do
      app = described_class.new(:"json::value", [str_nominal], bound: untyped)
      expect(app).to be_frozen
    end

    it "rejects non-Symbol uri" do
      expect { described_class.new("json::value", [str_nominal], bound: untyped) }
        .to raise_error(ArgumentError, /uri must be a Symbol/)
    end

    it "rejects unnamespaced uri (no `::`)" do
      expect { described_class.new(:value, [str_nominal], bound: untyped) }
        .to raise_error(ArgumentError, /must be namespaced as/)
    end

    it "rejects non-Array args" do
      expect { described_class.new(:"json::value", str_nominal, bound: untyped) }
        .to raise_error(ArgumentError, /args must be an Array/)
    end

    it "rejects empty args (arity-0 forms use a plain type alias)" do
      expect { described_class.new(:"json::value", [], bound: untyped) }
        .to raise_error(ArgumentError, /args must be non-empty/)
    end

    it "rejects nil bound" do
      expect { described_class.new(:"json::value", [str_nominal], bound: nil) }
        .to raise_error(ArgumentError, /bound must be/)
    end
  end

  describe "describe and erase_to_rbs" do
    it "renders the application in RBS-style `uri[args]` form" do
      app = described_class.new(:"json::value", [str_nominal], bound: untyped)
      expect(app.describe).to eq("json::value[String]")
    end

    it "renders multi-arg applications with comma-separated args" do
      app = described_class.new(:"dry_monads::result", [str_nominal, int_nominal], bound: untyped)
      expect(app.describe).to eq("dry_monads::result[String, Integer]")
    end

    it "erases to the bound (Dynamic[Top] for the default `untyped` bound)" do
      app = described_class.new(:"json::value", [str_nominal], bound: untyped)
      expect(app.erase_to_rbs).to eq(untyped.erase_to_rbs)
    end

    it "erases to a concrete bound when one is registered" do
      app = described_class.new(:"json::value", [str_nominal], bound: int_nominal)
      expect(app.erase_to_rbs).to eq("Integer")
    end
  end

  describe "lattice probes (delegate to bound)" do
    it "tracks the bound's top/bot/dynamic answers" do
      app = described_class.new(:"json::value", [str_nominal], bound: untyped)
      expect(app.top).to eq(untyped.top)
      expect(app.bot).to eq(untyped.bot)
      expect(app.dynamic).to eq(untyped.dynamic)
    end
  end

  describe "structural equality" do
    it "is equal across independent constructions of the same uri/args/bound" do
      a = described_class.new(:"json::value", [str_nominal], bound: untyped)
      b = described_class.new(:"json::value", [str_nominal], bound: untyped)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when the URI differs" do
      a = described_class.new(:"json::value", [str_nominal], bound: untyped)
      b = described_class.new(:"yaml::value", [str_nominal], bound: untyped)
      expect(a).not_to eq(b)
    end

    it "differs when the args differ" do
      a = described_class.new(:"json::value", [str_nominal], bound: untyped)
      b = described_class.new(:"json::value", [int_nominal], bound: untyped)
      expect(a).not_to eq(b)
    end

    it "differs when the bound differs" do
      a = described_class.new(:"json::value", [str_nominal], bound: untyped)
      b = described_class.new(:"json::value", [str_nominal], bound: int_nominal)
      expect(a).not_to eq(b)
    end
  end

  describe "inspect" do
    it "renders the carrier with its describe form and bound" do
      app = described_class.new(:"json::value", [str_nominal], bound: untyped)
      expect(app.inspect).to include("json::value[String]")
      expect(app.inspect).to include("bound=")
    end
  end
end
