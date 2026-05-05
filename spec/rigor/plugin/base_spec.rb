# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Base do
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end

  describe ".manifest" do
    it "stores a manifest declared at class definition" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "1.2.3", description: "demo plugin")
      end

      expect(klass.manifest).to be_a(Rigor::Plugin::Manifest)
      expect(klass.manifest.id).to eq("demo")
      expect(klass.manifest.description).to eq("demo plugin")
    end

    it "raises when accessed without a prior declaration" do
      klass = Class.new(described_class)
      expect { klass.manifest }.to raise_error(ArgumentError, /did not declare a manifest/)
    end
  end

  describe "#initialize" do
    it "stores the injected services and frozen config" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end

      plugin = klass.new(services: services, config: { "k" => 1 })
      expect(plugin.services).to eq(services)
      expect(plugin.config).to eq({ "k" => 1 })
      expect(plugin.config).to be_frozen
    end

    it "delegates `manifest` to the class" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end
      plugin = klass.new(services: services)
      expect(plugin.manifest).to eq(klass.manifest)
    end
  end

  describe "#init" do
    it "is a no-op by default" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end
      plugin = klass.new(services: services)
      expect(plugin.init(services)).to be_nil
    end

    it "can be overridden by subclasses" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")

        attr_reader :captured

        def init(services)
          @captured = services.reflection
        end
      end

      plugin = klass.new(services: services)
      plugin.init(services)
      expect(plugin.captured).to eq(Rigor::Reflection)
    end
  end
end
