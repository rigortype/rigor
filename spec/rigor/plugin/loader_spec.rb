# frozen_string_literal: true

require "spec_helper"

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

    it "preserves configuration order across multiple plugins" do # rubocop:disable RSpec/ExampleLength
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

    it "calls #init on every loaded plugin with the service container" do # rubocop:disable RSpec/ExampleLength
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

    it "passes user config into the plugin instance after schema validation" do # rubocop:disable RSpec/ExampleLength
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
      expect(registry.load_errors.first.message).to match(/could not load plugin gem "rigor-alpha"/)
    end

    it "surfaces missing-registration failures as load errors" do
      requirer = ->(_name) { true }

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.plugins).to be_empty
      expect(registry.load_errors.first.message).to match(/did not register any plugin/)
    end

    it "surfaces multi-registration ambiguity as a load error" do
      requirer = lambda { |_name|
        Rigor::Plugin.register(plugin_class_a)
        Rigor::Plugin.register(plugin_class_b)
        true
      }

      registry = described_class.load(configuration: configuration, services: services, requirer: requirer)

      expect(registry.plugins).to be_empty
      expect(registry.load_errors.first.message).to match(/registered multiple plugins/)
    end

    it "resolves an explicit `id:` even when the gem registers multiple plugins" do # rubocop:disable RSpec/ExampleLength
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

    it "rejects duplicate plugin ids in the configuration" do # rubocop:disable RSpec/ExampleLength
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
      expect(registry.load_errors.first.message).to match(/appeared twice/)
    end

    it "surfaces config schema violations as load errors" do # rubocop:disable RSpec/ExampleLength
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
      expect(registry.load_errors.first.message).to match(/expected boolean/)
    end

    it "surfaces #init exceptions as load errors without crashing the loader" do # rubocop:disable RSpec/ExampleLength
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
end
