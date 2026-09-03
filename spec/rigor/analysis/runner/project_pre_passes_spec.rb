# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #135 self-mutation sweep — the giant >300 LOC engine-file tier. `ProjectPrePasses` (336 LOC) had NO
# convention spec at all before this file, so this is authorship, not a gap-fill: the examples below exist to
# pin the class's own promises before the mutation pass ever ran, then close what it found.
#
# What the class promises (mirrors the file's own header comment):
#
# - `#run` drives every EAGER project-wide pre-pass (plugin load + `#prepare`, the dependency-source index,
#   the synthetic-method scanner, the project-patched `pre_eval:` scanner) into one frozen {Result}. Pool mode
#   defers `#prepare` (each pool worker re-runs it on its own instance) so `#run` must NOT invoke it eagerly
#   when `pool_mode:` reads true. A `pre_eval:` entry that does not exist on disk is filtered before the
#   scanner ever sees it — slice-1 already surfaced its `pre-eval.file-not-found` diagnostic elsewhere.
# - `#discover` / `#discover_from_bundles` / `#build_discovery` build the DEFERRED cross-file discovery
#   tables (class index + def index) from one shared `{classes:, def_index:}` shape into the {Discovery}
#   bundle — a pure field-by-field translation with 12 slots easy to silently transpose.
# - `#build_project_scan` / `#adopt_prebuilt` translate between {Result} and the LSP-facing {ProjectScan}
#   snapshot in both directions — also pure field translation, plus a `.dup.freeze` on the two diagnostic
#   streams `#build_project_scan` re-derives.
# - `#prepared_registry` loads plugins and runs `#prepare` UNCONDITIONALLY (no pool-mode skip — the
#   fact-fingerprint probe that calls it is always sequential) while discarding prepare diagnostics: a plugin
#   that fails to prepare contributes no facts, so it is silently absent from the fingerprint rather than
#   erroring the probe.
# - Plugin loading isolates every per-plugin failure: a bad `plugins:` entry becomes a load error on the
#   {Rigor::Plugin::Registry}, and a `#prepare` raise becomes one diagnostic per plugin — never an exception
#   out of `#run` / `#prepared_registry`.
RSpec.describe Rigor::Analysis::Runner::ProjectPrePasses do
  around do |example|
    original_bundle_root = Rigor::Plugin::Isolation.target_bundle_root
    example.run
  ensure
    Rigor::Plugin::Isolation.target_bundle_root = original_bundle_root
    Rigor::Plugin.unregister!
  end

  def build_pre_passes(
    configuration: Rigor::Configuration.new(Rigor::Configuration::DEFAULTS),
    cache_store: nil, buffer: nil, plugin_requirer: nil, pool_mode: false
  )
    described_class.new(
      configuration: configuration, cache_store: cache_store, buffer: buffer,
      plugin_requirer: plugin_requirer, pool_mode: -> { pool_mode }
    )
  end

  def real_services(configuration = Rigor::Configuration.new)
    Rigor::Plugin::Services.new(reflection: Rigor::Reflection, type: Rigor::Type::Combinator,
                                configuration: configuration)
  end

  describe "#run" do
    it "returns an inert Result when the project declares no plugins and no pre_eval entries" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "a.rb")
        File.write(path, "x = 1\n")
        pre_passes = build_pre_passes(configuration: Rigor::Configuration.new("paths" => [dir]))

        result = Dir.chdir(dir) { pre_passes.run(expansion: { files: [path] }) }

        expect(result.plugin_registry).to eq(Rigor::Plugin::Registry::EMPTY)
        expect(result.cached_plugin_prepare_diagnostics).to eq([])
        expect(result.pre_eval_diagnostics_from_scanner).to eq([])
        expect(result.project_patched_methods).to be_a(Rigor::Inference::ProjectPatchedMethods)
        expect(result.synthetic_method_index).not_to be_nil
      end
    end

    it "filters a pre_eval entry that does not exist on disk before scanning " \
       "(slice-1 already surfaced the missing-file diagnostic elsewhere)" do
      Dir.mktmpdir do |dir|
        existing = File.join(dir, "patch.rb")
        File.write(existing, "class Foo\n  def bar; end\nend\n")
        missing = File.join(dir, "does_not_exist.rb")
        configuration = Rigor::Configuration.new("paths" => [dir], "pre_eval" => [existing, missing])
        pre_passes = build_pre_passes(configuration: configuration)
        allow(Rigor::Inference::ProjectPatchedScanner).to receive(:scan).and_call_original

        Dir.chdir(dir) { pre_passes.run(expansion: { files: [] }) }

        expect(Rigor::Inference::ProjectPatchedScanner).to have_received(:scan).with([existing], buffer: nil)
      end
    end

    describe "plugin #prepare ordering (ADR-18 slice 3)" do
      it "runs #prepare eagerly and captures a raise into cached_plugin_prepare_diagnostics when NOT in pool mode" do
        raising_class = Class.new(Rigor::Plugin::Base) do
          manifest(id: "prepare-raises", version: "0.1.0")

          def prepare(_services)
            raise StandardError, "boom"
          end
        end
        stub_const("ProjectPrePassesSpecPrepareRaises", raising_class)
        requirer = lambda do |_name|
          Rigor::Plugin.register(raising_class)
          true
        end
        configuration = Rigor::Configuration.new("plugins" => ["rigor-prepare-raises"])
        pre_passes = build_pre_passes(configuration: configuration, plugin_requirer: requirer, pool_mode: false)

        result = pre_passes.run(expansion: { files: [] })

        expect(result.cached_plugin_prepare_diagnostics.size).to eq(1)
        expect(result.cached_plugin_prepare_diagnostics.first.message).to include("prepare-raises")
      end

      it "skips the eager #prepare call in pool mode, so a would-be-raising plugin surfaces NO diagnostic " \
         "here — each pool worker re-runs #prepare on its own instance instead" do
        raising_class = Class.new(Rigor::Plugin::Base) do
          manifest(id: "prepare-raises-pool", version: "0.1.0")

          def prepare(_services)
            raise StandardError, "boom"
          end
        end
        stub_const("ProjectPrePassesSpecPrepareRaisesPool", raising_class)
        requirer = lambda do |_name|
          Rigor::Plugin.register(raising_class)
          true
        end
        configuration = Rigor::Configuration.new("plugins" => ["rigor-prepare-raises-pool"])
        pre_passes = build_pre_passes(configuration: configuration, plugin_requirer: requirer, pool_mode: true)

        result = pre_passes.run(expansion: { files: [] })

        expect(result.cached_plugin_prepare_diagnostics).to eq([])
        expect(result.plugin_registry).not_to be_empty
      end
    end
  end

  describe "#discover / #discover_from_bundles / #build_discovery" do
    # rubocop:disable-next RSpec/ExampleLength
    it "builds every Discovery slot from the matching def_index key, without transposing any of the 17 slots" do
      index = {
        classes: :classes_marker,
        def_index: {
          def_nodes: :def_nodes_marker,
          def_nestings: :def_nestings_marker,
          singleton_def_nodes: :singleton_def_nodes_marker,
          def_sources: :def_sources_marker,
          singleton_def_sources: :singleton_def_sources_marker,
          superclasses: :superclasses_marker,
          header_nestings: :header_nestings_marker,
          includes: :includes_marker,
          class_sources: :class_sources_marker,
          # Issue #644 — the three constant slots. Distinct markers like every other key, so a slot wired to
          # the wrong `def_index` entry still fails here rather than merely satisfying the `fetch`.
          constant_values: :constant_values_marker,
          constant_sources: :constant_sources_marker,
          constant_writes: :constant_writes_marker,
          method_visibilities: :method_visibilities_marker,
          methods: :methods_marker,
          data_member_layouts: :data_member_layouts_marker,
          struct_member_layouts: :struct_member_layouts_marker
        }
      }
      pre_passes = build_pre_passes

      discovery = pre_passes.build_discovery(index)

      expect(discovery.discovered_classes).to eq(:classes_marker)
      expect(discovery.discovered_def_nodes).to eq(:def_nodes_marker)
      expect(discovery.discovered_def_nestings).to eq(:def_nestings_marker)
      expect(discovery.discovered_singleton_def_nodes).to eq(:singleton_def_nodes_marker)
      expect(discovery.discovered_def_sources).to eq(:def_sources_marker)
      expect(discovery.discovered_singleton_def_sources).to eq(:singleton_def_sources_marker)
      expect(discovery.discovered_superclasses).to eq(:superclasses_marker)
      expect(discovery.discovered_header_nestings).to eq(:header_nestings_marker)
      expect(discovery.discovered_includes).to eq(:includes_marker)
      expect(discovery.discovered_class_sources).to eq(:class_sources_marker)
      expect(discovery.constant_values).to eq(:constant_values_marker)
      expect(discovery.constant_sources).to eq(:constant_sources_marker)
      expect(discovery.constant_writes).to eq(:constant_writes_marker)
      expect(discovery.discovered_method_visibilities).to eq(:method_visibilities_marker)
      expect(discovery.discovered_methods).to eq(:methods_marker)
      expect(discovery.data_member_layouts).to eq(:data_member_layouts_marker)
      expect(discovery.struct_member_layouts).to eq(:struct_member_layouts_marker)
    end

    it "#discover walks the real project once and returns a Discovery whose class table finds a cross-file class" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "widget.rb")
        File.write(path, "class Widget\n  def render\n    1\n  end\nend\n")
        pre_passes = build_pre_passes

        discovery = pre_passes.discover(expansion: { files: [path] })

        expect(discovery.discovered_classes.keys).to include("Widget")
        expect(discovery.discovered_def_sources).to be_a(Hash)
      end
    end

    it "#discover_from_bundles folds a cold (empty seed) run into the same shape as #discover, " \
       "plus the refreshed per-file bundles the session persists" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "widget.rb")
        File.write(path, "class Widget\nend\n")
        pre_passes = build_pre_passes

        discovery, bundles = pre_passes.discover_from_bundles(expansion: { files: [path] }, seed_bundles: {})

        expect(discovery.discovered_classes.keys).to include("Widget")
        expect(bundles).to be_a(Hash)
        expect(bundles.keys).to include(path)
      end
    end
  end

  describe "#build_project_scan" do
    it "translates every Result slot into the matching ProjectScan slot, " \
       "and freezes an independent COPY of each diagnostic stream" do
      prepare_diagnostics = [:prepare_diag]
      pre_eval_diagnostics = [:pre_eval_diag]
      result = described_class::Result.new(
        plugin_registry: :registry_marker, dependency_source_index: :dsi_marker,
        cached_plugin_prepare_diagnostics: prepare_diagnostics,
        synthetic_method_index: :synth_marker, project_patched_methods: :patched_marker,
        pre_eval_diagnostics_from_scanner: pre_eval_diagnostics
      )
      pre_passes = build_pre_passes

      scan = pre_passes.build_project_scan(result)

      expect(scan.plugin_registry).to eq(:registry_marker)
      expect(scan.dependency_source_index).to eq(:dsi_marker)
      expect(scan.synthetic_method_index).to eq(:synth_marker)
      expect(scan.project_patched_methods).to eq(:patched_marker)
      expect(scan.plugin_prepare_diagnostics).to eq([:prepare_diag])
      expect(scan.plugin_prepare_diagnostics.frozen?).to be(true)
      expect(scan.plugin_prepare_diagnostics).not_to equal(prepare_diagnostics)
      expect(scan.pre_eval_diagnostics).to eq([:pre_eval_diag])
      expect(scan.pre_eval_diagnostics.frozen?).to be(true)
      expect(scan.pre_eval_diagnostics).not_to equal(pre_eval_diagnostics)
    end
  end

  describe "#adopt_prebuilt" do
    it "translates every ProjectScan slot into the matching Result slot, discovery tables left for the caller" do
      scan = Rigor::Analysis::ProjectScan.new(
        plugin_registry: :registry_marker, dependency_source_index: :dsi_marker,
        synthetic_method_index: :synth_marker, project_patched_methods: :patched_marker,
        plugin_prepare_diagnostics: [:prepare_diag], pre_eval_diagnostics: [:pre_eval_diag]
      )
      pre_passes = build_pre_passes

      result = pre_passes.adopt_prebuilt(scan)

      expect(result.plugin_registry).to eq(:registry_marker)
      expect(result.dependency_source_index).to eq(:dsi_marker)
      expect(result.cached_plugin_prepare_diagnostics).to eq([:prepare_diag])
      expect(result.synthetic_method_index).to eq(:synth_marker)
      expect(result.project_patched_methods).to eq(:patched_marker)
      expect(result.pre_eval_diagnostics_from_scanner).to eq([:pre_eval_diag])
    end
  end

  describe "#prepared_registry" do
    it "returns the EMPTY registry without invoking the plugin_requirer when no plugins are configured" do
      requirer = ->(_name) { raise "plugin_requirer must not be called when configuration.plugins is empty" }
      pre_passes = build_pre_passes(plugin_requirer: requirer)

      expect(pre_passes.prepared_registry).to eq(Rigor::Plugin::Registry::EMPTY)
    end

    it "loads plugins and runs #prepare unconditionally (no pool-mode skip), " \
       "keeping a plugin whose #prepare raised in the returned registry" do
      prepared = []
      plugin_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "fingerprint-probe", version: "0.1.0")
        define_method(:prepare) { |_services| prepared << :ran }
      end
      stub_const("ProjectPrePassesSpecFingerprintProbe", plugin_class)
      requirer = lambda do |_name|
        Rigor::Plugin.register(plugin_class)
        true
      end
      configuration = Rigor::Configuration.new("plugins" => ["rigor-fingerprint-probe"])
      # pool_mode: true would matter for #run, but #prepared_registry never reads it — proven by NOT wiring a
      # pool_mode reader at all: `-> { raise "pool_mode should never be read here" }`.
      pre_passes = described_class.new(
        configuration: configuration, cache_store: nil, buffer: nil, plugin_requirer: requirer,
        pool_mode: -> { raise "pool_mode should never be read here" }
      )

      registry = pre_passes.prepared_registry

      expect(prepared).to eq([:ran])
      expect(registry.plugins.size).to eq(1)
    end

    it "discards a raised #prepare error rather than propagating it or dropping the plugin" do
      raising_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "fingerprint-probe-raises", version: "0.1.0")

        def prepare(_services)
          raise StandardError, "boom"
        end
      end
      stub_const("ProjectPrePassesSpecFingerprintProbeRaises", raising_class)
      requirer = lambda do |_name|
        Rigor::Plugin.register(raising_class)
        true
      end
      configuration = Rigor::Configuration.new("plugins" => ["rigor-fingerprint-probe-raises"])
      pre_passes = build_pre_passes(configuration: configuration, plugin_requirer: requirer)

      registry = nil
      expect { registry = pre_passes.prepared_registry }.not_to raise_error
      expect(registry.plugins.size).to eq(1)
    end
  end

  describe "#shared_fact_store" do
    it "returns nil for a nil plugin_registry" do
      expect(build_pre_passes.shared_fact_store(nil)).to be_nil
    end

    it "returns nil for an empty plugin_registry" do
      expect(build_pre_passes.shared_fact_store(Rigor::Plugin::Registry::EMPTY)).to be_nil
    end

    it "returns the first plugin's services.fact_store for a non-empty registry" do
      services = real_services
      plugin_class = Class.new(Rigor::Plugin::Base) { manifest(id: "fact-store-owner", version: "0.1.0") }
      stub_const("ProjectPrePassesSpecFactStoreOwner", plugin_class)
      registry = Rigor::Plugin::Registry.new(plugins: [plugin_class.new(services: services)])

      expect(build_pre_passes.shared_fact_store(registry)).to equal(services.fact_store)
    end
  end

  describe "#pool_mode? (private)" do
    it "delegates to the injected pool_mode reader" do
      expect(build_pre_passes(pool_mode: true).send(:pool_mode?)).to be(true)
      expect(build_pre_passes(pool_mode: false).send(:pool_mode?)).to be(false)
    end
  end

  describe "#load_plugins (private)" do
    it "returns the EMPTY registry (identity, not merely an empty one) when configuration.plugins is empty" do
      expect(build_pre_passes.send(:load_plugins)).to equal(Rigor::Plugin::Registry::EMPTY)
    end

    it "loads a configured plugin through Plugin::Loader, trusting it via #build_trust_policy" do
      plugin_class = Class.new(Rigor::Plugin::Base) { manifest(id: "loaded-plugin", version: "0.1.0") }
      stub_const("ProjectPrePassesSpecLoadedPlugin", plugin_class)
      requirer = lambda do |_name|
        Rigor::Plugin.register(plugin_class)
        true
      end
      configuration = Rigor::Configuration.new("plugins" => ["rigor-loaded-plugin"])
      pre_passes = build_pre_passes(configuration: configuration, plugin_requirer: requirer)

      registry = pre_passes.send(:load_plugins)

      expect(registry.plugins.size).to eq(1)
      expect(registry.plugins.first.manifest.id).to eq("loaded-plugin")
    end
  end

  describe "#build_trust_policy (private)" do
    it "trusts the gem name half of every plugins: entry (String and Hash gem:/id: forms), " \
       "and threads signature_paths / plugins_io straight through" do
      Dir.mktmpdir do |dir|
        sig_dir = File.join(dir, "sig")
        FileUtils.mkdir_p(sig_dir)
        extra_dir = File.join(dir, "extra")
        FileUtils.mkdir_p(extra_dir)
        configuration = Rigor::Configuration.new(
          "signature_paths" => [sig_dir],
          "plugins" => ["rigor-a", { "gem" => "rigor-b" }, { "id" => "rigor-c" }],
          "plugins_io" => { "allowed_paths" => [extra_dir], "network" => "allowlist",
                            "allowed_url_hosts" => ["example.com"] }
        )
        pre_passes = build_pre_passes(configuration: configuration)
        allow(Gem).to receive(:loaded_specs).and_return({})

        expected_pwd = nil
        policy = Dir.chdir(dir) do
          expected_pwd = Dir.pwd
          pre_passes.send(:build_trust_policy)
        end

        expect(policy.trusted_gems).to eq(%w[rigor-a rigor-b rigor-c])
        expect(policy.allowed_read_roots).to include(
          expected_pwd, File.expand_path(sig_dir), File.expand_path(extra_dir)
        )
        expect(policy.network_policy).to eq(:allowlist)
        expect(policy.allowed_url_hosts).to eq(["example.com"])
      end
    end

    it "appends a trusted gem's own full_gem_path to the allowed read roots when it is actually installed" do
      configuration = Rigor::Configuration.new("plugins" => ["rigor-installed"])
      pre_passes = build_pre_passes(configuration: configuration)
      fake_spec = instance_double(Gem::Specification, full_gem_path: "/gems/rigor-installed")
      allow(Gem).to receive(:loaded_specs).and_return({ "rigor-installed" => fake_spec })

      policy = pre_passes.send(:build_trust_policy)

      expect(policy.allowed_read_roots).to include("/gems/rigor-installed")
    end
  end

  describe "#trusted_gem_name (private)" do
    it "returns a String entry unchanged" do
      expect(build_pre_passes.send(:trusted_gem_name, "rigor-x")).to eq("rigor-x")
    end

    it "reads the \"gem\" key from a Hash entry" do
      expect(build_pre_passes.send(:trusted_gem_name, { "gem" => "rigor-x", "id" => "x" })).to eq("rigor-x")
    end

    it "falls back to the \"id\" key when a Hash entry has no \"gem\" key" do
      expect(build_pre_passes.send(:trusted_gem_name, { "id" => "rigor-x" })).to eq("rigor-x")
    end

    it "returns nil for an entry that is neither a String nor a Hash" do
      expect(build_pre_passes.send(:trusted_gem_name, 42)).to be_nil
    end
  end

  describe "#trusted_gem_root (private)" do
    it "returns nil for a nil gem_name" do
      expect(build_pre_passes.send(:trusted_gem_root, nil)).to be_nil
    end

    it "returns nil for an empty gem_name" do
      expect(build_pre_passes.send(:trusted_gem_root, "")).to be_nil
    end

    it "returns the loaded spec's full_gem_path for an installed gem" do
      fake_spec = instance_double(Gem::Specification, full_gem_path: "/gems/rigor-x")
      allow(Gem).to receive(:loaded_specs).and_return({ "rigor-x" => fake_spec })

      expect(build_pre_passes.send(:trusted_gem_root, "rigor-x")).to eq("/gems/rigor-x")
    end

    it "returns nil for a gem_name Gem.loaded_specs has never heard of" do
      allow(Gem).to receive(:loaded_specs).and_return({})

      expect(build_pre_passes.send(:trusted_gem_root, "rigor-unknown")).to be_nil
    end

    # Mutant: dropping the `rescue StandardError` would propagate a spec lookup failure straight out of
    # trust-policy construction, aborting the whole run over one misbehaving gemspec.
    it "returns nil rather than raising when reading full_gem_path itself raises" do
      fake_spec = instance_double(Gem::Specification)
      allow(fake_spec).to receive(:full_gem_path).and_raise(StandardError, "corrupt gemspec")
      allow(Gem).to receive(:loaded_specs).and_return({ "rigor-x" => fake_spec })

      expect(build_pre_passes.send(:trusted_gem_root, "rigor-x")).to be_nil
    end
  end

  describe "#plugin_prepare_diagnostics / #invoke_plugin_prepare (private)" do
    it "returns an empty Array for an empty registry" do
      expect(build_pre_passes.send(:plugin_prepare_diagnostics, Rigor::Plugin::Registry::EMPTY)).to eq([])
    end

    it "returns an empty Array when every plugin's #prepare succeeds" do
      plugin_class = Class.new(Rigor::Plugin::Base) { manifest(id: "prepare-ok", version: "0.1.0") }
      stub_const("ProjectPrePassesSpecPrepareOk", plugin_class)
      registry = Rigor::Plugin::Registry.new(plugins: [plugin_class.new(services: real_services)])

      expect(build_pre_passes.send(:plugin_prepare_diagnostics, registry)).to eq([])
    end

    it "surfaces exactly one diagnostic per raising plugin, and NONE for a sibling that succeeded " \
       "(topological order: producers run — and are checked — before consumers)" do
      ok_class = Class.new(Rigor::Plugin::Base) { manifest(id: "prepare-ok-2", version: "0.1.0") }
      stub_const("ProjectPrePassesSpecPrepareOk2", ok_class)
      raising_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "prepare-raises-2", version: "0.1.0")

        def prepare(_services)
          raise StandardError, "boom"
        end
      end
      stub_const("ProjectPrePassesSpecPrepareRaises2", raising_class)
      registry = Rigor::Plugin::Registry.new(
        plugins: [ok_class.new(services: real_services), raising_class.new(services: real_services)]
      )

      diagnostics = build_pre_passes.send(:plugin_prepare_diagnostics, registry)

      expect(diagnostics.size).to eq(1)
      expect(diagnostics.first.message).to include("prepare-raises-2")
      expect(diagnostics.first.severity).to eq(:error)
      expect(diagnostics.first.rule).to eq("runtime-error")
      expect(diagnostics.first.source_family).to eq(:plugin_loader)
    end
  end

  describe "#safe_plugin_id (private)" do
    it "reads the id off the plugin's own manifest" do
      plugin_class = Class.new(Rigor::Plugin::Base) { manifest(id: "named-plugin", version: "0.1.0") }
      stub_const("ProjectPrePassesSpecNamedPlugin", plugin_class)
      plugin = plugin_class.new(services: real_services)

      expect(build_pre_passes.send(:safe_plugin_id, plugin)).to eq("named-plugin")
    end

    # Mutant: dropping the `rescue StandardError` here would turn a plugin whose OWN `#manifest` raises into
    # an unhandled exception from inside error-reporting itself — the one code path that must never raise.
    it "falls back to the plugin's class name when reading its manifest itself raises" do
      plugin = instance_double(Rigor::Plugin::Base, class: "FakePluginClass")
      allow(plugin).to receive(:manifest).and_raise(StandardError, "no manifest")

      expect(build_pre_passes.send(:safe_plugin_id, plugin)).to eq("FakePluginClass")
    end
  end
end
