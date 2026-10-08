# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "tmpdir"
require "fileutils"
require "rigor/protection/discovery_seed"

# The `extend` edge a singleton reads (`discovered_extends`) must reach every route that seeds a per-file scope from
# a discovery index: the whole-walk seed the coverage and protection paths build, the bundle-folded per-mutant seed,
# and the Runner's own seed that `rigor check` already carries. A route that drops the table answers "no mixin" for
# `Child.helper`, where Ruby would find `Helpers`.
RSpec.describe Rigor::Protection::DiscoverySeed do
  let(:sources) do
    {
      "a.rb" => "module Helpers; def h = 1; end\n",
      "b.rb" => "class Base; extend Helpers; end\n",
      "c.rb" => "class Child < Base; end\n"
    }
  end

  let(:expected_extends) { { "Base" => ["Helpers"] } }

  def with_project
    Dir.mktmpdir("rigor-discovery-seed-extends-") do |dir|
      paths = sources.map do |rel, source|
        File.join(dir, rel).tap { |path| File.write(path, source) }
      end
      yield paths
    end
  end

  def scope_with(tables)
    base = Rigor::Scope.empty
    base.with_discovery(base.discovery.with(**tables))
  end

  def runner_seed_tables(paths)
    configuration = Rigor::Configuration.new("paths" => paths)
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    pre_passes = Rigor::Analysis::Runner::ProjectPrePasses.new(
      configuration: configuration, cache_store: nil, buffer: nil, plugin_requirer: nil, pool_mode: -> { false }
    )
    index = Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths(paths)
    runner.send(:apply_discovery_result, pre_passes.build_discovery(index))
    runner.send(:project_scope_seed_tables)
  end

  it "carries the extend edge in the whole-walk seed" do
    with_project do |paths|
      tables = described_class.discovery_tables(paths)

      expect(tables[:discovered_extends]).to eq(expected_extends)
    end
  end

  it "carries the same extend edge in the bundle-folded seed for a buffer that leaves the file unchanged" do
    with_project do |paths|
      bundles = described_class.bundles(paths: paths)
      Tempfile.create(["unchanged", ".rb"]) do |tmp|
        tmp.write(sources.fetch("b.rb"))
        tmp.flush
        buffer = Rigor::Analysis::BufferBinding.new(logical_path: paths[1], physical_path: tmp.path)
        tables = described_class.tables_for_buffer(paths: paths, bundles: bundles, buffer: buffer)

        expect(tables[:discovered_extends]).to eq(expected_extends)
      end
    end
  end

  it "reads the singleton extend through a scope seeded from the whole-walk tables" do
    with_project do |paths|
      scope = scope_with(described_class.discovery_tables(paths))

      expect(scope.singleton_extends_of("Child")).to include("Helpers")
    end
  end

  it "seeds the Runner with the same extend table as the protection seed" do
    with_project do |paths|
      seed = described_class.discovery_tables(paths)

      expect(runner_seed_tables(paths)[:discovered_extends]).to eq(seed[:discovered_extends])
    end
  end
end
