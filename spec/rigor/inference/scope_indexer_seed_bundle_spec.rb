# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "digest"
require "rigor/inference/scope_indexer"

# ADR-85 WD2 — the seed-bundle fold. The core correctness property: rebuilding the cross-file discovery index
# from cached per-file bundles (re-walking only changed files) is byte-identical to a fresh parse+walk of the
# whole tree, for every plain-data table AND for the def-node tables once resolved to (node_id, name,
# fingerprint) triples. The `--verify-incremental` gate is the end-to-end backstop; this pins the algorithm in
# isolation.
RSpec.describe Rigor::Inference::ScopeIndexer do
  # A three-file project exercising cross-file reopening, inheritance, includes, singleton defs, a Data.define,
  # and a `Class.new` constant — the shapes the fold's merge semantics must preserve.
  def write_project(dir)
    File.write(File.join(dir, "a.rb"), <<~RUBY)
      module Shop
        class Base
          def tag = "base"
          def self.make = new
        end
        include Comparable
      end
    RUBY
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

  # Resolve a def-node table (live nodes OR DefHandles) to comparable (node_id, name, fingerprint) triples.
  def normalize_defs(table)
    table.transform_values do |methods|
      methods.transform_values do |value|
        if value.is_a?(Rigor::Inference::DefHandle)
          [value.node_id, value.name, value.fingerprint]
        else
          [value.node_id, value.name.to_s, Digest::SHA256.hexdigest(value.location.slice)]
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
    expect(normalize_defs(a[:def_nodes])).to eq(normalize_defs(r[:def_nodes]))
    expect(normalize_defs(a[:singleton_def_nodes])).to eq(normalize_defs(r[:singleton_def_nodes]))
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
