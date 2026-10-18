# frozen_string_literal: true

require "spec_helper"
require "rigor/protection/discovery_seed"
require "tmpdir"
require "fileutils"

# Issue #1614 — the seed paths that type a project without a `check` run ({Rigor::Protection::DiscoverySeed}, read by
# the protection scan and `rigor coverage`, and the ADR-67 {Rigor::Inference::ParameterInferenceCollector}) hand their
# per-file scopes the tables `Runner#project_scope_seed_tables` does, from the one list
# {Rigor::Inference::ProjectSeedTables} keeps. A table the runner seeds and they do not must be listed in
# `ProjectSeedTables::NOT_SEEDED` with its reason.
RSpec.describe Rigor::Inference::ProjectSeedTables do
  let(:sources) do
    {
      "lib/base.rb" => <<~RUBY,
        module Outer
          class Base
            def greet(name) = name
            def self.build = new
            private def secret = 1
          end
        end
      RUBY
      "lib/kid.rb" => <<~RUBY,
        module Outer
          class Kid < Base
            include Comparable
            prepend Wrap
            extend Helpers
            include Extra if defined?(Extra)
            def <=>(other) = 0
          end
        end
      RUBY
      "lib/mods.rb" => <<~RUBY,
        module Wrap; end
        module Helpers
          def helper = 1
        end
        module Extra; end
        LIMIT = 30
        Point = Struct.new(:x, :y)
        Coord = Data.define(:lat, :lng)
        module Tweaks
          refine String do
            def shout = upcase
          end
        end
        alias $new_out $stdout
      RUBY
      "lib/svc.rb" => "class Svc\n  def run(n) = n\nend\n",
      "lib/caller.rb" => "class Caller\n  def go = Svc.new.run(LIMIT)\n  def peek = LIMIT\nend\n"
    }
  end

  # The members no seed carries: `ScopeIndexer.index` builds each for the file it indexes, or reads it lazily off
  # that file's tree. Listed so a new member fails the completeness example until it is seeded or listed here.
  let(:per_file_members) do
    %i[
      declared_types class_ivars class_cvars program_globals program_global_seeds local_constant_names
      published_constant_alias_names published_constant_ivars patched_line_readers clears_last_status
      defines_case_equality implicit_self_evidence in_effect_refinements
    ]
  end

  # The tables whose values hold the def nodes of one walk, which a second walk parses afresh: compared by shape.
  let(:node_tables) { %i[discovered_def_nodes discovered_singleton_def_nodes discovered_def_nestings] }

  def with_project
    Dir.mktmpdir("rigor-seed-parity-") do |dir|
      paths = sources.map do |rel, source|
        File.join(dir, rel).tap do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, source)
        end
      end
      Dir.chdir(dir) { yield paths }
    end
  end

  def runner_seed(paths)
    runner = Rigor::Analysis::Runner.new(
      configuration: Rigor::Configuration.new("paths" => ["lib"]),
      cache_store: nil, collect_stats: false, record_dependencies: false
    )
    runner.send(:ensure_project_discovery, { files: paths })
    runner.send(:project_scope_seed_tables)
  end

  def collector_seed(paths)
    Rigor::Inference::ParameterInferenceCollector
      .new(files: paths, environment: Rigor::Environment.default)
      .send(:discovery_seed_tables)
  end

  def filled(tables) = tables.reject { |_, table| table.respond_to?(:empty?) && table.empty? }.keys

  def shape(name, table)
    return table unless node_tables.include?(name)
    return table.size if name == :discovered_def_nestings

    table.transform_values(&:keys)
  end

  it "builds a project that fills every table the runner seeds on a plain check run" do
    with_project do |paths|
      seeded = filled(runner_seed(paths))
      unseeded = Rigor::Scope::DiscoveryIndex.members - seeded - described_class::NOT_SEEDED.keys -
                 Rigor::Scope::DiscoveryIndex::SIBLINGS.values

      expect(unseeded).to match_array(per_file_members)
      expect(per_file_members & runner_seed(paths).keys).to be_empty
    end
  end

  it "gives a reason for every table it leaves out" do
    expect(described_class::NOT_SEEDED.values).to all(be_a(String).and(satisfy { |reason| !reason.strip.empty? }))
  end

  {
    "Protection::DiscoverySeed" => ->(paths, _spec) { Rigor::Protection::DiscoverySeed.discovery_tables(paths) },
    "ParameterInferenceCollector" => ->(paths, spec) { spec.collector_seed(paths) }
  }.each do |path_name, build|
    it "seeds through #{path_name} every table the runner seeds, with the runner's contents" do
      with_project do |paths|
        runner = runner_seed(paths)
        seed = build.call(paths, self)

        expect(filled(runner) - filled(seed)).to be_empty
        expect(filled(seed) - filled(runner)).to be_empty
        filled(runner).each do |name|
          expect(shape(name, seed.fetch(name))).to eq(shape(name, runner.fetch(name))), name.to_s
        end
      end
    end
  end

  it "types a constant another file writes the way check does, under the protection and coverage seed" do
    with_project do |paths|
      seed = Rigor::Protection::DiscoverySeed.discovery_tables(paths)
      base = Rigor::Scope.empty(environment: Rigor::Environment.default)
      scope = base.with_discovery(base.discovery.with(**seed))
      path = paths.find { |p| p.end_with?("caller.rb") }
      ast = Prism.parse_file(path).value
      index = Rigor::Inference::ScopeIndexer.index(ast, default_scope: scope.with_source_path(path))
      reads = []
      Rigor::Source::NodeWalker.each(ast) { |node| reads << node if node.is_a?(Prism::ConstantReadNode) }
      read = reads.find { |node| node.name == :LIMIT }

      expect(index[read].type_of(read).describe).to eq("30")
    end
  end

  it "infers a parameter whose call site passes a constant another file writes" do
    with_project do |paths|
      table = Rigor::Inference::ParameterInferenceCollector.collect(
        files: paths, environment: Rigor::Environment.default, max_rounds: 1
      )

      expect(table.dig(["Svc", :run, :instance], :n)&.describe).to eq("Integer")
    end
  end
end
