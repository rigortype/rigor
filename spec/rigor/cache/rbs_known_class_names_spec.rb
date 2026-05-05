# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Cache::RbsKnownClassNames do
  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-known-classes-spec-") }
  let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }
  let(:store) { Rigor::Cache::Store.new(root: cache_root) }
  let(:loader) { Rigor::Environment::RbsLoader.new }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".fetch" do
    it "returns a Set<String> covering the loaded RBS environment" do
      names = described_class.fetch(loader: loader, store: store)
      expect(names).to be_a(Set)
      expect(names).not_to be_empty
      expect(names).to all(be_a(String))
    end

    it "includes every core class the analyzer relies on (sanity check)" do
      names = described_class.fetch(loader: loader, store: store)
      %w[::Integer ::String ::Array ::Hash ::Object].each do |expected|
        expect(names).to include(expected), "expected #{expected} in known_class_names"
      end
    end

    it "writes a single entry under rbs.known_class_names/" do
      described_class.fetch(loader: loader, store: store)
      entries = Dir.glob(File.join(cache_root, "rbs.known_class_names", "**", "*.entry"))
      expect(entries.size).to eq(1)
    end

    it "skips the producer block on a cache hit" do
      allow(loader).to receive(:each_known_class_name).and_call_original
      described_class.fetch(loader: loader, store: store)
      described_class.fetch(loader: loader, store: store)
      expect(loader).to have_received(:each_known_class_name).once
    end
  end
end
