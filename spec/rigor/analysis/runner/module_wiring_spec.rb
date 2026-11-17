# frozen_string_literal: true

require "spec_helper"

# The module specs (`dependency_rows_spec.rb`, `scope_seed_spec.rb`, `effect_cache_entries_spec.rb`) pin each function
# on plain data. This file pins the other half of the move: that each thin `Runner` method hands the module the right
# instance variable, in the right position. A runner is `allocate`d (as `buffer_pool_dispatcher_spec.rb` does for its
# dispatcher), the ivars a method reads hold distinguishable sentinels, and the module is asked to receive exactly
# those. Dropping `@buffer`, or swapping two same-typed arguments, fails here and nowhere else.
RSpec.describe Rigor::Analysis::Runner do
  let(:runner) { described_class.allocate }
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

  def thin(name, *args)
    runner.send(name, *args)
  end

  describe "DependencyRows" do
    let(:rows) { Rigor::Analysis::Runner::DependencyRows }

    before { set(configuration: configuration, buffer: :buffer) }

    it "root_presence_entries: the expansion's roots, `pre_eval:`, the signature root candidates" do
      expect(rows).to receive(:root_presence_entries).with(:roots, :pre_eval, candidates).and_return(:rows)

      expect(thin(:root_presence_entries, { roots: :roots })).to eq(:rows)
    end

    it "plugin_boundary_rows and producer_watch_glob_entries: the registry's plugins" do
      set(plugin_registry: instance_double(Rigor::Plugin::Registry, plugins: :plugins))
      expect(rows).to receive(:plugin_boundary_rows).with(:plugins).and_return(:boundary)
      expect(rows).to receive(:producer_watch_glob_entries).with(:plugins).and_return(:watch)

      expect([thin(:plugin_boundary_rows), thin(:producer_watch_glob_entries)]).to eq(%i[boundary watch])
    end

    it "analysis_reads_attributed?: the post rows, the pre rows, then the reads" do
      set(post_analysis_plugin_rows: :post, pre_analysis_plugin_rows: :pre, analysis_reads: :reads)
      expect(rows).to receive(:analysis_reads_attributed?).with(:post, :pre, :reads).and_return(true)

      expect(thin(:analysis_reads_attributed?)).to be(true)
    end

    it "signature_rows: the snapshot's signature paths, the core root, the candidates" do
      set(snapshots: instance_double(Rigor::Analysis::Runner::RunSnapshots, signature_paths: :sig_paths))
      expect(rows).to receive(:signature_rows).with(:sig_paths, :core_root, candidates).and_return(:rows)

      expect(thin(:signature_rows)).to eq(:rows)
    end

    it "discovery_glob_entries: the widening flag, then `paths:`" do
      set(discovery_widened: :widened)
      expect(rows).to receive(:discovery_glob_entries).with(:widened, :paths).and_return(:rows)

      expect(thin(:discovery_glob_entries)).to eq(:rows)
    end

    it "bundle_sig_glob_entries: the bundle path, then auto-detect" do
      expect(rows).to receive(:bundle_sig_glob_entries).with(:bundle_path, :auto_detect).and_return(:rows)

      expect(thin(:bundle_sig_glob_entries)).to eq(:rows)
    end

    it "unanalysed_pre_eval_entries: the files, `pre_eval:`, the buffer" do
      expect(rows).to receive(:unanalysed_pre_eval_entries).with(:files, :pre_eval, :buffer).and_return(:rows)

      expect(thin(:unanalysed_pre_eval_entries, :files)).to eq(:rows)
    end

    it "kind_entries, analyzed_file_entries: the buffer" do
      expect(rows).to receive(:kind_entries).with(:paths, :buffer).and_return(:kinds)
      expect(rows).to receive(:analyzed_file_entries).with(:expansion, :buffer).and_return(:analysed)

      expect([thin(:kind_entries, :paths), thin(:analyzed_file_entries, :expansion)]).to eq(%i[kinds analysed])
    end

    it "discovery_file_entries: the expansion, the discovery expansion, the buffer" do
      set(project_discovery_expansion: :discovery)
      expect(rows).to receive(:discovery_file_entries).with(:expansion, :discovery, :buffer).and_return(:rows)

      expect(thin(:discovery_file_entries, :expansion)).to eq(:rows)
    end

    it "template_unit_file_entries: the run's template units, then the buffer" do
      set(template_units: :units)
      expect(rows).to receive(:template_unit_file_entries).with(:units, :buffer).and_return(:rows)

      expect(thin(:template_unit_file_entries)).to eq(:rows)
    end

    it "pre_eval_file_entries: `pre_eval:`, then the buffer" do
      expect(rows).to receive(:pre_eval_file_entries).with(:pre_eval, :buffer).and_return(:rows)

      expect(thin(:pre_eval_file_entries)).to eq(:rows)
    end
  end

  describe "ScopeSeed" do
    let(:seed) { Rigor::Analysis::Runner::ScopeSeed }

    it "seed_mixin_tables: includes, prepends, extends, unpositioned, in that order" do
      set(project_discovered_includes: :includes, project_discovered_prepends: :prepends,
          project_discovered_extends: :extends, project_unpositioned_mixins: :unpositioned)
      expect(seed).to receive(:seed_mixin_tables).with(:tables, :includes, :prepends, :extends, :unpositioned)

      thin(:seed_mixin_tables, :tables)
    end

    it "seed_dependency_attribution_tables: writers, shadowers, class sources, the recording flag, constant sources" do
      set(constant_writer_index: :writers, constant_shadower_index: :shadowers,
          project_discovered_class_sources: :class_sources, record_dependencies: :recording,
          project_constant_sources: :constant_sources)
      expect(seed).to receive(:seed_dependency_attribution_tables)
        .with(:tables, :writers, :shadowers, :class_sources, :recording, :constant_sources)

      thin(:seed_dependency_attribution_tables, :tables)
    end

    it "seed_def_source_tables: instance, then singleton" do
      set(project_discovered_def_sources: :instance, project_discovered_singleton_def_sources: :singleton)
      expect(seed).to receive(:seed_def_source_tables).with(:tables, :instance, :singleton)

      thin(:seed_def_source_tables, :tables)
    end

    it "seed_member_layout_tables: Data, then Struct" do
      set(project_data_member_layouts: :data, project_struct_member_layouts: :struct)
      expect(seed).to receive(:seed_member_layout_tables).with(:tables, :data, :struct)

      thin(:seed_member_layout_tables, :tables)
    end

    it "merged_seed_constants: `pre_eval:` constants, literal values, the seed, constant sources, the listed set" do
      set(project_pre_eval_constants: :pre_eval_constants, project_constant_values: :values,
          discovery_seed: :seed, project_constant_sources: :sources, pre_eval_path_set: :listed)
      expect(seed).to receive(:merged_seed_constants)
        .with(:pre_eval_constants, :values, :seed, :sources, :listed).and_return(:merged)

      expect(thin(:merged_seed_constants)).to eq(:merged)
    end
  end

  describe "EffectCacheEntries" do
    let(:entries) { Rigor::Analysis::Runner::EffectCacheEntries }

    before { set(cache_store: :store) }

    it "peek_effect_summary, peek_effect_collections: the cache store, then the descriptor" do
      expect(entries).to receive(:peek_effect_summary).with(:store, :descriptor).and_return(:summary)
      expect(entries).to receive(:peek_effect_collections).with(:store, :descriptor).and_return(:collections)

      expect([thin(:peek_effect_summary, :descriptor), thin(:peek_effect_collections, :descriptor)])
        .to eq(%i[summary collections])
    end

    it "write_effect_entry: the cache store, then the producer, descriptor, payload and dependencies" do
      expect(entries).to receive(:write_effect_entry).with(:store, :producer, :descriptor, :payload, :deps)

      thin(:write_effect_entry, :producer, :descriptor, :payload, :deps)
    end

    it "storable_effect_table: the effect table, then the collections" do
      set(effect_table: :table)
      expect(entries).to receive(:storable_effect_table).with(:table, :collections).and_return(:storable)

      expect(thin(:storable_effect_table, :collections)).to eq(:storable)
    end
  end
end
