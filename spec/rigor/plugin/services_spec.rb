# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Services do
  it "exposes the core analyzer services" do
    services = described_class.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new,
      cache_store: nil
    )

    expect(services.reflection).to eq(Rigor::Reflection)
    expect(services.type).to eq(Rigor::Type::Combinator)
    expect(services.configuration).to be_a(Rigor::Configuration)
    expect(services.cache_store).to be_nil
  end

  it "is frozen after construction" do
    services = described_class.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
    expect(services).to be_frozen
  end

  it "defaults to a network-disabled trust policy when none is supplied" do
    services = described_class.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
    expect(services.trust_policy).to be_a(Rigor::Plugin::TrustPolicy)
    expect(services.trust_policy.network_allowed?).to be(false)
  end

  it "carries a user-supplied trust policy through to plugins" do
    Dir.mktmpdir do |dir|
      policy = Rigor::Plugin::TrustPolicy.new(
        trusted_gems: ["rigor-rspec"],
        allowed_read_roots: [dir]
      )
      services = described_class.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: Rigor::Configuration.new,
        trust_policy: policy
      )
      expect(services.trust_policy).to eq(policy)
    end
  end

  describe "#io_boundary_for" do
    it "returns a fresh IoBoundary bound to the requested plugin id" do
      Dir.mktmpdir do |dir|
        services = described_class.new(
          reflection: Rigor::Reflection,
          type: Rigor::Type::Combinator,
          configuration: Rigor::Configuration.new,
          trust_policy: Rigor::Plugin::TrustPolicy.new(allowed_read_roots: [dir])
        )

        boundary = services.io_boundary_for("alpha")
        expect(boundary).to be_a(Rigor::Plugin::IoBoundary)
        expect(boundary.plugin_id).to eq("alpha")
        expect(boundary.policy).to eq(services.trust_policy)
      end
    end
  end

  describe "#fact_store (ADR-9 slice 2)" do
    it "constructs a fresh Plugin::FactStore by default" do
      services = described_class.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: Rigor::Configuration.new
      )

      expect(services.fact_store).to be_a(Rigor::Plugin::FactStore)
      expect(services.fact_store.read(plugin_id: "x", name: :y)).to be_nil
    end

    it "carries a user-supplied FactStore through unchanged" do
      injected = Rigor::Plugin::FactStore.new
      injected.publish(plugin_id: "activerecord", name: :model_index, value: { user: %i[id] })

      services = described_class.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: Rigor::Configuration.new,
        fact_store: injected
      )

      expect(services.fact_store).to be(injected)
      expect(services.fact_store.read(plugin_id: "activerecord", name: :model_index))
        .to eq(user: %i[id])
    end
  end
end
