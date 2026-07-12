# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/cache/store"

# Warm-path structural-waste slice 1: the two whole-project cross-file discovery
# parse passes (`ScopeIndexer.discovered_classes_for_paths` +
# `discovered_def_index_for_paths`) are deferred out of the eager pre-pass and
# run only on the analysis (cache-miss / non-cacheable) path, so a warm cache HIT
# never re-parses the project. The recording / subset modes (ADR-46) still force
# the build eagerly.
RSpec.describe Rigor::Analysis::Runner do
  # A two-file project: `b.rb` calls a method defined on a class declared in
  # `a.rb`, so cross-file discovery is exercised (not a per-file-only fixture).
  def write_project(dir)
    lib = File.join(dir, "lib")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "a.rb"), <<~RUBY)
      class Widget
        def price
          10
        end
      end
    RUBY
    File.write(File.join(lib, "b.rb"), <<~RUBY)
      class Shop
        def total
          Widget.new.price
        end
      end
    RUBY
    lib
  end

  def build_runner(dir, cache_root, **)
    described_class.new(
      configuration: Rigor::Configuration.new("paths" => [File.join(dir, "lib")]),
      cache_store: cache_root && Rigor::Cache::Store.new(root: cache_root),
      collect_stats: false, **
    )
  end

  it "runs the two discovery passes on a cold miss and SKIPS them on the warm hit" do
    Dir.mktmpdir("rigor-lazy-prepass-hit-") do |dir|
      write_project(dir)
      cache_root = File.join(dir, ".rigor", "cache")

      allow(Rigor::Inference::ScopeIndexer).to receive(:discovered_classes_for_paths).and_call_original
      allow(Rigor::Inference::ScopeIndexer).to receive(:discovered_def_index_for_paths).and_call_original

      cold = Dir.chdir(dir) { build_runner(dir, cache_root).run }
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_classes_for_paths).once
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_def_index_for_paths).once

      # A fresh Store at the same root forces a real disk hit (not the in-memory memo).
      warm_runner = build_runner(dir, cache_root)
      warm = Dir.chdir(dir) { warm_runner.run }

      # The warm run served from cache added NO further discovery parses.
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_classes_for_paths).once
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_def_index_for_paths).once
      expect(warm_runner.send(:run_result_cacheable?)).to be(true)
      # Byte-identical diagnostics warm vs cold.
      expect(warm.diagnostics.map(&:to_h)).to eq(cold.diagnostics.map(&:to_h))
    end
  end

  it "still runs discovery when the cache is disabled (--no-cache / cache_store nil)" do
    Dir.mktmpdir("rigor-lazy-prepass-nocache-") do |dir|
      write_project(dir)
      allow(Rigor::Inference::ScopeIndexer).to receive(:discovered_classes_for_paths).and_call_original

      Dir.chdir(dir) { build_runner(dir, nil).run }

      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_classes_for_paths).once
    end
  end

  it "forces discovery eagerly under record_dependencies even when the run is cache-hittable" do
    Dir.mktmpdir("rigor-lazy-prepass-record-") do |dir|
      write_project(dir)
      cache_root = File.join(dir, ".rigor", "cache")

      # Prime the run-diagnostics cache so a second run WOULD hit.
      Dir.chdir(dir) { build_runner(dir, cache_root).run }

      allow(Rigor::Inference::ScopeIndexer).to receive(:discovered_def_index_for_paths).and_call_original
      recording = build_runner(dir, cache_root, record_dependencies: true)
      Dir.chdir(dir) { recording.run }

      # Eager force (the recording mode reads the discovery tables via `symbol_fingerprints` /
      # `class_declarations` OUTSIDE the analysis assembly), so discovery ran even on the hittable run.
      expect(Rigor::Inference::ScopeIndexer).to have_received(:discovered_def_index_for_paths).once
      expect(recording.symbol_fingerprints).not_to be_empty
      expect(recording.class_declarations).not_to be_empty
    end
  end

  it "leaves the prebuilt (LSP) path seeding an empty project scope (discovery never forced)" do
    Dir.mktmpdir("rigor-lazy-prepass-prebuilt-") do |dir|
      write_project(dir)
      config = Rigor::Configuration.new("paths" => [File.join(dir, "lib")])
      scan = Dir.chdir(dir) do
        described_class.new(configuration: config, cache_store: nil, collect_stats: false)
                       .prepare_project_scan
      end

      allow(Rigor::Inference::ScopeIndexer).to receive(:discovered_classes_for_paths).and_call_original
      allow(Rigor::Inference::ScopeIndexer).to receive(:discovered_def_index_for_paths).and_call_original

      runner = described_class.new(
        configuration: config, cache_store: nil, collect_stats: false, prebuilt: scan
      )
      Dir.chdir(dir) { runner.run }

      # The prebuilt path deliberately seeds an empty project scope, so the deferred discovery is a no-op.
      expect(Rigor::Inference::ScopeIndexer).not_to have_received(:discovered_classes_for_paths)
      expect(Rigor::Inference::ScopeIndexer).not_to have_received(:discovered_def_index_for_paths)
    end
  end
end
