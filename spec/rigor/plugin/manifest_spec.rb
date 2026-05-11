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

  describe "produces / consumes (ADR-9 slice 4)" do
    it "defaults to empty produces and consumes" do
      m = described_class.new(id: "rails", version: "0.1.0")
      expect(m.produces).to eq([])
      expect(m.consumes).to eq([])
    end

    it "canonicalises produces names to Symbol" do
      m = described_class.new(id: "ar", version: "0.1.0", produces: [:model_index, "schema_table"])
      expect(m.produces).to eq(%i[model_index schema_table])
    end

    it "rejects non-Symbol/String produces entries" do
      expect do
        described_class.new(id: "ar", version: "0.1.0", produces: [123])
      end.to raise_error(ArgumentError, /produces/)
    end

    it "accepts owns_receivers as an Array of class-name Strings (ADR-10 5a)" do
      m = described_class.new(
        id: "ar", version: "0.1.0",
        owns_receivers: ["ActiveRecord::Base", "ApplicationRecord"]
      )
      expect(m.owns_receivers).to eq(%w[ActiveRecord::Base ApplicationRecord])
      expect(m.owns_receivers).to be_frozen
    end

    it "defaults owns_receivers to an empty array" do
      m = described_class.new(id: "ar", version: "0.1.0")
      expect(m.owns_receivers).to eq([])
    end

    it "rejects non-String / empty-String owns_receivers entries" do
      expect do
        described_class.new(id: "ar", version: "0.1.0", owns_receivers: [:Foo])
      end.to raise_error(ArgumentError, /owns_receivers/)
    end

    it "coerces consumes hashes into Consumption value objects" do
      m = described_class.new(
        id: "ap",
        version: "0.1.0",
        consumes: [{ plugin_id: "activerecord", name: :model_index }]
      )
      expect(m.consumes.size).to eq(1)
      cm = m.consumes.first
      expect(cm).to be_a(Rigor::Plugin::Manifest::Consumption)
      expect(cm.plugin_id).to eq("activerecord")
      expect(cm.name).to eq(:model_index)
      expect(cm.optional).to be(false)
    end

    it "honours optional: true on consumes entries" do
      m = described_class.new(
        id: "factorybot",
        version: "0.1.0",
        consumes: [{ plugin_id: "activerecord", name: :model_index, optional: true }]
      )
      expect(m.consumes.first.optional).to be(true)
    end

    it "accepts string keys on consumes entries (YAML round-trip)" do
      m = described_class.new(
        id: "ap",
        version: "0.1.0",
        consumes: [{ "plugin_id" => "ar", "name" => "model_index" }]
      )
      expect(m.consumes.first.plugin_id).to eq("ar")
    end

    it "rejects malformed consumes entries (missing plugin_id or name)" do
      expect do
        described_class.new(id: "ap", version: "0.1.0", consumes: [{ plugin_id: "ar" }])
      end.to raise_error(ArgumentError, /consumes/)
      expect do
        described_class.new(id: "ap", version: "0.1.0", consumes: [{ name: :x }])
      end.to raise_error(ArgumentError, /consumes/)
    end

    it "rejects non-Array consumes" do
      expect do
        described_class.new(id: "ap", version: "0.1.0", consumes: "model_index")
      end.to raise_error(ArgumentError, /consumes/)
    end

    it "round-trips produces / consumes through #to_h" do
      m = described_class.new(
        id: "ap",
        version: "0.1.0",
        produces: [:strong_params_validation],
        consumes: [{ plugin_id: "activerecord", name: :model_index, optional: true }]
      )
      expect(m.to_h["produces"]).to eq(["strong_params_validation"])
      expect(m.to_h["consumes"]).to eq(
        [{ "plugin_id" => "activerecord", "name" => "model_index", "optional" => true }]
      )
    end
  end

  describe "type_node_resolvers (ADR-13 slice 2)" do
    let(:pick_resolver_class) do
      Class.new(Rigor::Plugin::TypeNodeResolver) do
        def self.name = "PickResolver"
      end
    end
    let(:omit_resolver_class) do
      Class.new(Rigor::Plugin::TypeNodeResolver) do
        def self.name = "OmitResolver"
      end
    end

    it "defaults to an empty Array" do
      m = described_class.new(id: "ts", version: "0.1.0")
      expect(m.type_node_resolvers).to eq([])
      expect(m.type_node_resolvers).to be_frozen
    end

    it "stores TypeNodeResolver instances in declaration order" do
      pick = pick_resolver_class.new
      omit = omit_resolver_class.new
      m = described_class.new(
        id: "ts", version: "0.1.0",
        type_node_resolvers: [pick, omit]
      )
      expect(m.type_node_resolvers).to eq([pick, omit])
      expect(m.type_node_resolvers).to be_frozen
    end

    it "rejects non-Array type_node_resolvers" do
      expect do
        described_class.new(id: "ts", version: "0.1.0", type_node_resolvers: pick_resolver_class.new)
      end.to raise_error(ArgumentError, /type_node_resolvers must be an Array/)
    end

    it "rejects entries that are not TypeNodeResolver instances" do
      expect do
        described_class.new(id: "ts", version: "0.1.0", type_node_resolvers: ["not-a-resolver"])
      end.to raise_error(ArgumentError, /TypeNodeResolver instances/)
    end

    it "rejects a bare TypeNodeResolver class (instances required)" do
      expect do
        described_class.new(id: "ts", version: "0.1.0", type_node_resolvers: [pick_resolver_class])
      end.to raise_error(ArgumentError, /TypeNodeResolver instances/)
    end

    it "serialises resolver class names through #to_h" do
      m = described_class.new(
        id: "ts", version: "0.1.0",
        type_node_resolvers: [pick_resolver_class.new, omit_resolver_class.new]
      )
      expect(m.to_h["type_node_resolvers"]).to eq(%w[PickResolver OmitResolver])
    end
  end
end
