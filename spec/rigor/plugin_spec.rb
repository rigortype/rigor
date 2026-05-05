# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin do
  let(:plugin_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "demo", version: "0.1.0")
    end
  end

  before { described_class.unregister! }
  after { described_class.unregister! }

  describe ".register" do
    it "stores the class indexed by manifest id" do
      described_class.register(plugin_class)
      expect(described_class.registered_for("demo")).to eq(plugin_class)
      expect(described_class.registered_for(:demo)).to eq(plugin_class)
    end

    it "is idempotent for the same class" do
      described_class.register(plugin_class)
      expect { described_class.register(plugin_class) }.not_to raise_error
      expect(described_class.registered.size).to eq(1)
    end

    it "raises when two classes claim the same id" do
      described_class.register(plugin_class)
      conflicting = Class.new(Rigor::Plugin::Base) do
        manifest(id: "demo", version: "0.2.0")
      end

      expect { described_class.register(conflicting) }.to raise_error(
        Rigor::Plugin::LoadError, /already registered/
      )
    end

    it "rejects classes that do not subclass Rigor::Plugin::Base" do
      bare = Class.new
      expect { described_class.register(bare) }.to raise_error(ArgumentError, /subclass of Rigor::Plugin::Base/)
    end
  end

  describe ".unregister!" do
    it "clears a single id when given one" do
      described_class.register(plugin_class)
      described_class.unregister!("demo")
      expect(described_class.registered_for("demo")).to be_nil
    end

    it "clears all registrations when called without an argument" do
      described_class.register(plugin_class)
      described_class.unregister!
      expect(described_class.registered).to be_empty
    end
  end

  describe ".registered" do
    it "returns a frozen snapshot" do
      described_class.register(plugin_class)
      snapshot = described_class.registered
      expect(snapshot).to be_frozen
      expect { snapshot["other"] = Class.new }.to raise_error(FrozenError)
    end
  end
end
