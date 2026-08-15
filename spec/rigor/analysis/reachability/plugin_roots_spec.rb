# frozen_string_literal: true

require "spec_helper"
require "rigor/analysis/reachability/plugin_roots"
require "rigor/analysis/reachability/graph"
require "rigor/analysis/reachability/scan"

# ADR-102 WD3 — the root-contribution protocol. Framework knowledge stays in plugins; the core owns only the
# channel, which is ADR-9's existing fact store rather than a new hook.
#
# Every decline assertion here (a raising plugin contributes nothing, a garbage entry is dropped) is paired
# with a must-still-work case, because a `collect` that always returned `[]` would satisfy the decline half of
# this file on its own.
RSpec.describe Rigor::Analysis::Reachability::PluginRoots do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def configuration_for(*gems)
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("plugins" => gems))
  end

  # Registers `classes` in gem-name order, so `configuration_for("rigor-a", "rigor-b")` loads them.
  def requirer_for(mapping)
    lambda do |name|
      klass = mapping.fetch(name) { raise LoadError, "cannot load such file -- #{name}" }
      Rigor::Plugin.register(klass)
      true
    end
  end

  let(:root_publisher) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "roots-a", version: "0.1.0", produces: [:reachability_roots])

      def prepare(services)
        services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots,
                                    value: ["Admin::UsersController", "::HomeController"])
      end
    end
    stub_const("PluginRootsSpecPublisher", klass)
    klass
  end

  let(:second_publisher) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "roots-b", version: "0.1.0", produces: [:reachability_roots])

      def prepare(services)
        services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots,
                                    value: ["JobsController"])
      end
    end
    stub_const("PluginRootsSpecSecondPublisher", klass)
    klass
  end

  let(:raising_plugin) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "roots-boom", version: "0.1.0", produces: [:reachability_roots])

      def prepare(_services) = raise("routes file is a smoking crater")
    end
    stub_const("PluginRootsSpecRaiser", klass)
    klass
  end

  describe ".collect" do
    it "returns the constant names a plugin published from its prepare hook" do
      roots = described_class.collect(
        configuration: configuration_for("rigor-roots-a"),
        plugin_requirer: requirer_for("rigor-roots-a" => root_publisher)
      )

      expect(roots).to eq(["Admin::UsersController", "HomeController"])
    end

    it "unions the contributions of every publishing plugin" do
      roots = described_class.collect(
        configuration: configuration_for("rigor-roots-a", "rigor-roots-b"),
        plugin_requirer: requirer_for("rigor-roots-a" => root_publisher, "rigor-roots-b" => second_publisher)
      )

      expect(roots).to eq(["Admin::UsersController", "HomeController", "JobsController"])
    end

    # Fail-soft is the invariant: `rigor unused` is a report a human reads, and refusing to print it because
    # one plugin is misconfigured trades a slightly wider candidate list for no output at all.
    it "degrades to the plugin-free root set when the project declares no plugins" do
      expect(described_class.collect(configuration: configuration_for)).to eq([])
    end

    it "degrades when a plugin gem cannot be resolved" do
      roots = described_class.collect(
        configuration: configuration_for("rigor-does-not-exist"),
        plugin_requirer: requirer_for({})
      )

      expect(roots).to eq([])
    end

    # Per-plugin isolation, matching the analysis runner's own prepare pass: the raiser loses ITS facts, not
    # the facts of the plugin beside it.
    it "keeps a healthy plugin's roots when another plugin raises during prepare" do
      roots = described_class.collect(
        configuration: configuration_for("rigor-roots-boom", "rigor-roots-b"),
        plugin_requirer: requirer_for("rigor-roots-boom" => raising_plugin, "rigor-roots-b" => second_publisher)
      )

      expect(roots).to eq(["JobsController"])
    end

    it "drops entries that are not shaped like constant paths, keeping the ones that are" do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "roots-junk", version: "0.1.0", produces: [:reachability_roots])

        def prepare(services)
          services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots,
                                      value: ["app/controllers/users_controller.rb", "users_path", nil,
                                              "RealController"])
        end
      end
      stub_const("PluginRootsSpecJunkPublisher", klass)

      roots = described_class.collect(
        configuration: configuration_for("rigor-roots-junk"),
        plugin_requirer: requirer_for("rigor-roots-junk" => klass)
      )

      expect(roots).to eq(["RealController"])
    end

    it "ignores facts published under other names" do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "roots-other", version: "0.1.0", produces: %i[helper_table reachability_roots])

        def prepare(services)
          services.fact_store.publish(plugin_id: manifest.id, name: :helper_table, value: { "UsersPath" => 1 })
          services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots, value: ["OnlyThis"])
        end
      end
      stub_const("PluginRootsSpecOtherFactPublisher", klass)

      roots = described_class.collect(
        configuration: configuration_for("rigor-roots-other"),
        plugin_requirer: requirer_for("rigor-roots-other" => klass)
      )

      expect(roots).to eq(["OnlyThis"])
    end
  end

  # The point of the protocol, end to end: a declaration nothing in the project references is a candidate
  # until a plugin names it as an entry point.
  describe "consumed by the reachability graph" do
    let(:declarations) do
      result = Rigor::Analysis::Reachability::Scan.call(
        path: "app/controllers/home_controller.rb",
        source: "class HomeController\n  def index = nil\nend\n"
      )
      result.declarations
    end

    it "reports an unreferenced controller as a candidate without plugin roots" do
      report = Rigor::Analysis::Reachability::Graph.new(declarations: declarations, references: []).report

      expect(report.candidates.map(&:fqn)).to eq(["HomeController"])
    end

    it "does not report it once a plugin supplies it as a root" do
      roots = described_class.collect(
        configuration: configuration_for("rigor-roots-a"),
        plugin_requirer: requirer_for("rigor-roots-a" => root_publisher)
      )
      report = Rigor::Analysis::Reachability::Graph.new(declarations: declarations, references: [],
                                                        root_fqns: roots).report

      expect(report.candidates).to be_empty
      expect(report.roots).to eq(1)
    end
  end
end
