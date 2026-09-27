# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"
require "rigor/analysis/plugin_fact_fingerprint"
require "rigor/cache/store"

# ADR-88 WD1 fixtures — synthetic plugins exercising each fact-surface channel. Class-level toggles let a
# spec vary a producer value / a published fact / a hook value and observe the digest move, without touching
# a disk cache (the specs build the probe with `cache_store: nil`, so every producer recomputes and reflects
# the current toggle). Guarded so a re-load of this spec file does not redeclare the manifests.
module Rigor
  module Plugin
    unless defined?(FpProducerPlugin)
      # Channel (b): a producer whose value is a class-level toggle.
      class FpProducerPlugin < Base
        @value = "v1"
        class << self
          attr_accessor :value
        end
        manifest(id: "fp-producer", version: "0.1.0")
        producer :thing do |_params|
          FpProducerPlugin.value
        end
      end

      # Channel (a): a plugin that publishes a fact whose value is a class-level toggle.
      class FpFactPlugin < Base
        @value = "f1"
        class << self
          attr_accessor :value
        end
        manifest(id: "fp-fact", version: "0.1.0")
        def prepare(services)
          services.fact_store.publish(plugin_id: manifest.id, name: :thing, value: FpFactPlugin.value)
        end
      end

      # Channel (c): a plugin that CONTRIBUTES a type (`dynamic_return`) and declares only the hook — the
      # surface a per-file / structural plugin uses. Non-opaque.
      class FpHookPlugin < Base
        @value = "h1"
        class << self
          attr_accessor :value
        end
        manifest(id: "fp-hook", version: "0.1.0")
        dynamic_return methods: [:thing] do |_call_node, _scope|
          nil
        end
        def incremental_state_fingerprint
          FpHookPlugin.value
        end
      end

      # A plugin that CONTRIBUTES a type but declares NO fact / producer / hook — opaque.
      class FpOpaquePlugin < Base
        manifest(id: "fp-opaque", version: "0.1.0")
        dynamic_return methods: [:thing] do |_call_node, _scope|
          nil
        end
      end

      # A plugin that declares NO surface AND contributes NO type — inert, never opaque.
      class FpInertPlugin < Base
        manifest(id: "fp-inert", version: "0.1.0")
      end
    end

    unless defined?(FpSharedKeyPlugin)
      # Issue #1574: a producer whose value shares one frozen String between an Array element, a row's field
      # and a Hash key, as rigor-sidekiq's `worker_index` does. It reads nothing, so once its cache entry is
      # written every later run is served it.
      class FpSharedKeyPlugin < Base
        Row = Data.define(:class_name, :arity)

        manifest(id: "fp-shared-key", version: "0.1.0")
        producer :index do |_params|
          names = %w[WelcomeWorker DigestWorker].map { |name| name.dup.freeze }
          rows = names.map { |name| Row.new(class_name: name, arity: 1) }
          { names: names, rows: rows, by_name: rows.to_h { |row| [row.class_name, row] } }
        end
      end

      # Issue #1574: publishes a fact no digest can see into (a Proc), beside a surface of its own (the hook).
      class FpUndigestibleFactPlugin < Base
        manifest(id: "fp-undigestible-fact", version: "0.1.0")

        def prepare(services)
          services.fact_store.publish(plugin_id: manifest.id, name: :callback, value: -> {})
        end

        def incremental_state_fingerprint
          "static"
        end
      end
    end
  end
end

