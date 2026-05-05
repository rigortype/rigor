# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Manifest do
  describe "construction" do
    it "stores the declared id, version, description, protocols, and config_schema" do
      manifest = described_class.new(
        id: "rails",
        version: "0.1.0",
        description: "Rails support",
        protocols: %i[dynamic_return],
        config_schema: { "eager_load" => :boolean }
      )

      expect(manifest.id).to eq("rails")
      expect(manifest.version).to eq("0.1.0")
      expect(manifest.description).to eq("Rails support")
      expect(manifest.protocols).to eq(%i[dynamic_return])
      expect(manifest.config_schema).to eq({ "eager_load" => :boolean })
    end

    it "freezes the manifest after construction" do
      manifest = described_class.new(id: "rails", version: "0.1.0")
      expect(manifest).to be_frozen
      expect(manifest.protocols).to be_frozen
      expect(manifest.config_schema).to be_frozen
    end

    it "rejects ids that violate the producer-id regex" do
      expect { described_class.new(id: "Rails", version: "0.1.0") }.to raise_error(ArgumentError, /must match/)
      expect { described_class.new(id: "1rails", version: "0.1.0") }.to raise_error(ArgumentError, /must match/)
      expect { described_class.new(id: "", version: "0.1.0") }.to raise_error(ArgumentError, /must match/)
    end

    it "rejects empty or non-string version strings" do
      expect { described_class.new(id: "rails", version: "") }.to raise_error(ArgumentError, /version/)
      expect { described_class.new(id: "rails", version: nil) }.to raise_error(ArgumentError, /version/)
      expect { described_class.new(id: "rails", version: 1.0) }.to raise_error(ArgumentError, /version/)
    end

    it "rejects unknown config_schema value kinds" do
      expect do
        described_class.new(id: "rails", version: "0.1.0", config_schema: { "foo" => :bogus })
      end.to raise_error(ArgumentError, /value kind must be one of/)
    end
  end

  describe "#validate_config" do
    let(:manifest) do
      described_class.new(
        id: "rails",
        version: "0.1.0",
        config_schema: {
          "eager_load" => :boolean,
          "paths" => :array,
          "name" => :string
        }
      )
    end

    it "returns no errors when every key is recognised and well-typed" do
      errors = manifest.validate_config(
        "eager_load" => true,
        "paths" => %w[app lib],
        "name" => "main"
      )
      expect(errors).to be_empty
    end

    it "flags unknown config keys" do
      errors = manifest.validate_config("typo" => true)
      expect(errors).to include(/unknown config key "typo"/)
    end

    it "flags wrong value kinds" do
      errors = manifest.validate_config("eager_load" => "yes")
      expect(errors).to include(/expected boolean/)
    end

    it "rejects non-Hash config" do
      errors = manifest.validate_config([])
      expect(errors).to eq(["plugin config must be a Hash, got Array"])
    end
  end

  describe "equality" do
    it "treats manifests with identical fields as equal" do
      a = described_class.new(id: "rails", version: "0.1.0")
      b = described_class.new(id: "rails", version: "0.1.0")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "treats manifests with different fields as unequal" do
      a = described_class.new(id: "rails", version: "0.1.0")
      b = described_class.new(id: "rails", version: "0.2.0")
      expect(a).not_to eq(b)
    end
  end
end
