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

# ADR-25 — a named plugin class declaring `signature_paths:`, for
# the `Registry#signature_paths` aggregation test (resolution
# needs a named constant).
class RigorPluginRegistrySpecSigPlugin < Rigor::Plugin::Base
  manifest(id: "registry-spec-sig-plugin", version: "0.0.1", signature_paths: ["sig"])
end

# ADR-26 — a named plugin class declaring `open_receivers:`, for
# the `Registry#open_receivers` / `#open_receiver?` tests.
class RigorPluginRegistrySpecOpenPlugin < Rigor::Plugin::Base
  manifest(id: "registry-spec-open-plugin", version: "0.0.1",
           open_receivers: ["ActiveRecord::Relation"])
end

# ADR-28 — a named plugin class declaring `protocol_contracts:`,
# for the `Registry#protocol_contracts` / `#contracts_for_path`
# tests.
class RigorPluginRegistrySpecContractPlugin < Rigor::Plugin::Base
  manifest(
    id: "registry-spec-contract-plugin", version: "0.0.1",
    protocol_contracts: [
      Rigor::Plugin::ProtocolContract.new(
        path_glob: "lib/controller/**/*.rb",
        method_name: :get,
        return_type_name: "Object"
      )
    ]
  )
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

  describe "#signature_paths (ADR-25)" do
    it "is empty when no plugin declares signature_paths" do
      expect(described_class::EMPTY.signature_paths).to eq([])
      registry = described_class.new(plugins: [plugin_class.new(services: services)])
      expect(registry.signature_paths).to eq([])
    end

    it "aggregates declared signature_paths across loaded plugins" do
      sig_plugin = RigorPluginRegistrySpecSigPlugin.new(services: services)
      registry = described_class.new(plugins: [sig_plugin])
      expect(registry.signature_paths).to eq(sig_plugin.signature_paths)
      expect(registry.signature_paths).not_to be_empty
    end
  end

  describe "#open_receivers / #open_receiver? (ADR-26)" do
    it "is empty when no plugin declares open_receivers" do
      expect(described_class::EMPTY.open_receivers).to eq([])
      registry = described_class.new(plugins: [plugin_class.new(services: services)])
      expect(registry.open_receivers).to eq([])
      expect(registry.open_receiver?("ActiveRecord::Relation")).to be(false)
    end

    it "aggregates declared open_receivers and answers the membership predicate" do
      open_plugin = RigorPluginRegistrySpecOpenPlugin.new(services: services)
      registry = described_class.new(plugins: [open_plugin])

      expect(registry.open_receivers).to eq(%w[ActiveRecord::Relation])
      expect(registry.open_receiver?("ActiveRecord::Relation")).to be(true)
      expect(registry.open_receiver?("String")).to be(false)
      expect(registry.open_receiver?(nil)).to be(false)
    end
  end

  describe "#protocol_contracts / #contracts_for_path (ADR-28)" do
    it "is empty when no plugin declares protocol_contracts" do
      expect(described_class::EMPTY.protocol_contracts).to eq([])
      registry = described_class.new(plugins: [plugin_class.new(services: services)])
      expect(registry.protocol_contracts).to eq([])
      expect(registry.contracts_for_path("lib/controller/x.rb")).to eq([])
      expect(registry.contracts_for_path(nil)).to eq([])
    end

    it "aggregates declared protocol_contracts and matches them by path glob" do
      contract_plugin = RigorPluginRegistrySpecContractPlugin.new(services: services)
      registry = described_class.new(plugins: [contract_plugin])

      expect(registry.protocol_contracts.size).to eq(1)

      expect(registry.contracts_for_path("lib/controller/home_controller.rb")).not_to be_empty
      # absolute paths match via the `**/`-prefixed suffix form
      expect(registry.contracts_for_path("/tmp/proj/lib/controller/api/v1_controller.rb")).not_to be_empty
      expect(registry.contracts_for_path("lib/services/widget.rb")).to eq([])
    end
  end

  describe "#additional_initializers (ADR-38)" do
    def build_init_plugin(id, entries, services)
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: id, version: "0.1.0", additional_initializers: entries)
      end
      klass.new(services: services)
    end

    it "is empty when no plugin declares additional_initializers" do
      plugin = plugin_class.new(services: services)
      registry = described_class.new(plugins: [plugin])
      expect(registry.additional_initializers).to eq([])
    end

    it "aggregates entries across plugins in plugin-registration order" do
      a = Rigor::Plugin::AdditionalInitializer.new(receiver_constraint: "Minitest::Test", methods: [:setup])
      b = Rigor::Plugin::AdditionalInitializer.new(receiver_constraint: "RSpec::Core", methods: [:before])
      p1 = build_init_plugin("minitest", [a], services)
      p2 = build_init_plugin("rspec", [b], services)
      registry = described_class.new(plugins: [p1, p2])

      expect(registry.additional_initializers).to eq([a, b])
    end
  end

  describe "#source_rbs_synthesizers (ADR-32 WD4)" do
    let(:synth_plugin_class) do
      synth = ->(_path) { "# synthesised" }
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "synth-spec-plugin", version: "0.0.1", source_rbs_synthesizer: synth)
      end
    end

    it "is empty when no plugin declares source_rbs_synthesizer" do
      expect(described_class::EMPTY.source_rbs_synthesizers).to eq([])
      registry = described_class.new(plugins: [plugin_class.new(services: services)])
      expect(registry.source_rbs_synthesizers).to eq([])
    end

    it "aggregates [plugin, callable] pairs across loaded plugins" do
      plugin = synth_plugin_class.new(services: services)
      registry = described_class.new(plugins: [plugin])

      pairs = registry.source_rbs_synthesizers
      expect(pairs.size).to eq(1)
      expect(pairs.first.first).to be(plugin)
      expect(pairs.first.first.manifest.id).to eq("synth-spec-plugin")
      expect(pairs.first.last).to respond_to(:call)
    end

    it "skips plugins whose manifest carries no synthesizer" do
      mixed = [
        synth_plugin_class.new(services: services),
        plugin_class.new(services: services)
      ]
      registry = described_class.new(plugins: mixed)
      pairs = registry.source_rbs_synthesizers
      expect(pairs.map { |p, _| p.manifest.id }).to eq(["synth-spec-plugin"])
    end
  end
end
