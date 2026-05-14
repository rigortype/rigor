# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-7 § "Slice 6" end-to-end coverage for the plugin-side
# cache producer surface — the `Plugin::Base.producer` DSL,
# `Plugin::Base#cache_for` callable, automatic PluginEntry
# attachment (6-B), and `plugin.<id>.` producer-id sandbox
# prefix (6-C).
RSpec.describe Rigor::Plugin::Base, # rubocop:disable RSpec/SpecFilePathFormat
               "cache producers (slice 6)" do # rubocop:disable RSpec/DescribeMethod
  let(:tmpdir) { Dir.mktmpdir("rigor-plugin-cache-spec-") }
  let(:store) { Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache")) }
  let(:trust_policy) do
    Rigor::Plugin::TrustPolicy.new(allowed_read_roots: [tmpdir])
  end
  let(:configuration) { Rigor::Configuration.new }
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: configuration,
      cache_store: store,
      trust_policy: trust_policy
    )
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe ".producer DSL (6-A)" do
    it "records a producer block keyed by id" do
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
        producer :hello do |_params|
          "world"
        end
      end

      expect(klass.producers).to include(:hello)
      expect(klass.producers).to be_frozen
    end

    it "rejects a producer declaration without a block" do
      expect do
        Class.new(described_class) do
          manifest(id: "alpha", version: "0.1.0")
          producer :hello
        end
      end.to raise_error(ArgumentError, /requires a block body/)
    end

    it "accepts custom serialize / deserialize callables" do
      ser = ->(value) { value.to_s.b }
      des = ->(bytes) { bytes.to_s } # rubocop:disable Style/SymbolProc
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
        producer :hello, serialize: ser, deserialize: des do |_params|
          "world"
        end
      end

      entry = klass.producers[:hello]
      expect(entry[:serialize]).to eq(ser)
      expect(entry[:deserialize]).to eq(des)
    end
  end

  describe "#cache_for callable" do
    let(:plugin_class) do
      Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
        producer :doubled do |params|
          params.fetch(:n) * 2
        end
      end
    end

    it "raises when the producer id is not declared" do
      plugin = plugin_class.new(services: services)
      expect { plugin.cache_for(:missing) }.to raise_error(ArgumentError, /did not declare producer/)
    end

    it "computes the value on cache miss and caches under plugin.<id>.<producer> (6-C)" do
      plugin = plugin_class.new(services: services)
      callable = plugin.cache_for(:doubled, params: { n: 3 })
      expect(callable.call).to eq(6)

      stats = store.stats
      expect(stats[:misses]).to eq(1)
      expect(stats[:writes]).to eq(1)
      expect(stats[:by_producer].keys).to include("plugin.alpha.doubled")
    end

    it "hits the cache on the second call with identical params (PluginEntry stable)" do
      plugin = plugin_class.new(services: services)
      plugin.cache_for(:doubled, params: { n: 3 }).call
      plugin.cache_for(:doubled, params: { n: 3 }).call

      stats = store.stats
      expect(stats[:misses]).to eq(1)
      expect(stats[:hits]).to eq(1)
    end

    it "treats different plugin manifest versions as different cache slices (6-B)" do
      v1 = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
        producer(:value) { |_p| 1 }
      end.new(services: services)
      v2 = Class.new(described_class) do
        manifest(id: "alpha", version: "0.2.0")
        producer(:value) { |_p| 2 }
      end.new(services: services)

      expect(v1.cache_for(:value, params: {}).call).to eq(1)
      expect(v2.cache_for(:value, params: {}).call).to eq(2)
    end

    it "treats different plugin config hashes as different cache slices (6-B)" do
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
        producer(:value) { |_p| config.fetch("flag") }
      end

      a = klass.new(services: services, config: { "flag" => "enabled" })
      b = klass.new(services: services, config: { "flag" => "disabled" })

      expect(a.cache_for(:value, params: {}).call).to eq("enabled")
      expect(b.cache_for(:value, params: {}).call).to eq("disabled")
    end

    it "bypasses the cache when services.cache_store is nil (--no-cache)" do
      no_cache_services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration,
        cache_store: nil,
        trust_policy: trust_policy
      )
      called = 0
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      klass.producer(:value) { |_p| called += 1; 42 } # rubocop:disable Style/Semicolon

      plugin = klass.new(services: no_cache_services)
      callable = plugin.cache_for(:value, params: {})
      expect(callable.call).to eq(42)
      expect(callable.call).to eq(42)
      expect(called).to eq(2)
    end

    it "exposes io_boundary inside the producer block via instance_exec" do
      file = File.join(tmpdir, "data.txt")
      File.write(file, "hello")
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      klass.producer(:contents) { |params| io_boundary.read_file(params.fetch(:path)) }

      plugin = klass.new(services: services)
      result = plugin.cache_for(:contents, params: { path: file }).call
      expect(result).to eq("hello")
    end

    it "composes a plugin-author-supplied descriptor with the auto-built one" do
      called = 0
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      klass.producer(:value) { |_p| called += 1; 99 } # rubocop:disable Style/Semicolon
      plugin = klass.new(services: services)

      v1 = Rigor::Cache::Descriptor.new(
        gems: [Rigor::Cache::Descriptor::GemEntry.new(name: "rails", requirement: ">= 0", locked: "7.0.0")]
      )
      v2 = Rigor::Cache::Descriptor.new(
        gems: [Rigor::Cache::Descriptor::GemEntry.new(name: "rails", requirement: ">= 0", locked: "7.1.0")]
      )

      expect(plugin.cache_for(:value, params: {}, descriptor: v1).call).to eq(99)
      expect(plugin.cache_for(:value, params: {}, descriptor: v1).call).to eq(99)
      # Same auto-built + same extra → cache hit, called stays at 1
      expect(called).to eq(1)

      # Different gem-version pin → different cache slice → recompute
      expect(plugin.cache_for(:value, params: {}, descriptor: v2).call).to eq(99)
      expect(called).to eq(2)
    end

    it "raises Cache::Descriptor::Conflict when extra and auto-built rows disagree" do
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      klass.producer(:value) { |_p| 1 }
      plugin = klass.new(services: services)

      conflicting = Rigor::Cache::Descriptor.new(
        plugins: [Rigor::Cache::Descriptor::PluginEntry.new(
          id: "alpha", version: "9.9.9", config_hash: "x"
        )]
      )

      expect do
        plugin.cache_for(:value, params: {}, descriptor: conflicting).call
      end.to raise_error(Rigor::Cache::Descriptor::Conflict)
    end

    it "invalidates when files read via io_boundary BEFORE cache_for change between calls" do
      file = File.join(tmpdir, "data.txt")
      File.write(file, "v1")

      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      target = file
      klass.producer(:contents) { |_params| io_boundary.read_file(target) }
      klass.define_method(:fetch_contents) do
        io_boundary.read_file(target)
        cache_for(:contents, params: {}).call
      end

      first = klass.new(services: services)
      expect(first.fetch_contents).to eq("v1")

      File.write(file, "v2")
      second = klass.new(services: services)
      expect(second.fetch_contents).to eq("v2")
    end
  end
end
