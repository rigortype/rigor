# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Cache::RbsClassTypeParamNames do
  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-type-params-spec-") }
  let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }
  let(:store) { Rigor::Cache::Store.new(root: cache_root) }
  let(:loader) { Rigor::Environment::RbsLoader.new }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".fetch" do
    it "returns a Hash<String, Array<Symbol>> for the loaded RBS environment" do
      table = described_class.fetch(loader: loader, store: store)
      expect(table).to be_a(Hash)
      expect(table).not_to be_empty
      table.each do |class_name, params|
        expect(class_name).to be_a(String)
        expect(params).to be_an(Array)
        expect(params).to all(be_a(Symbol))
      end
    end

    it "captures generic classes' type parameters (Array, Hash)" do
      table = described_class.fetch(loader: loader, store: store)
      expect(table.fetch("Array")).to eq([:Elem])
      expect(table.fetch("Hash")).to eq(%i[K V])
    end

    it "leaves non-generic classes with an empty parameter list" do
      table = described_class.fetch(loader: loader, store: store)
      expect(table.fetch("Integer")).to eq([])
    end

    it "writes a single entry under rbs.class_type_param_names/" do
      described_class.fetch(loader: loader, store: store)
      entries = Dir.glob(File.join(cache_root, "rbs.class_type_param_names", "**", "*.entry"))
      expect(entries.size).to eq(1)
    end

    it "skips the producer block on a cache hit" do
      allow(loader).to receive(:each_known_class_name).and_call_original
      described_class.fetch(loader: loader, store: store)
      described_class.fetch(loader: loader, store: store)
      expect(loader).to have_received(:each_known_class_name).once
    end

    it "round-trips through Marshal cleanly (Hash<String, Array<Symbol>> is Marshal-clean)" do
      table = described_class.fetch(loader: loader, store: store)
      blob = Marshal.dump(table)
      reloaded = Marshal.load(blob) # rubocop:disable Security/MarshalLoad
      expect(reloaded.fetch("Array")).to eq([:Elem])
    end
  end
end
