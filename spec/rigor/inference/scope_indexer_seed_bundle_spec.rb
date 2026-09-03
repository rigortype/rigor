# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "digest"
require "rigor/inference/scope_indexer"
require "rigor/inference/def_node_resolver"

# ADR-85 WD2 — the seed-bundle fold. The core correctness property: rebuilding the cross-file discovery index
# from cached per-file bundles (re-walking only changed files) is byte-identical to a fresh parse+walk of the
# whole tree, for every plain-data table AND for the def-node tables once resolved to (node_id, name,
# fingerprint) triples. The `--verify-incremental` gate is the end-to-end backstop; this pins the algorithm in
# isolation.
RSpec.describe Rigor::Inference::ScopeIndexer do
  # A three-file project exercising cross-file reopening, inheritance, includes, singleton defs, a Data.define,
  # a `Class.new` constant, and — issue #707 — a COMPACT declaration, whose `Module.nesting` is the one entry
  # `["Shop::Compact"]` where the nested spelling of the same class would record two. Without it the chain
  # comparison could not tell a carried chain from a re-derived one: both spellings render the same class name.
  def write_project(dir)
    write_project_a(dir)
    File.write(File.join(dir, "b.rb"), <<~RUBY)
      module Shop
        class Widget < Base
          def price = 10
          def name = "w"
        end
        Point = Data.define(:x, :y)
        Boom = Class.new(StandardError)
      end
    RUBY
    File.write(File.join(dir, "c.rb"), <<~RUBY)
      module Shop
        class Widget
          def discount = 2
        end
      end
    RUBY
    %w[a.rb b.rb c.rb].map { |f| File.join(dir, f) }
  end

  def write_project_a(dir)
    File.write(File.join(dir, "a.rb"), <<~RUBY)
      module Shop
        class Base
          def tag = "base"
          def self.make = new
        end
        include Comparable
      end

      class Shop::Compact
        def build = 1
        def self.build_all = new
      end
    RUBY
  end

  # Resolve a def-node table (live nodes OR DefHandles) to comparable (node_id, name, fingerprint, nesting)
  # rows. Issue #707 — the chain is part of the equivalence, not an extra: `def_nestings` is keyed by node
  # IDENTITY, so a bundle can only carry it ON the row, and a fold that dropped it would still compare equal
  # on every other table while a warm run resolved a different constant than a cold one. For a live node the
  # chain comes from the index's own `def_nestings` table; for a handle, off the handle.
  def normalize_defs(table, nestings)
    table.transform_values do |methods|
      methods.transform_values do |value|
        if value.is_a?(Rigor::Inference::DefHandle)
          [value.node_id, value.name, value.fingerprint, value.nesting]
        else
          [value.node_id, value.name.to_s, Digest::SHA256.hexdigest(value.location.slice), nestings[value]]
        end
      end
    end
  end

  def plain_tables
    %i[def_sources superclasses includes method_visibilities methods
       class_sources data_member_layouts struct_member_layouts]
  end

  def expect_index_equivalent(actual, reference)
    expect(actual[:classes]).to eq(reference[:classes])
    a = actual[:def_index]
    r = reference[:def_index]
    plain_tables.each { |key| expect(a[key]).to eq(r[key]), "#{key} diverged" }
    expect_def_tables_equivalent(a, r, :def_nodes)
    expect_def_tables_equivalent(a, r, :singleton_def_nodes)
  end

  def expect_def_tables_equivalent(actual, reference, key)
    expect(normalize_defs(actual[key], actual[:def_nestings]))
      .to eq(normalize_defs(reference[key], reference[:def_nestings])), "#{key} diverged"
  end

  it "cold fold (empty bundles) is byte-identical to a fresh walk and keeps live nodes" do
    Dir.mktmpdir do |dir|
      paths = write_project(dir)
      reference = described_class.discovered_project_index_for_paths(paths)
      cold = described_class.discovered_project_index_incremental(paths, seed_bundles: {})

      expect_index_equivalent(cold, reference)
      # Cold = every file re-walked → live nodes throughout.
      cold[:def_index][:def_nodes].each_value do |methods|
        methods.each_value { |v| expect(v).to be_a(Prism::DefNode) }
      end
      expect(cold[:bundles].keys).to match_array(paths)
    end
  end

  it "warm fold (all cached) is byte-identical to a fresh walk and stores handles" do
    Dir.mktmpdir do |dir|
      paths = write_project(dir)
      reference = described_class.discovered_project_index_for_paths(paths)
      cold = described_class.discovered_project_index_incremental(paths, seed_bundles: {})
      warm = described_class.discovered_project_index_incremental(paths, seed_bundles: cold[:bundles])

      expect_index_equivalent(warm, reference)
      # Nothing changed → every def-node is a lazy handle (no file re-parsed for its body).
      warm[:def_index][:def_nodes].each_value do |methods|
        methods.each_value { |v| expect(v).to be_a(Rigor::Inference::DefHandle) }
      end
    end
  end

  it "matches a fresh walk of the edited tree after a single-file change (mixed live + handles)" do
    Dir.mktmpdir do |dir|
      paths = write_project(dir)
      cold = described_class.discovered_project_index_incremental(paths, seed_bundles: {})

      # Edit b.rb: change a body and add a method.
      File.write(paths[1], <<~RUBY)
        module Shop
          class Widget < Base
            def price = 42
            def name = "w"
            def sku = "s1"
          end
          Point = Data.define(:x, :y)
          Boom = Class.new(StandardError)
        end
      RUBY

      reference = described_class.discovered_project_index_for_paths(paths)
      warm = described_class.discovered_project_index_incremental(paths, seed_bundles: cold[:bundles])

      expect_index_equivalent(warm, reference)
      # b.rb was re-walked (digest changed) → its methods are live; a.rb / c.rb served from bundles → handles.
      expect(warm[:def_index][:def_nodes]["Shop::Widget"][:price]).to be_a(Prism::DefNode)
      expect(warm[:def_index][:def_nodes]["Shop::Base"][:tag]).to be_a(Rigor::Inference::DefHandle)
      expect(warm[:def_index][:def_nodes]["Shop::Widget"][:sku]).to be_a(Prism::DefNode)
    end
  end

  it "drops a removed file and adds a new one against the same bundle set" do
    Dir.mktmpdir do |dir|
      paths = write_project(dir)
      cold = described_class.discovered_project_index_incremental(paths, seed_bundles: {})

      File.delete(paths[2]) # remove c.rb
      d = File.join(dir, "d.rb")
      File.write(d, "module Shop\n  class Gadget\n    def go = 1\n  end\nend\n")
      new_paths = [paths[0], paths[1], d]

      reference = described_class.discovered_project_index_for_paths(new_paths)
      warm = described_class.discovered_project_index_incremental(new_paths, seed_bundles: cold[:bundles])

      expect_index_equivalent(warm, reference)
      expect(warm[:bundles].keys).to match_array(new_paths) # c.rb's bundle dropped, d.rb's added
    end
  end

  # Issue #707 — the chain the bundle carries must be the chain the DECLARATION records, and for a compact
  # declaration that is the single qualified entry. Pinned as a value rather than only through the
  # equivalence, so a fold that carried the same WRONG chain on both sides would still be caught.
  it "carries a compact declaration's one-entry Module.nesting onto the handle" do
    Dir.mktmpdir do |dir|
      paths = write_project(dir)
      cold = described_class.discovered_project_index_incremental(paths, seed_bundles: {})
      warm = described_class.discovered_project_index_incremental(paths, seed_bundles: cold[:bundles])

      compact = warm[:def_index][:def_nodes]["Shop::Compact"][:build]
      nested = warm[:def_index][:def_nodes]["Shop::Base"][:tag]
      singleton = warm[:def_index][:singleton_def_nodes]["Shop::Compact"][:build_all]

      expect(compact.nesting).to eq(["Shop::Compact"])
      expect(nested.nesting).to eq(["Shop::Base", "Shop"])
      expect(singleton.nesting).to eq(["Shop::Compact"])
    end
  end

  # Issue #707 — the reason a rehydration memo is NOT a second source for the same fact: OBJECT PROVENANCE.
  # `DefNodeResolver` runs its own `Prism.parse`, and both tables are `compare_by_identity`, so a node it
  # mints is never the object one of the analyzer's own walks produced and no node can be a key in both. That
  # is the load-bearing claim behind the reader's `table || rehydration` order, so it is COMPUTED here rather
  # than argued: were a resolved node ever also an index key, the fallback could silently prefer a stale chain
  # over a live one.
  #
  # The claim is deliberately about the PARSE and not about files. A file-level version — "a file is either
  # re-walked or bundle-served, never both in one run" — is FALSE and was asserted before it was measured: an
  # unchanged file re-analysed as a dependent is bundle-served by this fold AND walked live by
  # `merge_def_node_tables` for its own per-file index. The example below therefore takes a MIXED run and
  # checks identities, which is what actually holds.
  it "keeps the index table and the resolver rehydration disjoint over the same run" do
    Dir.mktmpdir do |dir|
      paths = write_project(dir)
      cold = described_class.discovered_project_index_incremental(paths, seed_bundles: {})
      # Edit b.rb so the run is MIXED: b.rb re-walked (live nodes), a.rb / c.rb served from bundles (handles).
      File.write(paths[1], "module Shop\n  class Widget < Base\n    def price = 42\n  end\nend\n")
      warm = described_class.discovered_project_index_incremental(paths, seed_bundles: cold[:bundles])
      nestings = warm[:def_index][:def_nestings]

      Rigor::Inference::DefNodeResolver.with_run do
        bundled = Rigor::Inference::DefNodeResolver.resolve(
          warm[:def_index][:def_nodes]["Shop::Compact"][:build]
        )
        live = warm[:def_index][:def_nodes]["Shop::Widget"][:price]

        # The bundle-served def: minted by the resolver's own parse, so the index cannot key it — the
        # rehydration is the ONLY answer, and it is the chain the declaration recorded.
        expect(nestings).not_to have_key(bundled)
        expect(Rigor::Inference::DefNodeResolver.rehydrated_nesting(bundled)).to eq(["Shop::Compact"])

        # The re-walked def, in the same run: the index owns it and the rehydration knows nothing about it.
        expect(live).to be_a(Prism::DefNode)
        expect(nestings[live]).to eq(["Shop::Widget", "Shop"])
        expect(Rigor::Inference::DefNodeResolver.rehydrated_nesting(live)).to be_nil
      end
    end
  end

  it "produces Marshal-clean bundles (they ride the snapshot blob)" do
    Dir.mktmpdir do |dir|
      paths = write_project(dir)
      cold = described_class.discovered_project_index_incremental(paths, seed_bundles: {})
      expect { Marshal.dump(cold[:bundles]) }.not_to raise_error
      round_tripped = Marshal.load(Marshal.dump(cold[:bundles]))
      warm = described_class.discovered_project_index_incremental(paths, seed_bundles: round_tripped)
      expect_index_equivalent(warm, described_class.discovered_project_index_for_paths(paths))
    end
  end
end
