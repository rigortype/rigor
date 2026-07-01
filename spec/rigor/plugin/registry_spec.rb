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

  describe "ContributionIndex compiled tables reached through Registry (ADR-52 WD1)" do
    let(:gated_plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "gated", version: "0.0.1")

        dynamic_return receivers: ["Result"], methods: %i[unwrap unwrap!] do |_call_node, _scope|
          nil
        end
      end
    end
    let(:type_specifier_plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "specifier", version: "0.0.1")

        narrowing_facts methods: [:assert_kind_of] do |_call_node, _scope|
          nil
        end
      end
    end

    it "compiles per-plugin dynamic_return/type_specifier method-name gates keyed by plugin (.class grouping)" do
      dynamic_plugin = gated_plugin_class.new(services: services)
      specifier_plugin = type_specifier_plugin_class.new(services: services)
      registry = described_class.new(plugins: [dynamic_plugin, specifier_plugin])
      index = registry.contribution_index

      # dynamic_gates: keyed per plugin instance, grouping happens by
      # `p.class.dynamic_returns` — the gate reflects only THIS
      # plugin's declared method names, not the other plugin's.
      expect(index.dynamic_candidate_for?(dynamic_plugin, :unwrap)).to be(true)
      expect(index.dynamic_candidate_for?(dynamic_plugin, :unwrap!)).to be(true)
      expect(index.dynamic_candidate_for?(dynamic_plugin, :assert_kind_of)).to be(false)
      expect(index.dynamic_candidate_for?(specifier_plugin, :unwrap)).to be(false)

      # type_specifier_gates: same per-plugin isolation, on the other rule table.
      expect(index.type_specifier_candidate_for?(specifier_plugin, :assert_kind_of)).to be(true)
      expect(index.type_specifier_candidate_for?(specifier_plugin, :unwrap)).to be(false)
      expect(index.type_specifier_candidate_for?(dynamic_plugin, :assert_kind_of)).to be(false)
    end

    it "unions per-plugin gates into a global dispatch/statement gate (Set#merge across plugins)" do
      unwrap_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "unwrapper", version: "0.0.1")
        dynamic_return receivers: ["Result"], methods: [:unwrap] do |_call_node, _scope|
          nil
        end
      end
      kilometers_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "units", version: "0.0.1")
        dynamic_return methods: [:kilometers] do |_call_node, _scope|
          nil
        end
      end
      registry = described_class.new(
        plugins: [unwrap_class.new(services: services), kilometers_class.new(services: services)]
      )
      index = registry.contribution_index

      # The union gate must include names from BOTH plugins, proving
      # `union_gate` actually merges (not just keeps the last plugin's set).
      expect(index.dispatch_candidate?(:unwrap)).to be(true)
      expect(index.dispatch_candidate?(:kilometers)).to be(true)
      expect(index.dispatch_candidate?(:nonexistent)).to be(false)
    end

    it "raises ArgumentError naming the offending plugin's class for the removed flow_contribution_for hook" do
      legacy_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "legacy-flow", version: "0.0.1")

        def flow_contribution_for(call_node:, scope:) # rubocop:disable Lint/UnusedMethodArgument
          nil
        end
      end
      legacy_plugin = legacy_class.new(services: services)

      expect { described_class.new(plugins: [legacy_plugin]) }.to raise_error(ArgumentError) do |error|
        expect(error.message).to include(legacy_plugin.class.inspect)
        expect(error.message).to include("flow_contribution_for")
        expect(error.message).to include("removed (ADR-52)")
      end
    end

    it "builds the block_as_methods index (#each over entries, #method_names per entry) and #fetch defaults to empty" do
      entry_a = Rigor::Plugin::Macro::BlockAsMethod.new(receiver_constraint: "Sinatra::Base",
                                                        method_names: %i[get post])
      entry_b = Rigor::Plugin::Macro::BlockAsMethod.new(receiver_constraint: "Grape::API", method_names: [:get])
      klass_a = Class.new(Rigor::Plugin::Base) { manifest(id: "a", version: "0.0.1", block_as_methods: [entry_a]) }
      klass_b = Class.new(Rigor::Plugin::Base) { manifest(id: "b", version: "0.0.1", block_as_methods: [entry_b]) }
      registry = described_class.new(plugins: [klass_a.new(services: services), klass_b.new(services: services)])
      index = registry.contribution_index

      # #each over entries + #method_names per entry populate BOTH
      # names for entry_a and the one name for entry_b, in
      # (plugin, declaration) order.
      expect(index.block_entries_for(:get)).to eq([entry_a, entry_b])
      expect(index.block_entries_for(:post)).to eq([entry_a])
      # #fetch's default value kicks in for an unknown key, and the
      # SAME frozen empty array is returned every time (identity).
      expect(index.block_entries_for(:missing)).to eq([])
      expect(index.block_entries_for(:missing)).to be(index.block_entries_for(:never))
    end

    it "resolves owns_receiver? ancestry via Environment#class_ordering" do
      owns_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "owner", version: "0.0.1", owns_receivers: ["ActiveRecord::Relation"])
      end
      registry = described_class.new(plugins: [owns_class.new(services: services)])
      index = registry.contribution_index
      environment = instance_double(Rigor::Environment)
      allow(environment).to receive(:class_ordering).with("Post::Relation", "ActiveRecord::Relation")
                                                    .and_return(:subclass)
      allow(environment).to receive(:class_ordering).with("Unrelated", "ActiveRecord::Relation")
                                                    .and_return(nil)

      expect(index.owns_receiver?("ActiveRecord::Relation", environment)).to be(true) # exact-name fast path
      expect(index.owns_receiver?("Post::Relation", environment)).to be(true) # via class_ordering => :subclass
      expect(index.owns_receiver?("Unrelated", environment)).to be(false) # class_ordering => nil, no match
      expect(environment).to have_received(:class_ordering).with("Post::Relation", "ActiveRecord::Relation").once
    end

    it "tolerates a plugin whose #manifest raises when compiling block_as_methods (manifest_for rescue)" do
      manifest_raising_plugin = plugin_class.new(services: services)
      allow(manifest_raising_plugin).to receive(:manifest).and_raise(NoMethodError, "no manifest")

      registry = described_class.new(plugins: [manifest_raising_plugin])

      expect(registry.contribution_index.block_entries_for(:anything)).to eq([])
    end
  end

  describe "#hkt_overlay_registry (ADR-20 slice 6)" do
    it "returns the shared EMPTY registry when no plugin declares HKT entries" do
      registry = described_class.new(plugins: [plugin_class.new(services: services)])
      expect(registry.hkt_overlay_registry).to be(Rigor::Inference::HktRegistry::EMPTY)
    end

    it "aggregates hkt_registrations and hkt_definitions across plugins into one HktRegistry" do
      registration = Rigor::Inference::HktRegistry::Registration.new(
        uri: :"plugin::box", arity: 1, variance: [:out], bound: Rigor::Type::Combinator.untyped
      )
      definition = Rigor::Inference::HktRegistry.definition_with_body_tree(
        uri: :"plugin::box",
        params: [:K],
        body_tree: Rigor::Inference::HktBody::Param.new(name: :K)
      )
      registration_plugin_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "hkt-reg", version: "0.0.1", hkt_registrations: [registration])
      end
      definition_plugin_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "hkt-def", version: "0.0.1", hkt_definitions: [definition])
      end
      registry = described_class.new(
        plugins: [registration_plugin_class.new(services: services), definition_plugin_class.new(services: services)]
      )

      overlay = registry.hkt_overlay_registry
      expect(overlay).to be_a(Rigor::Inference::HktRegistry)
      expect(overlay).to be_registered(:"plugin::box")
      expect(overlay).to be_defined(:"plugin::box")
      expect(overlay.registration(:"plugin::box")).to eq(registration)
      expect(overlay.definition(:"plugin::box")).to eq(definition)
    end
  end
end
