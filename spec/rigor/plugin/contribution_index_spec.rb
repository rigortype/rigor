# frozen_string_literal: true

require "spec_helper"

# ADR-52 WD1 — the compiled contribution table. These specs pin the
# gate semantics that keep the engine's pruned walks byte-identical to
# the ungated ones: a gate may only return false when every pruned
# consultation would have produced nothing.
RSpec.describe Rigor::Plugin::ContributionIndex do
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end
  let(:plain_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "plain", version: "0.0.1")
    end
  end
  let(:gated_dynamic_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "gated", version: "0.0.1")

      dynamic_return receivers: ["Result"], methods: %i[unwrap unwrap!] do |_call_node, _scope|
        nil
      end
    end
  end
  let(:ungated_dynamic_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "ungated", version: "0.0.1")

      dynamic_return receivers: ["ActiveRecord::Base"] do |_call_node, _scope|
        nil
      end
    end
  end
  let(:type_specifier_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "specifier", version: "0.0.1")

      type_specifier methods: [:assert_kind_of] do |_call_node, _scope|
        nil
      end
    end
  end
  let(:legacy_flow_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "flow", version: "0.0.1")

      def flow_contribution_for(call_node:, scope:) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end
    end
  end

  def build_plugin(klass)
    klass.new(services: services)
  end

  describe "method-name gates" do
    it "gates a fully methods:-gated plugin per name, and globally" do
      plugin = build_plugin(gated_dynamic_class)
      index = described_class.new([plugin])

      expect(index.dynamic_candidate_for?(plugin, :unwrap)).to be(true)
      expect(index.dynamic_candidate_for?(plugin, :each)).to be(false)
      expect(index.dispatch_candidate?(:unwrap)).to be(true)
      expect(index.dispatch_candidate?(:each)).to be(false)
    end

    it "never gates a plugin with a methods:-less rule" do
      plugin = build_plugin(ungated_dynamic_class)
      index = described_class.new([plugin])

      expect(index.dynamic_candidate_for?(plugin, :anything)).to be(true)
      expect(index.dispatch_candidate?(:anything)).to be(true)
    end

    it "disables the global dispatch gate when any plugin is ungated" do
      gated = build_plugin(gated_dynamic_class)
      ungated = build_plugin(ungated_dynamic_class)
      index = described_class.new([gated, ungated])

      # Global: must stay permissive for the ungated plugin's sake…
      expect(index.dispatch_candidate?(:each)).to be(true)
      # …while the per-plugin gate still prunes the gated one.
      expect(index.dynamic_candidate_for?(gated, :each)).to be(false)
      expect(index.dynamic_candidate_for?(ungated, :each)).to be(true)
    end

    it "raises ArgumentError when a Registry is built with a plugin defining flow_contribution_for (removed ADR-52)" do
      legacy = build_plugin(legacy_flow_class)

      expect { Rigor::Plugin::Registry.new(plugins: [legacy]) }
        .to raise_error(ArgumentError, /removed \(ADR-52\)/)
    end

    it "gates the statement path on type_specifier method names" do
      plugin = build_plugin(type_specifier_class)
      index = described_class.new([plugin])

      expect(index.statement_candidate?(:assert_kind_of)).to be(true)
      expect(index.statement_candidate?(:each)).to be(false)
      expect(index.statement_candidate?(nil)).to be(false)
      expect(index.type_specifier_candidate_for?(plugin, :assert_kind_of)).to be(true)
      expect(index.type_specifier_candidate_for?(plugin, :each)).to be(false)
    end

    it "treats a run-time (callable) methods: rule as ungated by name (ADR-52 slice 4)" do
      # A callable methods: set is unknown at registry-build time, so it
      # cannot compile into the name gate — the plugin is consulted on
      # every dispatch and filters in the instance path.
      runtime_methods_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "rtm", version: "0.0.1")
        dynamic_return methods: -> { [:evaluate] } do |_call_node, _scope|
          nil
        end
      end
      plugin = build_plugin(runtime_methods_class)
      index = described_class.new([plugin])

      expect(index.dynamic_candidate_for?(plugin, :evaluate)).to be(true)
      expect(index.dynamic_candidate_for?(plugin, :anything)).to be(true)
      expect(index.dispatch_candidate?(:anything)).to be(true)
    end
  end

  describe "#for_file_diagnostics" do
    it "includes plugins overriding #diagnostics_for_file or declaring a node_rule, and skips the rest" do
      overriding_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "overriding", version: "0.0.1")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          []
        end
      end
      node_rule_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "noder", version: "0.0.1")

        node_rule Prism::CallNode do |_node, _scope, _path|
          []
        end
      end

      overriding = build_plugin(overriding_class)
      noder = build_plugin(node_rule_class)
      plain = build_plugin(plain_class)
      index = described_class.new([plain, overriding, noder])

      expect(index.for_file_diagnostics).to eq([overriding, noder])
    end
  end

  describe "#block_entries_for" do
    it "returns the matching entries in (plugin, declaration) order, and a shared empty array otherwise" do
      entry_a = Rigor::Plugin::Macro::BlockAsMethod.new(receiver_constraint: "Sinatra::Base",
                                                        method_names: %i[get post])
      entry_b = Rigor::Plugin::Macro::BlockAsMethod.new(receiver_constraint: "Grape::API", method_names: [:get])
      klass_a = Class.new(Rigor::Plugin::Base) { manifest(id: "a", version: "0.0.1", block_as_methods: [entry_a]) }
      klass_b = Class.new(Rigor::Plugin::Base) { manifest(id: "b", version: "0.0.1", block_as_methods: [entry_b]) }

      index = described_class.new([build_plugin(klass_a), build_plugin(klass_b)])

      expect(index.block_entries_for(:get)).to eq([entry_a, entry_b])
      expect(index.block_entries_for(:post)).to eq([entry_a])
      expect(index.block_entries_for(:missing)).to eq([])
      expect(index.block_entries_for(:missing)).to be(index.block_entries_for(:never))
    end
  end

  describe "#owns_receiver?" do
    it "is false in O(1) when no plugin declares owns_receivers" do
      index = described_class.new([build_plugin(plain_class)])
      environment = instance_double(Rigor::Environment)

      expect(index.owns_receiver?("Anything", environment)).to be(false)
    end

    it "matches exact names, resolves ancestry through the environment, and memoises the verdict" do
      owns_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "owner", version: "0.0.1", owns_receivers: ["ActiveRecord::Relation"])
      end
      index = described_class.new([build_plugin(owns_class)])
      environment = instance_double(Rigor::Environment)
      allow(environment).to receive(:class_ordering).with("Post::Relation", "ActiveRecord::Relation")
                                                    .and_return(:subclass)

      expect(index.owns_receiver?("ActiveRecord::Relation", environment)).to be(true)
      expect(index.owns_receiver?("Post::Relation", environment)).to be(true)
      expect(index.owns_receiver?("Post::Relation", environment)).to be(true)
      expect(environment).to have_received(:class_ordering).once
    end
  end

  # The `&:symbol` block path dispatches with the BlockArgumentNode
  # itself as `call_node` (`ExpressionTyper#symbol_block_return_type`),
  # so the collector's name gate must tolerate nodes without `#name` —
  # a raise here is silently absorbed upstream and nils the block type
  # (GitLab corpus regression: `select(&:presence)` flipped onto its
  # no-block Enumerator overload).
  describe "dispatcher collection with a non-CallNode (ADR-52 slice-1 regression)" do
    def block_argument_node
      Prism.parse("foo(&:bar)").value.statements.body.first.block
    end

    it "returns no contributions through the global gate instead of raising" do
      registry = Rigor::Plugin::Registry.new(plugins: [build_plugin(gated_dynamic_class)])

      contributions = Rigor::Inference::MethodDispatcher.send(
        :collect_plugin_contributions, registry, block_argument_node, nil, nil
      )
      expect(contributions).to eq([])
    end

    it "walks an ungated plugin without raising" do
      registry = Rigor::Plugin::Registry.new(plugins: [build_plugin(ungated_dynamic_class)])

      contributions = Rigor::Inference::MethodDispatcher.send(
        :collect_plugin_contributions, registry, block_argument_node, nil, nil
      )
      expect(contributions).to eq([])
    end
  end

  describe "registry-level compiled aggregates" do
    it "answers open_receiver? from the compiled set" do
      open_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "opener", version: "0.0.1", open_receivers: ["ActiveRecord::Relation"])
      end
      registry = Rigor::Plugin::Registry.new(plugins: [build_plugin(open_class)])

      expect(registry.open_receiver?("ActiveRecord::Relation")).to be(true)
      expect(registry.open_receiver?("Other")).to be(false)
      expect(registry.open_receiver?(nil)).to be(false)
      expect(registry.open_receivers).to eq(["ActiveRecord::Relation"])
    end

    it "memoises contracts_for_path per path" do
      contract = Rigor::Plugin::ProtocolContract.new(
        path_glob: "app/handlers/**/*.rb", method_name: :call, param_types: [], singleton: false
      )
      contract_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "contractor", version: "0.0.1")
      end
      plugin = build_plugin(contract_class)
      allow(plugin).to receive(:protocol_contracts).and_return([contract])
      registry = Rigor::Plugin::Registry.new(plugins: [plugin])

      first = registry.contracts_for_path("app/handlers/foo.rb")
      expect(first).to eq([contract])
      expect(registry.contracts_for_path("app/handlers/foo.rb")).to be(first)
      expect(registry.contracts_for_path("lib/other.rb")).to eq([])
      expect(registry.contracts_for_path(nil)).to eq([])
    end
  end
end
