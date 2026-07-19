# frozen_string_literal: true

require "spec_helper"

# ADR-25 — named plugin classes for the signature_paths load-time-validation tests. Defined in this file, so the gem
# root resolves (no `/lib/` segment) to this file's directory; `"."` therefore points at an existing directory and the
# bogus entry at a missing one.
class LoaderSpecSigOkPlugin < Rigor::Plugin::Base
  manifest(id: "sigok", version: "0.1.0", signature_paths: ["."])
end

class LoaderSpecSigMissingPlugin < Rigor::Plugin::Base
  manifest(id: "sigmissing", version: "0.1.0", signature_paths: ["does-not-exist-xyz"])
end

RSpec.describe Rigor::Plugin::Loader do
  let(:configuration) { Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("plugins" => plugins)) }
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: configuration
    )
  end

  let(:plugin_class_a) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "alpha", version: "0.1.0", config_schema: { "flag" => :boolean })
    end
    stub_const("FakeAlphaPlugin", klass)
    klass
  end

  let(:plugin_class_b) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "beta", version: "0.1.0")
    end
    stub_const("FakeBetaPlugin", klass)
    klass
  end

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  describe ".load" do
    let(:plugins) { ["rigor-alpha"] }

    it "requires each gem and instantiates the registered plugin" do
      requirer = lambda { |name|
        raise "unexpected gem #{name}" unless name == "rigor-alpha"

        Rigor::Plugin.register(plugin_class_a)
        true
      }

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.ids).to eq(["alpha"])
      expect(registry.plugins.first).to be_a(plugin_class_a)
      expect(registry.load_errors).to be_empty
    end

    it "skips an entry marked `enabled: false` without requiring or loading it (ADR-93 WD2 opt-out)" do
      requirer = ->(name) { raise "should not require disabled gem #{name}" }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "plugins" => [{ "gem" => "rigor-alpha", "enabled" => false }]
        )
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.plugins).to be_empty
      expect(registry.load_errors).to be_empty
    end

    it "preserves configuration order across multiple plugins" do
      requirer = lambda { |name|
        case name
        when "rigor-beta" then Rigor::Plugin.register(plugin_class_b)
        when "rigor-alpha" then Rigor::Plugin.register(plugin_class_a)
        end
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => %w[rigor-beta rigor-alpha])
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.ids).to eq(%w[beta alpha])
    end

    it "calls #init on every loaded plugin with the service container" do
      captured = []
      tracking_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "tracker", version: "0.1.0")
      end
      tracking_class.define_method(:init) { |svc| captured << svc }
      stub_const("FakeTrackerPlugin", tracking_class)

      requirer = lambda { |_name|
        Rigor::Plugin.register(tracking_class)
        true
      }

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => ["rigor-tracker"])
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration
      )

      described_class.load(configuration: configuration, services: services, requirer: requirer)
      expect(captured).to eq([services])
    end

    it "passes user config into the plugin instance after schema validation" do
      requirer = lambda { |_name|
        Rigor::Plugin.register(plugin_class_a)
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "plugins" => [{ "gem" => "rigor-alpha", "config" => { "flag" => true } }]
        )
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.load_errors).to be_empty
      expect(registry.plugins.first.config).to eq({ "flag" => true })
    end

    it "surfaces gem-load failures as load errors instead of raising" do
      requirer = ->(_name) { raise LoadError, "cannot load such file -- rigor-alpha" }

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.plugins).to be_empty
      expect(registry.load_errors.size).to eq(1)
      expect(registry.load_errors.first.message).to include('could not load plugin gem "rigor-alpha"')
    end

    it "surfaces missing-registration failures as load errors" do
      requirer = ->(_name) { true }

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.plugins).to be_empty
      expect(registry.load_errors.first.message).to include("did not register any plugin")
    end

    it "surfaces multi-registration ambiguity as a load error" do
      requirer = lambda { |_name|
        Rigor::Plugin.register(plugin_class_a)
        Rigor::Plugin.register(plugin_class_b)
        true
      }

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.plugins).to be_empty
      # The error must be actionable: name the meta-gem nature and how to list the individual plugins (the onboarding
      # field-trial trap).
      message = registry.load_errors.first.message
      expect(message).to include("convenience meta-gem")
      expect(message).to match(/list the individual plugin gems/i)
      expect(message).to include("`id:`")
    end

    it "resolves an explicit `id:` even when the gem registers multiple plugins" do
      requirer = lambda { |_name|
        Rigor::Plugin.register(plugin_class_a)
        Rigor::Plugin.register(plugin_class_b)
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "plugins" => [{ "gem" => "rigor-pair", "id" => "alpha" }]
        )
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)
      expect(registry.ids).to eq(["alpha"])
    end

    it "rejects duplicate plugin ids in the configuration" do
      requirer = lambda { |_name|
        Rigor::Plugin.register(plugin_class_a)
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "plugins" => ["rigor-alpha", { "gem" => "rigor-alpha-again", "id" => "alpha" }]
        )
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)
      expect(registry.plugins.size).to eq(1)
      expect(registry.load_errors.first.message).to include("appeared twice")
    end

    it "surfaces config schema violations as load errors" do
      requirer = lambda { |_name|
        Rigor::Plugin.register(plugin_class_a)
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "plugins" => [{ "gem" => "rigor-alpha", "config" => { "flag" => "not-a-bool" } }]
        )
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)
      expect(registry.plugins).to be_empty
      expect(registry.load_errors.first.message).to include("expected boolean")
    end

    it "surfaces #init exceptions as load errors without crashing the loader" do
      bomb_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "bomb", version: "0.1.0")
      end
      bomb_class.define_method(:init) { |_| raise "kaboom" }
      stub_const("FakeBombPlugin", bomb_class)

      requirer = lambda { |_name|
        Rigor::Plugin.register(bomb_class)
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => ["rigor-bomb"])
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)
      expect(registry.plugins).to be_empty
      expect(registry.load_errors.first.message).to match(/raised during init.*kaboom/)
    end
  end

  describe ".load with empty configuration" do
    let(:plugins) { [] }

    it "returns an empty registry without invoking the requirer" do
      requirer = ->(name) { raise "should not be called: #{name}" }

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)
      expect(registry).to be_empty
    end
  end

  describe "topological sort + missing-producer (ADR-9 slice 5)" do
    let(:producer_class) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "activerecord", version: "0.1.0", produces: [:model_index])
      end
      stub_const("FakeActiverecordPlugin", klass)
      klass
    end

    let(:consumer_class) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(
          id: "actionpack",
          version: "0.1.0",
          consumes: [{ plugin_id: "activerecord", name: :model_index }]
        )
      end
      stub_const("FakeActionpackPlugin", klass)
      klass
    end

    let(:plugins) { %w[rigor-actionpack rigor-activerecord] }

    def consumer_first_requirer
      # #194 slice 2 — `rigor-actionpack` / `rigor-activerecord` are both bundled plugins, so the loader now
      # hands the requirer their engine-anchored absolute paths, not the bare gem names. `File.basename(…,
      # ".rb")` recovers the gem name from either form (a bare name is returned unchanged), modelling
      # `Kernel.require`, which accepts name-or-path alike.
      lambda { |arg|
        case File.basename(arg, ".rb")
        when "rigor-actionpack" then Rigor::Plugin.register(consumer_class)
        when "rigor-activerecord" then Rigor::Plugin.register(producer_class)
        end
        true
      }
    end

    it "orders the producer before the consumer regardless of configuration order" do
      registry = described_class.load(
        configuration: configuration, services: services, requirer: consumer_first_requirer
      )

      expect(registry.ids).to eq(%w[activerecord actionpack])
      expect(registry.load_errors).to be_empty
    end

    it "emits :missing-producer when a non-optional consume has no matching producer" do
      requirer = lambda { |_name|
        Rigor::Plugin.register(consumer_class)
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => ["rigor-actionpack"])
      )

      registry = described_class.load(
        configuration: configuration, services: services, requirer: requirer
      )

      expect(registry.plugins).to be_empty
      err = registry.load_errors.first
      expect(err.reason).to eq(:"missing-producer")
      expect(err.plugin_ref).to eq("actionpack")
      expect(err.message).to include("activerecord")
      expect(err.message).to include("model_index")
    end

    it "skips :missing-producer validation for optional consumes" do
      optional_consumer = Class.new(Rigor::Plugin::Base) do
        manifest(
          id: "factorybot",
          version: "0.1.0",
          consumes: [{ plugin_id: "activerecord", name: :model_index, optional: true }]
        )
      end
      stub_const("FakeFactoryBotPlugin", optional_consumer)
      requirer = lambda { |_name|
        Rigor::Plugin.register(optional_consumer)
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => ["rigor-factorybot"])
      )

      registry = described_class.load(
        configuration: configuration, services: services, requirer: requirer
      )

      expect(registry.ids).to eq(["factorybot"])
      expect(registry.load_errors).to be_empty
    end

    it "emits :dependency-cycle when consumes form a cycle" do # rubocop:disable RSpec/ExampleLength
      cycle_a = Class.new(Rigor::Plugin::Base) do
        manifest(
          id: "cycle-a", version: "0.1.0",
          produces: [:fact_a],
          consumes: [{ plugin_id: "cycle-b", name: :fact_b }]
        )
      end
      cycle_b = Class.new(Rigor::Plugin::Base) do
        manifest(
          id: "cycle-b", version: "0.1.0",
          produces: [:fact_b],
          consumes: [{ plugin_id: "cycle-a", name: :fact_a }]
        )
      end
      stub_const("FakeCycleAPlugin", cycle_a)
      stub_const("FakeCycleBPlugin", cycle_b)
      requirer = lambda { |name|
        case name
        when "rigor-cycle-a" then Rigor::Plugin.register(cycle_a)
        when "rigor-cycle-b" then Rigor::Plugin.register(cycle_b)
        end
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => %w[rigor-cycle-a rigor-cycle-b])
      )

      registry = described_class.load(
        configuration: configuration, services: services, requirer: requirer
      )

      err = registry.load_errors.find { |e| e.reason == :"dependency-cycle" }
      expect(err).not_to be_nil
      expect(err.message).to include("cycle-a")
      expect(err.message).to include("cycle-b")
    end
  end

  describe "signature_paths validation (ADR-25)" do
    it "loads a plugin whose declared signature path exists" do
      requirer = lambda { |name|
        Rigor::Plugin.register(LoaderSpecSigOkPlugin) if name == "rigor-sigok"
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => ["rigor-sigok"])
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection, type: Rigor::Type::Combinator, configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.ids).to eq(["sigok"])
      expect(registry.load_errors).to be_empty
      expect(registry.signature_paths).to eq([File.expand_path(".", __dir__)])
    end

    it "drops a plugin whose declared signature path is missing, with a LoadError" do
      requirer = lambda { |name|
        Rigor::Plugin.register(LoaderSpecSigMissingPlugin) if name == "rigor-sigmissing"
        true
      }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => ["rigor-sigmissing"])
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection, type: Rigor::Type::Combinator, configuration: configuration
      )

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.plugins).to be_empty
      expect(registry.load_errors.map(&:message)).to include(/signature path .* not a directory/)
    end
  end

  # #194 slice 1 — the loader pins the file each successfully-required gem loaded from (via the injectable
  # `feature_resolver` seam, so these specs never touch the real `$LOADED_FEATURES`) and threads it onto the
  # registry / the surfaced LoadError, so an engine↔plugin version skew is diagnosable at a glance.
  describe "resolved plugin file paths (#194 slice 1)" do
    let(:plugins) { ["rigor-alpha"] }

    def register_alpha_requirer
      lambda { |_name|
        Rigor::Plugin.register(plugin_class_a)
        true
      }
    end

    it "records the file the gem require resolved to, keyed by gem name" do
      resolver = ->(gem) { "/fake/gems/#{gem}/lib/#{gem}.rb" }

      registry = described_class.load(
        configuration: configuration, services: services,
        requirer: register_alpha_requirer, feature_resolver: resolver
      )

      expect(registry.ids).to eq(["alpha"])
      expect(registry.resolved_gem_paths).to eq("rigor-alpha" => "/fake/gems/rigor-alpha/lib/rigor-alpha.rb")
    end

    it "degrades to a nil path when the resolver cannot pin the file, without failing the load" do
      resolver = ->(_gem) {}

      registry = described_class.load(
        configuration: configuration, services: services,
        requirer: register_alpha_requirer, feature_resolver: resolver
      )

      expect(registry.ids).to eq(["alpha"])
      expect(registry.load_errors).to be_empty
      expect(registry.resolved_gem_paths).to have_key("rigor-alpha")
      expect(registry.resolved_gem_paths.fetch("rigor-alpha")).to be_nil
    end

    it "stamps the resolved path on a post-require failure so the diagnostic can name the loaded copy" do
      bomb_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "bomb", version: "0.1.0")
      end
      bomb_class.define_method(:init) { |_| raise "kaboom" }
      stub_const("FakeBombPathPlugin", bomb_class)
      requirer = lambda { |_name|
        Rigor::Plugin.register(bomb_class)
        true
      }
      resolver = ->(gem) { "/checkout/plugins/#{gem}/lib/#{gem}.rb" }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("plugins" => ["rigor-bomb"])
      )
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection, type: Rigor::Type::Combinator, configuration: configuration
      )

      registry = described_class.load(
        configuration: configuration, services: services, requirer: requirer, feature_resolver: resolver
      )

      error = registry.load_errors.first
      expect(error.message).to include("raised during init")
      expect(error.resolved_path).to eq("/checkout/plugins/rigor-bomb/lib/rigor-bomb.rb")
    end

    it "leaves resolved_path nil on a require that failed outright — there is no file to name" do
      requirer = ->(_name) { raise LoadError, "cannot load such file -- rigor-alpha" }
      # A resolver that WOULD hand back a path is never consulted, because the require never succeeded.
      resolver = ->(gem) { "/should/not/be/used/#{gem}.rb" }

      registry = described_class.load(
        configuration: configuration, services: services, requirer: requirer, feature_resolver: resolver
      )

      error = registry.load_errors.first
      expect(error.message).to include('could not load plugin gem "rigor-alpha"')
      expect(error.resolved_path).to be_nil
      expect(registry.resolved_gem_paths).to be_empty
    end
  end

  # #194 slice 2 (ADR-93 WD5) — a `plugins:` entry naming a plugin the engine itself bundles is required BY
  # ITS ENGINE-ANCHORED ABSOLUTE PATH, never by gem name, so a stale installed `rigortype` gem can never
  # displace the engine's own versioned copy through RubyGems name resolution. Every other gem keeps today's
  # bare-name require. WD5 records the spec-level requirer-argument proof as the acceptance: reproducing the
  # real stale-gem skew is out of proportion and no-ops under Bundler (`Gem.paths` manipulation is inert).
  describe ".bundled_plugin_path" do
    # `rigor-rbs-inline` is the WD5-central bundled plugin (the ADR-93 auto-wire default); any bundled gem
    # would do. The expected path is derived the same way the loader derives it, so the assertion holds
    # wherever the checkout lives.
    let(:bundled_gem) { "rigor-rbs-inline" }
    let(:anchored) { File.join(described_class::ENGINE_ROOT, "plugins", bundled_gem, "lib", "#{bundled_gem}.rb") }

    it "returns the engine-anchored absolute path of a plugin the engine bundles" do
      expect(described_class.bundled_plugin_path(bundled_gem)).to eq(anchored)
      expect(File.file?(described_class.bundled_plugin_path(bundled_gem))).to be(true)
    end

    it "returns nil for a gem the engine does not bundle (a third-party / project-bundle plugin)" do
      expect(described_class.bundled_plugin_path("rigor-nonexistent-xyz")).to be_nil
    end
  end

  describe "engine-anchored bundled-plugin resolution (#194 slice 2)" do
    let(:bundled_gem) { "rigor-rbs-inline" }
    let(:anchored) { File.join(described_class::ENGINE_ROOT, "plugins", bundled_gem, "lib", "#{bundled_gem}.rb") }

    def config_for(plugins)
      Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("plugins" => plugins))
    end

    def services_for(configuration)
      Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection, type: Rigor::Type::Combinator, configuration: configuration
      )
    end

    def capturing_requirer(sink)
      lambda { |arg|
        sink << arg
        Rigor::Plugin.register(plugin_class_a)
        true
      }
    end

    # (a) A bundled-name entry hands the requirer the anchored ABSOLUTE PATH, not the gem name.
    it "requires a bundled plugin by its engine-anchored absolute path" do
      received = []
      configuration = config_for([bundled_gem])

      registry = described_class.load(
        configuration: configuration, services: services_for(configuration),
        requirer: capturing_requirer(received)
      )

      expect(received).to eq([anchored])
      expect(registry.load_errors).to be_empty
    end

    # (b) A gem the engine does not bundle keeps today's bare-name require, unchanged.
    it "requires a non-bundled gem by its bare name" do
      received = []
      configuration = config_for(["rigor-alpha"])
      expect(described_class.bundled_plugin_path("rigor-alpha")).to be_nil

      described_class.load(
        configuration: configuration, services: services_for(configuration),
        requirer: capturing_requirer(received)
      )

      expect(received).to eq(["rigor-alpha"])
    end

    # (c) When the engine's bundled copy is absent (a trimmed ADR-27 packaging), the loader falls back to the
    #     bare gem name so no install mode regresses — even for a gem the engine normally bundles.
    it "falls back to the bare gem name when the anchored file is absent" do
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(anchored).and_return(false)
      received = []
      configuration = config_for([bundled_gem])

      described_class.load(
        configuration: configuration, services: services_for(configuration),
        requirer: capturing_requirer(received)
      )

      expect(received).to eq([bundled_gem])
    end

    # (d) Slice-1 interplay: an absolute-path require's `$LOADED_FEATURES` entry still ends in `/<gem>.rb`,
    #     the suffix FEATURE_RESOLVER matches — so anchoring does not break slice 1's resolved-path capture.
    it "anchors to a path the slice-1 feature resolver still pins" do
      expect(anchored).to end_with("/#{bundled_gem}.rb")

      # Probe the real FEATURE_RESOLVER against an absolute-path entry, with a synthetic gem name so the real
      # `$LOADED_FEATURES` is never left mutated for a plugin the suite might genuinely have loaded.
      probe_path = "/fake/gems/rigor-anchor-probe/lib/rigor-anchor-probe.rb"
      $LOADED_FEATURES.push(probe_path)
      expect(described_class::FEATURE_RESOLVER.call("rigor-anchor-probe")).to eq(probe_path)
    ensure
      $LOADED_FEATURES.delete(probe_path)
    end
  end
end
