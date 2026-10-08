# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/protection/discovery_seed"

# ADR-119 WD3 — the def-contribution producers fill WD1's siblings, and every fold path reads them by one rule:
#
# - `possible_discovered_methods` per name and side, `P' = (P − C_f) ∪ (P_f − C)` with `C = member − P`, so a side
#   any file supplies certainly is never possible, whatever the file order;
# - a def-node slot's contest follows the file that wrote the slot (the member folds later-wins);
# - the joined envelopes' contests by union.
#
# Each rule is checked in both file orders, and the cold direct walk, the bundle fold of a cold run and the bundle
# fold of a warm run must agree, as must the per-file index of the file that writes last.
RSpec.describe "Discovery certainty (ADR-119 WD3)" do
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:certain_file) { "class C\n  attr_reader :x\n  def m(a) = a\nend\n" }
  let(:possible_file) do
    "class C\n  if ENV[\"X\"]\n    attr_reader :x\n    attr_reader :y\n    def m(a, b) = a\n  end\nend\n"
  end

  around do |example|
    Dir.mktmpdir("rigor-discovery-certainty-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write_project(files)
    files.map do |rel, source|
      FileUtils.mkdir_p(File.dirname(rel))
      File.write(rel, source)
      rel
    end
  end

  def siblings_of(index) = index.fetch(:def_index).fetch(:siblings)

  # The project siblings over `files`, in the given order, along the three whole-project paths.
  def project_siblings(files)
    paths = write_project(files)
    direct = indexer.discovered_project_index_for_paths(paths)
    cold = indexer.discovered_project_index_incremental(paths, seed_bundles: {})
    warm = indexer.discovered_project_index_incremental(paths, seed_bundles: cold.fetch(:bundles))
    [direct, cold, warm].map { |index| siblings_of(index) }
  end

  def agreed_siblings(files)
    direct, cold, warm = project_siblings(files)
    expect(cold).to eq(direct)
    expect(warm).to eq(direct)
    direct
  end

  # The per-file index of `path` over the project seed of `files`.
  def per_file_discovery(files, path)
    paths = write_project(files)
    index = indexer.discovered_project_index_incremental(paths, seed_bundles: {})
    tables = Rigor::Protection::DiscoverySeed.seed_tables(index)
    base = Rigor::Scope.empty
    scope = base.with_discovery(base.discovery.with(**tables)).with_source_path(path)
    root = Prism.parse(File.read(path), filepath: path).value
    indexer.index(root, default_scope: scope).fetch(root).discovery
  end

  describe "possible_discovered_methods across files" do
    it "keeps a name certain when any file supplies it certainly, in either order" do
      [%w[a.rb b.rb], %w[b.rb a.rb]].each do |order|
        files = order.zip([certain_file, possible_file]).to_h

        expect(agreed_siblings(files).fetch(:possible_discovered_methods)).to eq("C" => { y: :instance })
      end
    end

    it "keeps a name possible when every contribution is" do
      siblings = agreed_siblings("a.rb" => possible_file, "b.rb" => "class C\n  [1].each { attr_reader :x }\nend\n")

      expect(siblings.fetch(:possible_discovered_methods)).to eq("C" => { x: :instance, y: :instance })
    end

    it "folds per side: a certain singleton half leaves the instance half possible" do
      siblings = agreed_siblings(
        "a.rb" => "class C\n  class << self\n    attr_reader :z\n  end\nend\n",
        "b.rb" => "class C\n  if ENV[\"X\"]\n    attr_reader :z\n    class << self\n      attr_reader :z\n    " \
                  "end\n  end\nend\n"
      )

      expect(siblings.fetch(:possible_discovered_methods)).to eq("C" => { z: :instance })
    end
  end

  describe "contested def-node slots" do
    it "follows the file that wrote the slot last" do
      later_possible = agreed_siblings("a.rb" => certain_file, "b.rb" => possible_file)
      later_certain = agreed_siblings("a.rb" => possible_file, "b.rb" => certain_file)

      expect(later_possible.fetch(:contested_discovered_def_nodes)).to eq(Set[["C", :m]])
      expect(later_certain.fetch(:contested_discovered_def_nodes)).to be_empty
    end

    it "contests a singleton slot a possible `def self.x` wrote" do
      siblings = agreed_siblings("a.rb" => "class C\n  if ENV[\"X\"]\n    def self.s = 1\n  end\nend\n")

      expect(siblings.fetch(:contested_discovered_singleton_def_nodes)).to eq(Set[["C", :s]])
    end

    it "contests an alias of a contested def, and a possible alias of a certain one" do
      siblings = agreed_siblings(
        "a.rb" => "class C\n  def k = 1\n  if ENV[\"X\"]\n    def m = 1\n    alias n2 k\n  end\n  alias n m\nend\n"
      )

      expect(siblings.fetch(:contested_discovered_def_nodes)).to eq(Set[["C", :m], ["C", :n], ["C", :n2]])
    end

    it "contests a top-level def under a conditional" do
      siblings = agreed_siblings("a.rb" => "if ENV[\"X\"]\n  def top = 1\nend\n")

      expect(siblings.fetch(:contested_discovered_def_nodes)).to eq(Set[["<toplevel>", :top]])
    end
  end

  describe "contested envelopes" do
    it "union across files, in either order" do
      [%w[a.rb b.rb], %w[b.rb a.rb]].each do |order|
        files = order.zip([certain_file, possible_file]).to_h

        expect(agreed_siblings(files).fetch(:contested_discovered_parameter_envelopes))
          .to include(["C", %i[instance m]], ["C", %i[instance y]])
      end
    end
  end

  describe "the per-file index" do
    it "agrees with the project index for the file that writes last" do
      files = { "a.rb" => certain_file, "b.rb" => possible_file }
      project = agreed_siblings(files)
      discovery = per_file_discovery(files, "b.rb")

      expect(discovery.contested_discovered_def_nodes).to eq(project.fetch(:contested_discovered_def_nodes))
      expect(discovery.contested_discovered_parameter_envelopes)
        .to eq(project.fetch(:contested_discovered_parameter_envelopes))
      # The project table drops `def`-declared instance names from the member and its sibling at finalize
      # (`subtract_def_methods`); the per-file member keeps the file's own, so `m` is possible here only.
      expect(project.fetch(:possible_discovered_methods)).to eq("C" => { y: :instance })
      expect(discovery.possible_discovered_methods).to eq("C" => { y: :instance, m: :instance })
    end

    it "lets the file under analysis win the slots it writes" do
      discovery = per_file_discovery({ "a.rb" => possible_file, "b.rb" => certain_file }, "a.rb")

      expect(discovery.contested_discovered_def_nodes).to eq(Set[["C", :m]])
    end
  end
end
