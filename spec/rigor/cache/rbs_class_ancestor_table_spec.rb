# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Cache::RbsClassAncestorTable do
  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-ancestor-table-spec-") }
  let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }
  let(:store) { Rigor::Cache::Store.new(root: cache_root) }
  let(:loader) { Rigor::Environment::RbsLoader.new }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".fetch" do
    it "returns a Hash<String, Array<String>> for the loaded RBS environment" do
      table = described_class.fetch(loader: loader, store: store)
      expect(table).to be_a(Hash)
      expect(table).not_to be_empty
      table.each do |class_name, ancestors|
        expect(class_name).to be_a(String)
        expect(ancestors).to be_an(Array)
        expect(ancestors).to all(be_a(String))
      end
    end

    it "captures Integer's ancestor chain (sanity check on a known class)" do
      table = described_class.fetch(loader: loader, store: store)
      expect(table).to include("Integer")
      expect(table.fetch("Integer")).to include("Integer", "Numeric", "Comparable", "Object", "BasicObject")
    end

    it "writes a single entry under rbs.class_ancestor_table/" do
      described_class.fetch(loader: loader, store: store)
      entries = Dir.glob(File.join(cache_root, "rbs.class_ancestor_table", "**", "*.entry"))
      expect(entries.size).to eq(1)
    end

    it "skips the producer block on a cache hit" do
      allow(loader).to receive(:each_known_class_name).and_call_original
      described_class.fetch(loader: loader, store: store)
      described_class.fetch(loader: loader, store: store)
      expect(loader).to have_received(:each_known_class_name).once
    end

    it "round-trips through Marshal cleanly (Hash<String, Array<String>> is Marshal-clean)" do
      table = described_class.fetch(loader: loader, store: store)
      blob = Marshal.dump(table)
      reloaded = Marshal.load(blob) # rubocop:disable Security/MarshalLoad
      expect(reloaded.fetch("Integer")).to eq(table.fetch("Integer"))
    end
  end
end
