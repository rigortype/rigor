# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "rigor/protection/discovery_seed"
require "tmpdir"
require "fileutils"

# ADR-119 WD7 — the `unpositioned_mixins` table (and `discovered_class_sources`, the reopening census the order
# reader pairs it with) must reach a per-file scope by every route a discovery index takes, and a bundle-served file
# must contribute exactly what its cold walk does. A route that dropped either would answer "every edge is
# positioned" on that route, where a reader that depends on ancestor order should decline.
RSpec.describe "unpositioned mixin edges reach every discovery seed" do
  let(:indexer) { Rigor::Inference::ScopeIndexer }

  let(:expected) { { "Gadget" => { include: ["Greeting"] }, "Helper" => { extend: ["Greeting"] } } }

  let(:sources) do
    {
      "lib/direct.rb" => "class Gadget\n  include Greeting\nend\n",
      "lib/guarded.rb" => "class Gadget\n  include Greeting if defined?(Greeting)\n  prepend Wrap\nend\n",
      "lib/mods.rb" => <<~RUBY
        module Greeting; end
        module Wrap; end
        module Helper
          def self.boot = extend(Greeting)
        end
      RUBY
    }
  end

  def with_project
    Dir.mktmpdir("rigor-unpositioned-seed-") do |dir|
      paths = sources.map do |rel, source|
        File.join(dir, rel).tap do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, source)
        end
      end
      yield dir, paths
    end
  end

  def unpositioned_of(index) = index.fetch(:def_index).fetch(:unpositioned_mixins)

  # The seed tables with the guarded file re-walked from a mutant whose edge is direct.
  def mutated_tables(paths, bundles)
    Tempfile.create(["mutant", ".rb"]) do |tmp|
      tmp.write("class Gadget\n  include Greeting\n  prepend Wrap\nend\n")
      tmp.flush
      buffer = Rigor::Analysis::BufferBinding.new(logical_path: paths[1], physical_path: tmp.path)
      Rigor::Protection::DiscoverySeed.tables_for_buffer(paths: paths, bundles: bundles, buffer: buffer)
    end
  end

  it "gives a bundle-served warm fold the table its cold walk gives, unchanged and edited" do
    with_project do |_dir, paths|
      reference = indexer.discovered_project_index_for_paths(paths)
      cold = indexer.discovered_project_index_incremental(paths, seed_bundles: {})
      warm = indexer.discovered_project_index_incremental(paths, seed_bundles: cold.fetch(:bundles))

      expect(unpositioned_of(reference)).to eq(expected)
      expect(unpositioned_of(cold)).to eq(unpositioned_of(reference))
      expect(unpositioned_of(warm)).to eq(unpositioned_of(reference))

      # Rewriting the guarded file so its edge is direct leaves the OTHER file's direct edge, and both fold
      # positioned, while the two bundle-served files keep their contribution.
      File.write(paths[1], "class Gadget\n  include Greeting\n  prepend Wrap\nend\n")
      edited_reference = indexer.discovered_project_index_for_paths(paths)
      edited_warm = indexer.discovered_project_index_incremental(paths, seed_bundles: cold.fetch(:bundles))

      expect(unpositioned_of(edited_reference)).to eq("Helper" => { extend: ["Greeting"] })
      expect(unpositioned_of(edited_warm)).to eq(unpositioned_of(edited_reference))
    end
  end

  it "reads a pre-32 bundle, which lacks the table, as carrying no unpositioned edge" do
    with_project do |_dir, paths|
      cold = indexer.discovered_project_index_incremental(paths, seed_bundles: {})
      legacy = cold.fetch(:bundles).transform_values { |bundle| bundle.except(:unpositioned_mixins) }

      warm = indexer.discovered_project_index_incremental(paths, seed_bundles: legacy)

      expect(unpositioned_of(warm)).to eq({})
    end
  end

  it "seeds a plain `check` run with the table and the class-source census, without dependency recording" do
    with_project do |dir, paths|
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new("paths" => [File.join(dir, "lib")]),
          cache_store: nil, collect_stats: false, record_dependencies: false
        )
        runner.send(:ensure_project_discovery, { files: paths })
        tables = runner.send(:project_scope_seed_tables)

        expect(tables.fetch(:unpositioned_mixins)).to eq(expected)
        expect(tables.fetch(:discovered_class_sources).fetch("Gadget").size).to eq(2)
        expect(tables).not_to have_key(:constant_sources)
      end
    end
  end

  it "seeds the protection scan's discovery index, whole-project and with a mutant buffer" do
    with_project do |_dir, paths|
      seed = Rigor::Protection::DiscoverySeed.discovery_tables(paths)
      bundles = Rigor::Protection::DiscoverySeed.bundles(paths: paths)
      expect(seed.fetch(:unpositioned_mixins)).to eq(expected)
      expect(seed.fetch(:discovered_class_sources).fetch("Gadget").size).to eq(2)
      expect(Rigor::Scope.empty.with_discovery(Rigor::Scope.empty.discovery.with(**seed))
                         .discovery.unpositioned_mixins).to eq(seed.fetch(:unpositioned_mixins))
      expect(mutated_tables(paths, bundles).fetch(:unpositioned_mixins)).to eq("Helper" => { extend: ["Greeting"] })
    end
  end
end
