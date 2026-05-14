# frozen_string_literal: true

require "spec_helper"

# A top-level constant so the Blueprint's `Object.const_get` can
# resolve it the same way it will inside a Phase 4 worker Ractor.
class RigorPluginBlueprintSpecPlugin < Rigor::Plugin::Base
  manifest(id: "blueprint-spec", version: "0.1.0")

  def init(_services)
    @init_called = true
  end

  attr_reader :init_called
end

RSpec.describe Rigor::Plugin::Blueprint do
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end

  describe "construction" do
    it "accepts a class name as a String" do
      blueprint = described_class.new(klass_name: "RigorPluginBlueprintSpecPlugin")
      expect(blueprint.klass_name).to eq("RigorPluginBlueprintSpecPlugin")
    end

    it "accepts a class name as a Module and stores the const path" do
      blueprint = described_class.new(klass_name: RigorPluginBlueprintSpecPlugin)
      expect(blueprint.klass_name).to eq("RigorPluginBlueprintSpecPlugin")
    end

    it "rejects non-String / non-Module klass_name" do
      expect { described_class.new(klass_name: :symbol) }
        .to raise_error(ArgumentError, /must be a String or Module/)
    end

    it "deep-copies the config so caller mutations don't bleed through" do
      config = { "factories" => [{ "path" => "spec/factories" }] }
      blueprint = described_class.new(klass_name: "RigorPluginBlueprintSpecPlugin", config: config)
      config["factories"] << { "path" => "other" }
      expect(blueprint.config["factories"].size).to eq(1)
    end
  end

  describe "Ractor.shareable?" do
    it "is frozen" do
      expect(described_class.new(klass_name: "RigorPluginBlueprintSpecPlugin")).to be_frozen
    end

    it "is Ractor.shareable? with an empty config" do
      blueprint = described_class.new(klass_name: "RigorPluginBlueprintSpecPlugin")
      expect(Ractor.shareable?(blueprint)).to be(true)
    end

    it "is Ractor.shareable? with a nested-Hash config" do
      blueprint = described_class.new(
        klass_name: "RigorPluginBlueprintSpecPlugin",
        config: { "factories" => [{ "path" => "spec/factories" }] }
      )
      expect(Ractor.shareable?(blueprint)).to be(true)
    end
  end

  describe "#materialize" do
    it "resolves the class, instantiates, and calls #init(services)" do
      blueprint = described_class.new(klass_name: "RigorPluginBlueprintSpecPlugin")
      plugin = blueprint.materialize(services: services)

      expect(plugin).to be_a(RigorPluginBlueprintSpecPlugin)
      expect(plugin.init_called).to be(true)
      expect(plugin.services).to eq(services)
    end

    it "passes the frozen config through to the plugin instance" do
      blueprint = described_class.new(
        klass_name: "RigorPluginBlueprintSpecPlugin",
        config: { "factories" => ["spec/factories"] }
      )
      plugin = blueprint.materialize(services: services)

      expect(plugin.config["factories"]).to eq(["spec/factories"])
      expect(plugin.config).to be_frozen
    end

    it "produces a NEW instance per call (per-Ractor isolation contract)" do
      blueprint = described_class.new(klass_name: "RigorPluginBlueprintSpecPlugin")
      first = blueprint.materialize(services: services)
      second = blueprint.materialize(services: services)
      expect(first).not_to equal(second)
    end
  end
end