RSpec.describe Rigor::Analysis::PluginFactFingerprint do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def config_for(*plugin_ids)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["x"], "plugins" => plugin_ids)
    )
  end

  # A requirer that registers the named fixtures instead of touching the real load path.
  def requirer_for(map)
    lambda do |name|
      klass = map.fetch(name)
      Rigor::Plugin.register(klass)
      true
    end
  end

  def compute(config, map)
    described_class.compute(
      configuration: config, cache_store: nil, plugin_requirer: requirer_for(map)
    )
  end

  describe "the empty / inert cases" do
    it "returns a nil digest and no opacity when no plugins are configured" do
      result = compute(config_for, {})
      expect(result.digest).to be_nil
      expect(result.opaque?).to be(false)
      expect(result.reusable_against?(nil)).to be(true)
    end

    it "is non-opaque for a plugin that neither contributes a type nor declares a surface" do
      result = compute(config_for("fp-inert"), { "fp-inert" => Rigor::Plugin::FpInertPlugin })
      expect(result.opaque?).to be(false)
    end
  end

  describe "channel (b) — producer values" do
    it "moves the digest when a producer's value changes" do
      map = { "fp-producer" => Rigor::Plugin::FpProducerPlugin }
      Rigor::Plugin::FpProducerPlugin.value = "v1"
      first = compute(config_for("fp-producer"), map)
      Rigor::Plugin.unregister!
      Rigor::Plugin::FpProducerPlugin.value = "v2"
      second = compute(config_for("fp-producer"), map)

      expect(first.digest).not_to be_nil
      expect(second.digest).not_to eq(first.digest)
      expect(second.reusable_against?(first.digest)).to be(false)
    ensure
      Rigor::Plugin::FpProducerPlugin.value = "v1"
    end

    it "is stable across two computations when nothing changes" do
      map = { "fp-producer" => Rigor::Plugin::FpProducerPlugin }
      first = compute(config_for("fp-producer"), map)
      Rigor::Plugin.unregister!
      second = compute(config_for("fp-producer"), map)
      expect(second.digest).to eq(first.digest)
      expect(second.reusable_against?(first.digest)).to be(true)
    end
  end

  describe "channel (a) — published facts" do
    it "moves the digest when a published fact's value changes" do
      map = { "fp-fact" => Rigor::Plugin::FpFactPlugin }
      Rigor::Plugin::FpFactPlugin.value = "f1"
      first = compute(config_for("fp-fact"), map)
      Rigor::Plugin.unregister!
      Rigor::Plugin::FpFactPlugin.value = "f2"
      second = compute(config_for("fp-fact"), map)
      expect(second.digest).not_to eq(first.digest)
    ensure
      Rigor::Plugin::FpFactPlugin.value = "f1"
    end
  end

  describe "channel (c) — incremental_state_fingerprint hook" do
    it "moves the digest when the hook value changes and keeps a contributing plugin non-opaque" do
      map = { "fp-hook" => Rigor::Plugin::FpHookPlugin }
      Rigor::Plugin::FpHookPlugin.value = "h1"
      first = compute(config_for("fp-hook"), map)
      expect(first.opaque?).to be(false)
      Rigor::Plugin.unregister!
      Rigor::Plugin::FpHookPlugin.value = "h2"
      second = compute(config_for("fp-hook"), map)
      expect(second.digest).not_to eq(first.digest)
    ensure
      Rigor::Plugin::FpHookPlugin.value = "h1"
    end
  end

  describe "pooled/sequential parity — the two computation paths agree" do
    it "computes the same digest via the sequential probe (compute) and the post-hoc path (from_registry)" do
      config = config_for("fp-producer")
      map = { "fp-producer" => Rigor::Plugin::FpProducerPlugin }
      Rigor::Plugin::FpProducerPlugin.value = "v1"
      probe = described_class.compute(configuration: config, cache_store: nil, plugin_requirer: requirer_for(map))
      Rigor::Plugin.unregister!
      # A prepared registry stands in for the analysis runner's registry the sequential post-hoc path reads.
      registry = described_class.prepared_registry(
        configuration: config, cache_store: nil, plugin_requirer: requirer_for(map)
      )
      posthoc = described_class.from_registry(registry)
      expect(posthoc.digest).to eq(probe.digest)
      expect(posthoc.opaque_plugin_ids).to eq(probe.opaque_plugin_ids)
    ensure
      Rigor::Plugin::FpProducerPlugin.value = "v1"
    end
  end

  # Issue #1574 — the gate. The first `compute` runs the producer and writes its cache entry; the second, over
  # the same store root, is served that entry. The two values are equal, but the served one no longer shares
  # the String its Hash keys on, so a digest of `Marshal.dump` bytes differed and every run that switched
  # between computing and serving a producer threw the snapshot away.
  describe "a producer value computed on one run and served from the cache on the next" do
    it "digests alike on both runs" do
      Dir.mktmpdir do |root|
        map = { "fp-shared-key" => Rigor::Plugin::FpSharedKeyPlugin }
        config = config_for("fp-shared-key")
        computing = Rigor::Cache::Store.new(root: root)
        computed = described_class.compute(configuration: config, cache_store: computing,
                                           plugin_requirer: requirer_for(map))
        Rigor::Plugin.unregister!
        serving = Rigor::Cache::Store.new(root: root)
        served = described_class.compute(configuration: config, cache_store: serving,
                                         plugin_requirer: requirer_for(map))

        producer_id = "plugin.fp-shared-key.index"
        expect(computing.stats[:by_producer][producer_id]).to include(misses: 1, writes: 1)
        expect(serving.stats[:by_producer][producer_id]).to include(hits: 1, misses: 0)
        expect(served.digest).to eq(computed.digest)
        expect(served.reusable_against?(computed.digest)).to be(true)
      end
    end
  end

  # Issue #1574 — a fact the digest cannot read must not read as "unchanged". Before, one undigestible fact
  # dropped every plugin's facts from the digest, and a publisher with another surface (here the hook) stayed
  # reusable while its facts went unseen.
  describe "a published fact the digest cannot read" do
    it "makes its publisher opaque, so the snapshot is not reused" do
      map = {
        "fp-undigestible-fact" => Rigor::Plugin::FpUndigestibleFactPlugin, "fp-fact" => Rigor::Plugin::FpFactPlugin
      }
      result = compute(config_for("fp-undigestible-fact", "fp-fact"), map)

      expect(result.opaque_plugin_ids).to eq(["fp-undigestible-fact"])
      expect(result.reusable_against?(result.digest)).to be(false)
    end
  end

  describe "opacity — a contributing plugin with no surface" do
    it "names the plugin and makes the snapshot un-reusable" do
      result = compute(config_for("fp-opaque"), { "fp-opaque" => Rigor::Plugin::FpOpaquePlugin })
      expect(result.opaque?).to be(true)
      expect(result.opaque_plugin_ids).to eq(["fp-opaque"])
      # Even when the digest matches the stored one, opacity forbids reuse.
      expect(result.reusable_against?(result.digest)).to be(false)
    end
  end
end
