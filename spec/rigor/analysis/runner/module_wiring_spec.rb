# frozen_string_literal: true

require "spec_helper"

# The module specs (`dependency_rows_spec.rb`, `scope_seed_spec.rb`, `effect_cache_entries_spec.rb`) pin each function
# on plain data. This file pins the other half of the move: that each thin `Runner` method hands the module the right
# instance variable, in the right position. A runner is `allocate`d (as `buffer_pool_dispatcher_spec.rb` does for its
# dispatcher), the ivars a method reads hold distinguishable sentinels, and the module is asked to have received exactly
# those. Dropping `@buffer`, or swapping two same-typed arguments, fails here and nowhere else.
RSpec.describe "Runner thin callers into the moved modules" do
  let(:runner) { Rigor::Analysis::Runner.allocate }
  let(:configuration) do
    instance_double(
      Rigor::Configuration,
      pre_eval: :pre_eval, paths: :paths, core_root: :core_root, bundler_bundle_path: :bundle_path,
      bundler_auto_detect: :auto_detect, signature_paths: ["sig_x"]
    )
  end
  let(:candidates) { Rigor::Environment.project_signature_root_candidates(["sig_x"]) }

  def set(**ivars)
    ivars.each { |name, value| runner.instance_variable_set(:"@#{name}", value) }
  end

  # Calls the thin method `via` with `with`, and asserts that `owner.name` received `expected` and that its answer
  # came back.
  def expect_wired(owner, name, *expected, via: name, with: [])
    allow(owner).to receive(name).and_return(:answer)
    expect(runner.send(via, *with)).to eq(:answer)
    expect(owner).to have_received(name).with(*expected)
  end

  describe "DependencyRows" do
    let(:rows) { Rigor::Analysis::Runner::DependencyRows }

    before { set(configuration: configuration, buffer: :buffer) }

    it "root_presence_entries: the expansion's roots, `pre_eval:`, the signature root candidates" do
      expect_wired(rows, :root_presence_entries, :roots, :pre_eval, candidates, with: [{ roots: :roots }])
    end

    it "plugin_boundary_rows and producer_watch_glob_entries: the registry's plugins" do
      set(plugin_registry: instance_double(Rigor::Plugin::Registry, plugins: :plugins))

      expect_wired(rows, :plugin_boundary_rows, :plugins)
      expect_wired(rows, :producer_watch_glob_entries, :plugins)
    end

    it "analysis_reads_attributed?: the post rows, the pre rows, then the reads" do
      set(post_analysis_plugin_rows: :post, pre_analysis_plugin_rows: :pre, analysis_reads: :reads)

      expect_wired(rows, :analysis_reads_attributed?, :post, :pre, :reads)
    end

    it "signature_rows: the snapshot's signature paths, the core root, the candidates" do
      set(snapshots: instance_double(Rigor::Analysis::Runner::RunSnapshots, signature_paths: :sig_paths))

      expect_wired(rows, :signature_rows, :sig_paths, :core_root, candidates)
    end

    it "discovery_glob_entries: the widening flag, then `paths:`" do
      set(discovery_widened: :widened)

      expect_wired(rows, :discovery_glob_entries, :widened, :paths)
    end

    it "bundle_sig_glob_entries: the bundle path, then auto-detect" do
      expect_wired(rows, :bundle_sig_glob_entries, :bundle_path, :auto_detect)
    end

    it "unanalysed_pre_eval_entries: the files, `pre_eval:`, the buffer" do
      expect_wired(rows, :unanalysed_pre_eval_entries, :files, :pre_eval, :buffer, with: [:files])
    end

    it "kind_entries: the paths, then the buffer" do
      expect_wired(rows, :kind_entries, :paths, :buffer, with: [:paths])
    end

    it "analyzed_file_entries: the expansion, then the buffer" do
      expect_wired(rows, :analyzed_file_entries, :expansion, :buffer, with: [:expansion])
    end

    it "discovery_file_entries: the expansion, the discovery expansion, the buffer" do
      set(project_discovery_expansion: :discovery)

      expect_wired(rows, :discovery_file_entries, :expansion, :discovery, :buffer, with: [:expansion])
    end

    it "template_unit_file_entries: the run's template units, then the buffer" do
      set(template_units: :units)

      expect_wired(rows, :template_unit_file_entries, :units, :buffer)
    end

    it "pre_eval_file_entries: `pre_eval:`, then the buffer" do
      expect_wired(rows, :pre_eval_file_entries, :pre_eval, :buffer)
    end
  end

  describe "ScopeSeed" do
    let(:seed) { Rigor::Analysis::Runner::ScopeSeed }

    it "seed_mixin_tables: includes, prepends, extends, unpositioned, in that order" do
      set(project_discovered_includes: :includes, project_discovered_prepends: :prepends,
          project_discovered_extends: :extends, project_unpositioned_mixins: :unpositioned)

      expect_wired(seed, :seed_mixin_tables, :tables, :includes, :prepends, :extends, :unpositioned, with: [:tables])
    end

    it "seed_dependency_attribution_tables: writers, shadowers, class sources, the recording flag, constant sources" do
      set(constant_writer_index: :writers, constant_shadower_index: :shadowers,
          project_discovered_class_sources: :class_sources, record_dependencies: :recording,
          project_constant_sources: :constant_sources)

      expect_wired(seed, :seed_dependency_attribution_tables, :tables, :writers, :shadowers, :class_sources, :recording,
                   :constant_sources, with: [:tables])
    end

    it "seed_def_source_tables: instance, then singleton" do
      set(project_discovered_def_sources: :instance, project_discovered_singleton_def_sources: :singleton)

      expect_wired(seed, :seed_def_source_tables, :tables, :instance, :singleton, with: [:tables])
    end

    it "seed_member_layout_tables: Data, then Struct" do
      set(project_data_member_layouts: :data, project_struct_member_layouts: :struct)

      expect_wired(seed, :seed_member_layout_tables, :tables, :data, :struct, with: [:tables])
    end

    it "merged_seed_constants: `pre_eval:` constants, literal values, the seed, constant sources, the listed set" do
      set(project_pre_eval_constants: :pre_eval_constants, project_constant_values: :values,
          discovery_seed: :seed, project_constant_sources: :sources, pre_eval_path_set: :listed)

      expect_wired(seed, :merged_seed_constants, :pre_eval_constants, :values, :seed, :sources, :listed)
    end
  end

  describe "EffectCacheEntries" do
    let(:entries) { Rigor::Analysis::Runner::EffectCacheEntries }

    before { set(cache_store: :store) }

    it "peek_effect_summary: the cache store, then the descriptor" do
      expect_wired(entries, :peek_effect_summary, :store, :descriptor, with: [:descriptor])
    end

    it "peek_effect_collections: the cache store, then the descriptor" do
      expect_wired(entries, :peek_effect_collections, :store, :descriptor, with: [:descriptor])
    end

    it "write_effect_entry: the cache store, then the producer, descriptor, payload and dependencies" do
      expect_wired(entries, :write_effect_entry, :store, :producer, :descriptor, :payload, :deps,
                   with: %i[producer descriptor payload deps])
    end

    it "storable_effect_table: the effect table, then the collections" do
      set(effect_table: :table)

      expect_wired(entries, :storable_effect_table, :table, :collections, with: [:collections])
    end
  end
end
