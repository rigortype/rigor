# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-7 § "Slice 6" end-to-end coverage for the plugin-side cache producer surface — the `Plugin::Base.producer` DSL,
# `Plugin::Base#cache_for` callable, automatic PluginEntry attachment (6-B), and `plugin.<id>.` producer-id sandbox
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

  describe ".producer watch: validation (ADR-60 WD3)" do
    it "accepts nil, an Array, and a Proc" do
      expect do
        Class.new(described_class) do
          manifest(id: "alpha", version: "0.1.0")
          producer(:a) { |_p| 1 }
          producer(:b, watch: [["app/models", "**/*.rb"]]) { |_p| 2 }
          producer(:c, watch: -> { [["app/models", "**/*.rb"]] }) { |_p| 3 }
        end
      end.not_to raise_error
    end

    it "rejects a non-nil, non-Array, non-callable watch:" do
      expect do
        Class.new(described_class) do
          manifest(id: "alpha", version: "0.1.0")
          producer(:bad, watch: "app/models") { |_p| 1 }
        end
      end.to raise_error(ArgumentError, /watch: must be nil, an Array/)
    end
  end

  # Issue #151 — the producer, not a table inside `Cache::Store`, states how many of its generations survive
  # a compaction pass. A plugin producer keeps many entries live at once, so the default opts out.
  describe ".producer generation_cap: (issue #151)" do
    it "defaults to :unbounded and accepts a positive Integer" do
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
        producer(:many) { |_p| 1 }
        producer(:whole_project, generation_cap: 2) { |_p| 2 }
      end

      expect(klass.producers[:many][:generation_cap]).to eq(Rigor::Cache::Store::UNBOUNDED_GENERATIONS)
      expect(klass.producers[:whole_project][:generation_cap]).to eq(2)
    end

    it "rejects a non-positive / non-symbolic generation_cap at class-definition time" do
      expect do
        Class.new(described_class) do
          manifest(id: "alpha", version: "0.1.0")
          producer(:bad, generation_cap: 0) { |_p| 1 }
        end
      end.to raise_error(ArgumentError, /generation_cap: must be a positive Integer/)
    end

    it "threads the declared cap through cache_for into the Store" do
      store = Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache"))
      declared = []
      allow(store).to receive(:fetch_or_validate).and_wrap_original do |original, **kwargs, &block|
        declared << [kwargs[:producer_id], kwargs[:generation_cap]]
        original.call(**kwargs, &block)
      end
      plugin_services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection, type: Rigor::Type::Combinator,
        configuration: configuration, cache_store: store, trust_policy: trust_policy
      )
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
        producer(:whole_project, generation_cap: 3) { |_p| :value }
      end

      klass.new(services: plugin_services).cache_for(:whole_project, params: {}).call

      expect(declared).to eq([["plugin.alpha.whole_project", 3]])
    end
  end

  # ADR-60 WD3 — `cache_for` rides `Cache::Store#fetch_or_validate`: the entry is keyed on the stable identity inputs,
  # and the dependency descriptor (boundary reads + `watch:` globs) is recorded AFTER the producer block runs. Each
  # "session" below uses a FRESH `Cache::Store` (empty in-process memo) and a fresh plugin instance — the faithful
  # simulation of a second `rigor check` process reading the same on-disk cache, per the established
  # `pundit_plugin_spec` cross-process pattern.
  describe "#cache_for record-and-validate (ADR-60 WD3)" do
    let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }

    def services_with_fresh_store
      Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: configuration,
        cache_store: Rigor::Cache::Store.new(root: cache_root),
        trust_policy: trust_policy
      )
    end

    it "recomputes when a file read INSIDE the producer block changes between sessions" do
      file = File.join(tmpdir, "data.txt")
      File.write(file, "v1")

      # The structural hazard being fixed: the block performs the read, nothing primes the boundary beforehand. Under
      # the old `fetch_or_compute` call-time snapshot this read was invisible to the descriptor and session 2 served
      # stale "v1".
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      target = file
      klass.producer(:contents) { |_params| io_boundary.read_file(target) }

      first = klass.new(services: services_with_fresh_store)
      expect(first.cache_for(:contents, params: {}).call).to eq("v1")

      File.write(file, "v2")
      second = klass.new(services: services_with_fresh_store)
      expect(second.cache_for(:contents, params: {}).call).to eq("v2")
    end

    it "hits across sessions while the in-block-read file is unchanged" do
      file = File.join(tmpdir, "data.txt")
      File.write(file, "stable")

      calls = 0
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      target = file
      klass.producer(:contents) do |_params|
        calls += 1
        io_boundary.read_file(target)
      end

      expect(klass.new(services: services_with_fresh_store).cache_for(:contents, params: {}).call).to eq("stable")
      expect(klass.new(services: services_with_fresh_store).cache_for(:contents, params: {}).call).to eq("stable")
      expect(calls).to eq(1)
    end

    it "recomputes when a watch:-globbed file is ADDED between sessions (Proc form, instance state)" do
      models = File.join(tmpdir, "app", "models")
      FileUtils.mkdir_p(models)
      File.write(File.join(models, "a.rb"), "class A; end")

      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
        attr_reader :search_root

        def init(_services)
          # `watch:` Procs run at cache_for time, so init-derived roots like this one are visible to them.
          @search_root = config.fetch("root")
        end

        producer :model_count, watch: -> { [[search_root, "**/*.rb"]] } do |_params|
          Dir.glob(File.join(search_root, "**/*.rb")).size
        end
      end

      run_session = lambda do
        plugin = klass.new(services: services_with_fresh_store, config: { "root" => models })
        plugin.init(plugin.services)
        plugin.cache_for(:model_count, params: {}).call
      end

      expect(run_session.call).to eq(1)

      File.write(File.join(models, "b.rb"), "class B; end")
      expect(run_session.call).to eq(2)

      File.unlink(File.join(models, "b.rb"))
      expect(run_session.call).to eq(1)
    end

    it "recomputes when a watch:-globbed file CHANGES between sessions (static Array form)" do
      conf = File.join(tmpdir, "config")
      FileUtils.mkdir_p(conf)
      File.write(File.join(conf, "routes.rb"), "get '/a'")

      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      root = conf
      klass.producer(:routes, watch: [[root, "**/*.rb"]]) do |_params|
        File.read(File.join(root, "routes.rb"))
      end

      expect(klass.new(services: services_with_fresh_store).cache_for(:routes, params: {}).call).to eq("get '/a'")

      File.write(File.join(conf, "routes.rb"), "get '/b'")
      expect(klass.new(services: services_with_fresh_store).cache_for(:routes, params: {}).call).to eq("get '/b'")
    end

    it "round-trips a custom serialize/deserialize pair over the producer's value" do
      ser = ->(value) { value.to_s.b }
      des = ->(bytes) { bytes.to_s } # rubocop:disable Style/SymbolProc
      calls = 0
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      klass.producer(:greeting, serialize: ser, deserialize: des) do |_params|
        calls += 1
        "hello"
      end

      expect(klass.new(services: services_with_fresh_store).cache_for(:greeting, params: {}).call).to eq("hello")
      expect(klass.new(services: services_with_fresh_store).cache_for(:greeting, params: {}).call).to eq("hello")
      expect(calls).to eq(1)
    end

    it "treats a producer that fetched a URL as never-fresh (recomputes every session, never stale)" do
      http_client = Class.new do
        def get(_url, timeout:, max_bytes:) # rubocop:disable Lint/UnusedMethodArgument
          "remote-body"
        end
      end.new
      policy = Rigor::Plugin::TrustPolicy.new(
        allowed_read_roots: [tmpdir],
        network_policy: :allowlist,
        allowed_url_hosts: ["example.com"]
      )
      boundary = Rigor::Plugin::IoBoundary.new(policy: policy, plugin_id: "alpha", http_client: http_client)

      calls = 0
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      klass.producer(:remote) do |_params|
        calls += 1
        io_boundary.open_url("https://example.com/doc")
      end

      2.times do
        plugin = klass.new(services: services_with_fresh_store)
        plugin.instance_variable_set(:@io_boundary, boundary)
        expect(plugin.cache_for(:remote, params: {}).call).to eq("remote-body")
      end
      # ConfigEntry rows in the dependency descriptor make fresh? false by design — sound (never stale), recompute every
      # run.
      expect(calls).to eq(2)
    end

    it "reads a store dir containing unreadable foreign entries as silent misses" do
      klass = Class.new(described_class) do
        manifest(id: "alpha", version: "0.1.0")
      end
      klass.producer(:value) { |_p| 7 }

      # Simulate an old-format / corrupt entry already on disk.
      stale_dir = File.join(cache_root, "plugin.alpha.value", "ab")
      FileUtils.mkdir_p(stale_dir)
      File.binwrite(File.join(stale_dir, "cdef.entry"), "OLDFORMAT-not-a-rigor-entry")

      plugin = klass.new(services: services_with_fresh_store)
      expect(plugin.cache_for(:value, params: {}).call).to eq(7)
    end
  end
end
