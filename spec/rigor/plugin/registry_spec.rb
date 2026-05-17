# frozen_string_literal: true

require "spec_helper"

# Top-level constant the `.materialize` tests use as a
# `Blueprint#klass_name`. Defined locally so this spec file is
# self-contained — under `parallel_test` two workers may split
# `blueprint_spec.rb` and `registry_spec.rb` across processes,
# and `registry_spec` previously borrowed
# `RigorPluginBlueprintSpecPlugin` from the blueprint spec
# which left it `NameError`-prone in isolation.
class RigorPluginRegistrySpecPlugin < Rigor::Plugin::Base
  manifest(id: "registry-spec-plugin", version: "0.0.1")
end

RSpec.describe Rigor::Plugin::Registry do
  let(:plugin_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "demo", version: "0.1.0")
    end
  end
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end

  it "is empty by default" do
    registry = described_class.new
    expect(registry).to be_empty
    expect(registry.plugins).to eq([])
    expect(registry.load_errors).to eq([])
    expect(registry).not_to be_any_load_errors
  end

  it "EMPTY constant is shared and frozen" do
    expect(described_class::EMPTY).to be_frozen
    expect(described_class::EMPTY).to be_empty
  end

  it "exposes loaded plugins through #plugins, #ids, and #find" do
    plugin = plugin_class.new(services: services)
    registry = described_class.new(plugins: [plugin])

    expect(registry.plugins).to eq([plugin])
    expect(registry.ids).to eq(["demo"])
    expect(registry.find("demo")).to eq(plugin)
    expect(registry.find(:demo)).to eq(plugin)
    expect(registry.find("missing")).to be_nil
  end

  it "carries load errors with provenance" do
    error = Rigor::Plugin::LoadError.new("boom", plugin_ref: "broken")
    registry = described_class.new(load_errors: [error])

    expect(registry.load_errors).to eq([error])
    expect(registry).to be_any_load_errors
  end

  describe "ADR-15 Phase 3 — blueprints + materialize" do
    it "exposes the supplied blueprints (frozen, Ractor-shareable)" do
      blueprint = Rigor::Plugin::Blueprint.new(klass_name: "RigorPluginRegistrySpecPlugin")
      registry = described_class.new(blueprints: [blueprint])
      expect(registry.blueprints).to eq([blueprint])
      expect(registry.blueprints).to be_frozen
    end

    it ".materialize replays blueprints into a fresh registry" do
      blueprint = Rigor::Plugin::Blueprint.new(klass_name: "RigorPluginRegistrySpecPlugin")
      materialised = described_class.materialize(blueprints: [blueprint], services: services)

      expect(materialised.plugins.size).to eq(1)
      expect(materialised.plugins.first).to be_a(RigorPluginRegistrySpecPlugin)
      expect(materialised.blueprints).to eq([blueprint])
      expect(materialised.load_errors).to eq([])
    end

    it ".materialize produces NEW plugin instances on every call" do
      blueprint = Rigor::Plugin::Blueprint.new(klass_name: "RigorPluginRegistrySpecPlugin")
      first = described_class.materialize(blueprints: [blueprint], services: services)
      second = described_class.materialize(blueprints: [blueprint], services: services)
      expect(first.plugins.first).not_to equal(second.plugins.first)
    end
  end

  describe "#type_node_resolvers (ADR-13 slice 2)" do
    let(:resolver_class) { Class.new(Rigor::Plugin::TypeNodeResolver) }

    def build_plugin(id, resolvers, services)
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: id, version: "0.1.0", type_node_resolvers: resolvers)
      end
      klass.new(services: services)
    end

    it "is empty when no plugin declares resolvers" do
      plugin = plugin_class.new(services: services)
      registry = described_class.new(plugins: [plugin])
      expect(registry.type_node_resolvers).to eq([])
    end

    it "aggregates resolvers across plugins in plugin-registration order" do
      pick = resolver_class.new
      omit = resolver_class.new
      dry  = resolver_class.new
      ts = build_plugin("ts-utilities", [pick, omit], services)
      dry_plugin = build_plugin("dry-types", [dry], services)
      registry = described_class.new(plugins: [ts, dry_plugin])

      expect(registry.type_node_resolvers).to eq([pick, omit, dry])
    end

    it "preserves intra-plugin resolver order" do
      pick = resolver_class.new
      omit = resolver_class.new
      ts = build_plugin("ts-utilities", [pick, omit], services)
      registry = described_class.new(plugins: [ts])
      expect(registry.type_node_resolvers).to eq([pick, omit])
    end
  end
end
