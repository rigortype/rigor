# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/runner"
require "rigor/analysis/worker_session"
require "rigor/configuration"
require "rigor/protection/discovery_seed"

# ADR-119 WD1 — a `DiscoveryIndex` member that may admit a `possible` or `contested` fact travels with its sibling
# (`DiscoveryIndex::SIBLINGS`) through every copy path, and a pair is dropped only when BOTH halves are empty.
#
# No producer fills a sibling yet, so each example INJECTS non-empty siblings at the head of its path and asserts they
# arrive, and runs the same path with the siblings empty (a pair is dropped when both halves are empty, kept when
# either is not). A copy path that rebuilt members one at a time would strand a non-empty sibling here. The paths:
#
# 1. the bundle codec — build, Marshal, `bundle_to_file_index`, fold, finalize
# 2. def-index, `ProjectPrePasses::Discovery`, the Runner, `project_scope_seed_tables`, the per-file scope
# 3. `Protection::DiscoverySeed.seed_tables`, then `with(**)`
# 4. the `WorkerSession` seed, Marshal-crossed
# 5. the `ParameterInferenceCollector` tables
# 6. the per-file `ScopeIndexer.index` over a seeded default scope
# 7. a compact-header rename
RSpec.describe "DiscoveryIndex sibling pairing (ADR-119 WD1)" do
  let(:index_class) { Rigor::Scope::DiscoveryIndex }
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:siblings) { index_class::SIBLINGS }

  # One non-empty value per sibling, over names the fixture project defines.
  let(:injected) do
    {
      possible_discovered_methods: { "Gadget" => { ghost: :instance } },
      possible_discovered_deferred_ranges: { "lib/gadget.rb" => [[0, 1, :ghost, :instance, "Gadget"]] },
      contested_discovered_def_nodes: Set[["Gadget", :run]],
      contested_discovered_singleton_def_nodes: Set[["Gadget", :build]],
      contested_discovered_method_visibilities: Set[["Gadget", :run]],
      contested_discovered_parameter_envelopes: Set[["Gadget", %i[instance run]]]
    }
  end

  let(:project) do
    {
      "lib/gadget.rb" => "class Gadget\n  def run(arg) = arg\n  def self.build = new\nend\n",
      "lib/gadget_more.rb" => "class Gadget\n  def stop; end\nend\n"
    }
  end

  # A project that declares no def at all. Its `deferred_ranges` and `parameter_envelopes` are never truly empty (a
  # file row, the project-wide key), so only these four paired members are.
  let(:emptied_members) do
    %i[discovered_methods discovered_def_nodes discovered_singleton_def_nodes discovered_method_visibilities]
  end
  let(:bare_project) { { "lib/bare.rb" => "x = 1\n" } }

  around do |example|
    Dir.mktmpdir("rigor-sibling-pairing-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write_project(files)
    files.map do |rel, source|
      FileUtils.mkdir_p(File.dirname(rel))
      File.write(rel, source)
      rel
    end
  end

  def cold_index(files)
    indexer.discovered_project_index_incremental(write_project(files), seed_bundles: {})
  end

  # `index` with its def-index siblings replaced.
  def with_siblings(index, tables)
    index.merge(def_index: index.fetch(:def_index).merge(siblings: tables))
  end

  def empty_siblings = index_class.empty_siblings

  def scope_for(tables)
    base = Rigor::Scope.empty
    base.with_discovery(base.discovery.with(**tables))
  end

  def sibling_readers(scope)
    siblings.values.to_h { |sibling| [sibling, scope.discovery.public_send(sibling)] }
  end

  def pair_names(members)
    members + siblings.values_at(*members)
  end

  def configuration(paths)
    Rigor::Configuration.new("paths" => paths)
  end

  def runner_seed(index, paths)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(paths), cache_store: nil)
    pre_passes = Rigor::Analysis::Runner::ProjectPrePasses.new(
      configuration: configuration(paths), cache_store: nil, buffer: nil, plugin_requirer: nil, pool_mode: -> { false }
    )
    runner.send(:apply_discovery_result, pre_passes.build_discovery(index))
    runner
  end

  # rubocop:disable RSpec/MultipleMemoizedHelpers -- one fixture project per path, shared by every example
  describe "DiscoveryIndex#with" do
    let(:empty) { index_class::EMPTY }

    it "returns the receiver when nothing changes" do
      expect(empty.with).to be(empty)
    end

    it "accepts a member and its sibling together" do
      index = empty.with(discovered_methods: { "A" => { x: :instance } },
                         possible_discovered_methods: { "A" => { x: :instance } })

      expect(index.possible_discovered_methods).to eq("A" => { x: :instance })
    end

    it "raises when a member arrives without its sibling" do
      siblings.each do |member, sibling|
        expect { empty.with(member => empty.public_send(member)) }
          .to raise_error(ArgumentError, /#{member} and #{sibling} change together/)
      end
    end

    it "raises when a sibling arrives without its member" do
      siblings.each do |member, sibling|
        expect { empty.with(sibling => empty.public_send(sibling)) }
          .to raise_error(ArgumentError, /#{sibling} and #{member} change together/)
      end
    end

    it "leaves the members without a sibling free to change alone" do
      expect(empty.with(discovered_def_sources: {}).discovered_def_sources).to eq({})
    end
  end

  describe "DiscoveryIndex.compact_pairs" do
    it "drops a pair only when both halves are empty" do
      tables = { discovered_methods: {}, possible_discovered_methods: nil, discovered_def_nodes: { "A" => {} },
                 contested_discovered_def_nodes: Set.new, discovered_classes: {} }

      expect(index_class.compact_pairs(tables).keys)
        .to eq(%i[discovered_def_nodes contested_discovered_def_nodes discovered_classes])
    end

    it "keeps a pair whose member is empty and whose sibling is not, and completes a half pair" do
      kept = index_class.compact_pairs(discovered_methods: {}, possible_discovered_methods: { "A" => { x: :instance } })
      completed = index_class.compact_pairs(discovered_def_nodes: { "A" => {} })

      expect(kept).to eq(discovered_methods: {}, possible_discovered_methods: { "A" => { x: :instance } })
      expect(completed).to eq(discovered_def_nodes: { "A" => {} }, contested_discovered_def_nodes: Set.new)
    end

    it "passes an entry outside every pair through unchanged" do
      expect(index_class.compact_pairs(discovered_classes: {}, run_generation: :token))
        .to eq(discovered_classes: {}, run_generation: :token)
    end
  end

  describe "the bundle codec (path 1)" do
    def crossed(bundles)
      Marshal.load(Marshal.dump(bundles))
    end

    it "folds non-empty siblings across files, through Marshal, into the finalized def-index" do
      cold = cold_index(project)
      first, second = cold.fetch(:bundles).keys
      bundles = cold.fetch(:bundles).dup
      bundles[first] = bundles.fetch(first).merge(siblings: injected)
      bundles[second] = bundles.fetch(second).merge(
        siblings: empty_siblings.merge(possible_discovered_methods: { "Gadget" => { ghost: :singleton } })
      )

      warm = indexer.discovered_project_index_incremental(project.keys, seed_bundles: crossed(bundles))

      expect(warm.fetch(:def_index).fetch(:siblings))
        .to eq(injected.merge(possible_discovered_methods: { "Gadget" => { ghost: :both } }))
      expect(warm.fetch(:bundles).fetch(first).fetch(:siblings)).to eq(injected)
    end

    it "builds a bundle from a live file index that holds non-empty siblings, and reads it back" do
      path = write_project(project).first
      file_index = indexer.build_file_index(path, Prism.parse(File.read(path), filepath: path).value)
                          .merge(siblings: injected)

      bundle = indexer.build_seed_bundle(file_index, {}, "digest", "fingerprint")

      expect(bundle.fetch(:siblings)).to eq(injected)
      expect(indexer.bundle_to_file_index(crossed(bundle), path).fetch(:siblings)).to eq(injected)
    end

    it "carries empty siblings as empty" do
      cold = cold_index(project)
      warm = indexer.discovered_project_index_incremental(project.keys, seed_bundles: crossed(cold.fetch(:bundles)))

      expect(cold.fetch(:def_index).fetch(:siblings)).to eq(empty_siblings)
      expect(warm.fetch(:def_index).fetch(:siblings)).to eq(empty_siblings)
      expect(cold.fetch(:bundles).values.map { |bundle| bundle.fetch(:siblings) }).to all(eq(empty_siblings))
    end

    it "reads a bundle that lacks the key as carrying no sibling" do
      cold = cold_index(project)
      legacy = cold.fetch(:bundles).transform_values { |bundle| bundle.except(:siblings) }

      warm = indexer.discovered_project_index_incremental(project.keys, seed_bundles: legacy)

      expect(warm.fetch(:def_index).fetch(:siblings)).to eq(empty_siblings)
    end

    it "freezes the finalized siblings" do
      siblings_table = cold_index(project).fetch(:def_index).fetch(:siblings)

      expect(siblings_table).to be_frozen
      expect(siblings_table.values).to all(be_frozen)
    end
  end

  describe "def-index to the per-file scope through the Runner (path 2)" do
    it "seeds each non-empty sibling beside its member" do
      index = with_siblings(cold_index(project), injected)
      runner = runner_seed(index, project.keys)

      tables = runner.send(:project_scope_seed_tables)
      scope = runner.send(:seed_project_scope, Rigor::Scope.empty)

      injected.each { |sibling, value| expect(tables.fetch(sibling)).to eq(value) }
      siblings.each_key { |member| expect(tables).to have_key(member) }
      expect(sibling_readers(scope)).to eq(injected)
    end

    it "seeds an empty sibling with its non-empty member and drops a pair empty on both sides" do
      tables = runner_seed(cold_index(project), project.keys).send(:project_scope_seed_tables)
      bare = runner_seed(cold_index(bare_project), bare_project.keys).send(:project_scope_seed_tables)

      siblings.each { |member, sibling| expect(tables.fetch(sibling)).to be_empty if tables.key?(member) }
      expect(tables.fetch(:discovered_def_nodes)).not_to be_empty
      expect(tables.fetch(:contested_discovered_def_nodes)).to be_empty
      expect(bare.keys & pair_names(emptied_members)).to eq([])
    end

    it "keeps a non-empty sibling whose member is empty" do
      index = with_siblings(cold_index(bare_project), injected)
      tables = runner_seed(index, bare_project.keys).send(:project_scope_seed_tables)

      emptied_members.each do |member|
        sibling = siblings.fetch(member)
        expect(tables).to include(member => be_empty, sibling => injected.fetch(sibling))
      end
    end

    it "completes the half pair a discovery_seed base brings in" do
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration(project.keys), cache_store: nil,
        discovery_seed: { discovered_methods: { "A" => {} } }
      )

      tables = runner.send(:project_scope_seed_tables)

      expect(tables).to include(discovered_methods: { "A" => {} }, possible_discovered_methods: {})
    end
  end

  describe "DiscoverySeed.seed_tables then with(**) (path 3)" do
    it "keeps every non-empty sibling beside its member" do
      tables = Rigor::Protection::DiscoverySeed.seed_tables(with_siblings(cold_index(project), injected))

      expect(sibling_readers(scope_for(tables))).to eq(injected)
      siblings.each_key { |member| expect(tables).to have_key(member) }
    end

    it "keeps a non-empty sibling whose member is empty, and drops a pair empty on both sides" do
      stranded = Rigor::Protection::DiscoverySeed.seed_tables(with_siblings(cold_index(bare_project), injected))
      bare = Rigor::Protection::DiscoverySeed.seed_tables(cold_index(bare_project))

      expect(sibling_readers(scope_for(stranded))).to eq(injected)
      expect(bare.keys & pair_names(emptied_members)).to eq([])
    end

    it "pairs an empty sibling with its non-empty member" do
      tables = Rigor::Protection::DiscoverySeed.seed_tables(cold_index(project))

      expect(tables).to include(contested_discovered_def_nodes: be_empty, possible_discovered_methods: be_empty)
    end
  end

  describe "the WorkerSession seed, Marshal-crossed (path 4)" do
    def session_scope(seed)
      session = Rigor::Analysis::WorkerSession.new(
        configuration: configuration(project.keys), cache_store: nil,
        project_scope_seed: Marshal.load(Marshal.dump(seed))
      )
      session.send(:seed_project_scope, Rigor::Scope.empty)
    end

    it "gives a per-file scope the siblings the Runner seeded" do
      runner = runner_seed(with_siblings(cold_index(project), injected), project.keys)

      expect(sibling_readers(session_scope(runner.send(:project_scope_seed_tables)))).to eq(injected)
    end

    it "gives a per-file scope empty siblings when none were seeded" do
      runner = runner_seed(cold_index(project), project.keys)

      expect(sibling_readers(session_scope(runner.send(:project_scope_seed_tables)))).to eq(empty_siblings)
    end
  end

  describe "the ParameterInferenceCollector tables (path 5)" do
    def collector_scope(index)
      collector = Rigor::Inference::ParameterInferenceCollector.new(
        files: project.keys, environment: Rigor::Environment.default
      )
      allow(indexer).to receive_messages(discovered_def_index_for_paths: index.fetch(:def_index),
                                         discovered_classes_for_paths: index.fetch(:classes))
      collector.send(:build_seed_scope, collector.send(:discovery_seed_tables), {})
    end

    it "seeds the siblings of the members it carries" do
      scope = collector_scope(with_siblings(cold_index(project), injected))
      carried = injected.slice(:possible_discovered_methods, :possible_discovered_deferred_ranges,
                               :contested_discovered_def_nodes, :contested_discovered_singleton_def_nodes,
                               :contested_discovered_method_visibilities)

      expect(sibling_readers(scope)).to include(carried)
    end

    it "pairs an empty sibling with its non-empty member" do
      scope = collector_scope(cold_index(project))

      expect(scope.discovery.discovered_def_nodes).not_to be_empty
      expect(sibling_readers(scope)).to eq(empty_siblings)
    end
  end

  describe "the per-file ScopeIndexer.index over a seeded default scope (path 6)" do
    def indexed_discovery(tables, source = "class Gadget\n  def run(arg) = arg\nend\n")
      root = Prism.parse(source, filepath: "lib/gadget.rb").value
      default = scope_for(tables).with_source_path("lib/gadget.rb")
      indexer.index(root, default_scope: default).fetch(root).discovery
    end

    it "carries every seeded sibling through the file's own member rebuilds" do
      tables = Rigor::Protection::DiscoverySeed.seed_tables(with_siblings(cold_index(project), injected))

      discovery = indexed_discovery(tables)

      expect(siblings.values.to_h { |sibling| [sibling, discovery.public_send(sibling)] }).to eq(injected)
    end

    it "adds the siblings of a conditional extend to the seeded ones, which both survive" do
      tables = Rigor::Protection::DiscoverySeed.seed_tables(with_siblings(cold_index(project), injected))
      source = "module Fmt\n  def fmt = 1\nend\nclass Gadget\n  extend Fmt if ENV[\"X\"]\nend\n"

      discovery = indexed_discovery(tables, source)

      expect(discovery.possible_discovered_methods).to eq("Gadget" => { ghost: :instance, fmt: :singleton })
      expect(discovery.contested_discovered_singleton_def_nodes).to eq(Set[["Gadget", :build], ["Gadget", :fmt]])
      expect(discovery.unpositioned_mixins.dig("Gadget", :extend)).to eq(["Fmt"])
      expect(sibling_readers(Rigor::Scope.empty.with_discovery(discovery)).except(
               :possible_discovered_methods, :contested_discovered_singleton_def_nodes
             )).to eq(injected.except(:possible_discovered_methods, :contested_discovered_singleton_def_nodes))
    end

    it "does not write the seeded siblings the file's extend follows" do
      seeded = injected.fetch(:possible_discovered_methods)
      tables = Rigor::Protection::DiscoverySeed.seed_tables(with_siblings(cold_index(project), injected))
      source = "module Fmt\n  def fmt = 1\nend\nclass Gadget\n  extend Fmt if ENV[\"X\"]\nend\n"

      indexed_discovery(tables, source)

      expect(tables.fetch(:possible_discovered_methods)).to eq(seeded)
    end

    it "indexes a file over an unseeded scope with empty siblings" do
      discovery = indexed_discovery({})

      expect(discovery.sibling_tables).to eq(empty_siblings)
      expect(discovery.discovered_def_nodes).not_to be_empty
    end
  end

  describe "a compact-header rename (path 7)" do
    let(:compact) do
      { "lib/outer.rb" => "class Outer; end\n",
        "lib/leaf.rb" => "module Wrap\n  class Outer::Leaf\n    def added = :added\n  end\nend\n" }
    end

    let(:recorded) do
      { possible_discovered_methods: { "Wrap::Outer::Leaf" => { ghost: :instance } },
        contested_discovered_def_nodes: Set[["Wrap::Outer::Leaf", :added]],
        contested_discovered_parameter_envelopes: Set[["Wrap::Outer::Leaf", %i[instance added]]],
        possible_discovered_deferred_ranges: { "lib/leaf.rb" => [[0, 1, :added, :instance, "Wrap::Outer::Leaf"]] } }
    end

    it "re-keys the siblings with their members and leaves a path-keyed sibling alone" do
      cold = cold_index(compact)
      leaf = "lib/leaf.rb"
      bundles = cold.fetch(:bundles).dup
      bundles[leaf] = bundles.fetch(leaf).merge(siblings: empty_siblings.merge(recorded))

      warm = indexer.discovered_project_index_incremental(compact.keys, seed_bundles: bundles)
      def_index = warm.fetch(:def_index)

      expect(def_index.fetch(:compact_header_renames)).to eq("Wrap::Outer::Leaf" => "Outer::Leaf")
      expect(def_index.fetch(:def_nodes)).to have_key("Outer::Leaf")
      expect(def_index.fetch(:siblings)).to include(
        possible_discovered_methods: { "Outer::Leaf" => { ghost: :instance } },
        contested_discovered_def_nodes: Set[["Outer::Leaf", :added]],
        contested_discovered_parameter_envelopes: Set[["Outer::Leaf", %i[instance added]]],
        possible_discovered_deferred_ranges: recorded.fetch(:possible_discovered_deferred_ranges)
      )
      # `possible_discovered_deferred_ranges` is keyed by path, and SIBLINGS_KEYED_BY_PATH cannot be told apart from the
      # Hash arm of `rename_siblings` for path keys: a path is never a compact class name, so both arms leave the key
      # alone. The row's class name (its 5th field) is what separates "skipped" from "renamed", so pin it on the member
      # row and on the sibling row. Both must still name the inner class.
      member_owners = def_index.fetch(:deferred_ranges).fetch(leaf).map { |row| row[4] }
      sibling_owners = def_index.fetch(:siblings).fetch(:possible_discovered_deferred_ranges).fetch(leaf).map do |row|
        row[4]
      end
      expect(member_owners).not_to be_empty
      expect(member_owners).to all(eq("Wrap::Outer::Leaf"))
      expect(sibling_owners).to all(eq("Wrap::Outer::Leaf"))
    end

    it "folds two recorded keys that rename to one into the union" do
      acc = indexer.new_def_index_accumulator
      acc[:siblings] = acc[:siblings].merge(
        possible_discovered_methods: { "Wrap::Outer::Leaf" => { ghost: :instance }, "Outer::Leaf" => { ghost: :singleton } }
      )

      renamed = indexer.rename_siblings(acc[:siblings], "Wrap::Outer::Leaf" => "Outer::Leaf")

      expect(renamed.fetch(:possible_discovered_methods)).to eq("Outer::Leaf" => { ghost: :both })
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers
end
