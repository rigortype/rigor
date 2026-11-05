# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rigor/protection/discovery_seed"

# Issue #2300 — the override gate's definers index and the #1596 definition count are each built once per seed
# table, not once per analysed file. A file's def table is its own `def`s merged over the cross-file seed, a new
# Hash per file, so inverting it whole scanned every project `def` for every file.
RSpec.describe Rigor::Inference::DefinersIndex do
  let(:tmpdir) { Dir.mktmpdir }
  let(:paths) do
    {
      "base.rb" => <<~RUBY,
        class Base
          def run = 1
          def self.make = new
        end
      RUBY
      "child.rb" => <<~RUBY
        class Child < Base
          def run = 2
          def other = 3
        end
        def top_helper = 4
      RUBY
    }.map do |name, source|
      path = File.join(tmpdir, name)
      File.write(path, source)
      path
    end
  end
  let(:seed_scope) do
    tables = Rigor::Inference::ProjectSeedTables.for_paths(paths)
    Rigor::Protection::DiscoverySeed.seeded_scope(environment: Rigor::Environment.default, seed: tables)
  end

  after { FileUtils.remove_entry(tmpdir) }

  def file_scope(path)
    root = Prism.parse_file(path).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: seed_scope.with_source_path(path)).values.first
  end

  def as_sets(index, names) = names.to_h { |name| [name, index[name]&.sort] }

  # Counts seed builds, which an enabled MemoAudit adds to (each audited hit rebuilds to compare), so it runs with the
  # audit off whatever the environment says.
  it "inverts the seed once for every file merged over it, answering what a whole inversion answers" do
    was = Rigor::Inference::MemoAudit.enabled?
    Rigor::Inference::MemoAudit.disable!
    builds = []
    allow(described_class).to receive(:build).and_wrap_original do |original, table|
      builds << table
      original.call(table)
    end

    per_file_builds = []
    answers = paths.map do |path|
      table = file_scope(path).discovered_def_nodes
      before = builds.size
      index = described_class.for(table)
      per_file_builds << builds[before..].reject { |built| built.equal?(seed_scope.discovered_def_nodes) }
      [as_sets(index, %i[run other make top_helper]),
       as_sets(described_class.send(:build, table), %i[run other make top_helper])]
    end

    seed_table = seed_scope.discovered_def_nodes
    expect(builds.count { |table| table.equal?(seed_table) }).to eq(1)
    answers.each { |layered, whole| expect(layered).to eq(whole) }
    expect(answers.first.first).to eq(run: %w[Base Child], other: ["Child"], make: nil, top_helper: nil)
    # Per file, only the owners the file replaced are inverted: `Base` for base.rb, `Child` and the top level for
    # child.rb. The seed's other owners are read from the seed's index.
    expect(per_file_builds.map { |built| built.map(&:keys) })
      .to eq([[["Base"]], [["Child", Rigor::Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY]]])
  ensure
    Rigor::Inference::MemoAudit.enable! if was
  end

  it "inverts a table whole when the seed is frozen but one of its inner tables is not" do
    seed = { "Base" => { run: :node }.freeze, "Open" => { run: :node } }.freeze
    merged = seed.merge("Child" => { run: :node })
    described_class.record_layers(merged, seed)

    expect(described_class.for(merged)).to be_a(Hash)
  end

  it "inverts a table whole when its seed's tables are not all frozen" do
    seed = { "Base" => { run: :node } }
    merged = seed.merge("Child" => { run: :node })
    described_class.record_layers(merged, seed)

    expect(described_class.for(merged)).to be_a(Hash)
  end

  it "inverts a table whole when the merge dropped one of the seed's owners" do
    seed = { "Base" => { run: :node }.freeze, "Gone" => { run: :node }.freeze }.freeze
    merged = { "Base" => seed["Base"], "Child" => { other: :node } }
    described_class.record_layers(merged, seed)

    expect(described_class.for(merged)).to be_a(Hash)
  end

  # ADR-129 — the layers and the two seed-index ways are run-scoped Memos in the thread's TypingState.
  describe "the thread's typing state" do
    let(:slots) { %i[definers_index_layers definers_index_seed definers_index_seed_alt] }
    let(:seed) { { "Base" => { run: :node }.freeze }.freeze }
    let(:other_seed) { { "Other" => { run: :node }.freeze }.freeze }

    it "files the layers and both seed-index ways, and a finished run releases them" do
      [seed, other_seed].each do |table|
        merged = table.merge("Child" => { go: :node })
        described_class.record_layers(merged, table)
        described_class.for(merged)
      end

      expect(slots.map { |name| typing_slot(name) }).to all(satisfy { |value| !value.nil? })
      expect(typing_slot(:definers_index_layers).size).to eq(2)
      expect(typing_slot(:definers_index_seed).first).to equal(other_seed)
      expect(typing_slot(:definers_index_seed_alt).first).to equal(seed)

      Rigor::RunScopedSlots.release
      expect(slots.map { |name| typing_slot(name) }).to all(be_nil)
    end
  end

  describe "the #1596 definition count" do
    it "counts every file's instance rows, built once per deferred-ranges table" do
      table = file_scope(paths.last).discovered_deferred_ranges
      first = Rigor::Inference::SelfCallIvarWrites.definition_counts(table)

      expect(Rigor::Inference::SelfCallIvarWrites.definition_counts(table)).to equal(first)
      expect(first).to include(["Base", :run] => 1, ["Child", :run] => 1, ["Child", :other] => 1)
      expect(first).not_to have_key(["Base", :make])
      expect(Rigor::Inference::SelfCallIvarWrites.definition_counts(table.dup)).not_to equal(first)
    end
  end
end
