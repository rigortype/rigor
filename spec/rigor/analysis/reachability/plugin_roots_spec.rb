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
      contribution = described_class.collect(
        configuration: configuration_for("rigor-roots-a"),
        plugin_requirer: requirer_for("rigor-roots-a" => root_publisher)
      )

      expect(contribution.roots).to eq(["Admin::UsersController", "HomeController"])
    end

    it "unions the contributions of every publishing plugin" do
      contribution = described_class.collect(
        configuration: configuration_for("rigor-roots-a", "rigor-roots-b"),
        plugin_requirer: requirer_for("rigor-roots-a" => root_publisher, "rigor-roots-b" => second_publisher)
      )

      expect(contribution.roots).to eq(["Admin::UsersController", "HomeController", "JobsController"])
    end

    # Fail-soft is the invariant: `rigor unused` is a report a human reads, and refusing to print it because
    # one plugin is misconfigured trades a slightly wider candidate list for no output at all.
    it "degrades to the plugin-free root set when the project declares no plugins" do
      expect(described_class.collect(configuration: configuration_for)).to be_empty
    end

    it "hands the caller's cache store to the plugins' services, so producers hit their check-time slots" do
      store = instance_double(Rigor::Cache::Store)
      allow(Rigor::Plugin::Services).to receive(:new).and_call_original

      described_class.collect(
        configuration: configuration_for("rigor-roots-a"),
        plugin_requirer: requirer_for("rigor-roots-a" => root_publisher),
        cache_store: store
      )

      expect(Rigor::Plugin::Services).to have_received(:new).with(hash_including(cache_store: store))
    end

    it "degrades when a plugin gem cannot be resolved" do
      contribution = described_class.collect(
        configuration: configuration_for("rigor-does-not-exist"),
        plugin_requirer: requirer_for({})
      )

      expect(contribution).to be_empty
    end

    # Per-plugin isolation, matching the analysis runner's own prepare pass: the raiser loses ITS facts, not
    # the facts of the plugin beside it.
    it "keeps a healthy plugin's roots when another plugin raises during prepare" do
      contribution = described_class.collect(
        configuration: configuration_for("rigor-roots-boom", "rigor-roots-b"),
        plugin_requirer: requirer_for("rigor-roots-boom" => raising_plugin, "rigor-roots-b" => second_publisher)
      )

      expect(contribution.roots).to eq(["JobsController"])
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

      contribution = described_class.collect(
        configuration: configuration_for("rigor-roots-junk"),
        plugin_requirer: requirer_for("rigor-roots-junk" => klass)
      )

      expect(contribution.roots).to eq(["RealController"])
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

      contribution = described_class.collect(
        configuration: configuration_for("rigor-roots-other"),
        plugin_requirer: requirer_for("rigor-roots-other" => klass)
      )

      expect(contribution.roots).to eq(["OnlyThis"])
      expect(contribution.references).to be_empty
    end
  end

  # #350 — the sibling fact. A reference carries its referrer's ROLE, which is the whole reason it is not a
  # root: a plugin that knows a class is named from the test tree must be able to say so without promoting it
  # to production-reachable and erasing ADR-102 WD8's answer.
  describe ".collect — `:reachability_references`" do
    def publisher_of(value, id: "refs-a")
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: id, version: "0.1.0", produces: [:reachability_references])

        define_method(:prepare) do |services|
          services.fact_store.publish(plugin_id: manifest.id, name: :reachability_references, value: value)
        end
      end
      stub_const("PluginRootsSpecReferencePublisher#{id.delete('-')}", klass)
      klass
    end

    def collect_from(klass, gem_name: "rigor-refs-a")
      described_class.collect(
        configuration: configuration_for(gem_name),
        plugin_requirer: requirer_for(gem_name => klass)
      )
    end

    it "returns the name/role pairs a plugin published, and roots nothing" do
      contribution = collect_from(publisher_of([{ name: "Admin::User", role: :test }]))

      expect(contribution.references).to eq([described_class::Reference.new(name: "Admin::User", role: :test)])
      expect(contribution.roots).to be_empty
    end

    it "accepts String keys and values, so a value round-tripped through a cache slot still arrives" do
      contribution = collect_from(publisher_of([{ "name" => "::Widget", "role" => "production" }]))

      expect(contribution.references).to eq([described_class::Reference.new(name: "Widget", role: :production)])
    end

    # Paired decline + must-still-work, so a `collect` that dropped everything could not pass this file.
    it "drops entries with an unrecognised role, a bad name, or the wrong shape, keeping valid ones" do
      contribution = collect_from(publisher_of([{ name: "Kept", role: :test },
                                                { name: "Rejected", role: :ci },
                                                { name: "app/models/user.rb", role: :test },
                                                { name: nil, role: :test },
                                                "NotAHash"]))

      expect(contribution.references).to eq([described_class::Reference.new(name: "Kept", role: :test)])
    end

    it "collects both facts from one plugin-load pass" do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "refs-both", version: "0.1.0", produces: %i[reachability_roots reachability_references])

        def prepare(services)
          services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots, value: ["Rooted"])
          services.fact_store.publish(plugin_id: manifest.id, name: :reachability_references,
                                      value: [{ name: "Referenced", role: :test }])
        end
      end
      stub_const("PluginRootsSpecBothFactsPublisher", klass)

      contribution = collect_from(klass, gem_name: "rigor-refs-both")

      expect(contribution.roots).to eq(["Rooted"])
      expect(contribution.references.map(&:name)).to eq(["Referenced"])
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
      contribution = described_class.collect(
        configuration: configuration_for("rigor-roots-a"),
        plugin_requirer: requirer_for("rigor-roots-a" => root_publisher)
      )
      report = Rigor::Analysis::Reachability::Graph.new(declarations: declarations, references: [],
                                                        root_fqns: contribution.roots).report

      expect(report.candidates).to be_empty
      expect(report.roots).to eq(1)
    end

    # #350, the reference half, and the reason it is a separate fact: the same constant supplied as a
    # `:test`-role reference leaves `candidates` — it IS reached — but lands in `test_only` rather than being
    # promoted to production-reachable the way a root would promote it.
    it "moves a declaration into test_only, not out of the report, when supplied as a test-role reference" do
      reference = Rigor::Analysis::Reachability::Scan::Reference.new(
        as_written: "HomeController", nesting: [].freeze, from: nil, role: :test, path: "(plugin)", line: 1
      )
      report = Rigor::Analysis::Reachability::Graph.new(declarations: declarations,
                                                        references: [reference]).report

      expect(report.candidates).to be_empty
      expect(report.test_only.map(&:fqn)).to eq(["HomeController"])
      expect(report.roots).to eq(0)
    end
  end
end
