# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Cache::RbsConstantTable do
  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-const-table-spec-") }
  let(:cache_root) { File.join(tmpdir, ".rigor", "cache") }
  let(:store) { Rigor::Cache::Store.new(root: cache_root) }
  let(:loader) { Rigor::Environment::RbsLoader.new }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".fetch" do
    it "returns a Hash<String, Rigor::Type> for the loaded RBS environment" do
      table = described_class.fetch(loader: loader, store: store)
      expect(table).to be_a(Hash)
      expect(table).not_to be_empty
      table.each do |name, value|
        expect(name).to be_a(String)
        expect(value.class.name).to start_with("Rigor::Type::")
      end
    end

    it "includes Math::PI as a translated Float type (sanity check on a known constant)" do
      table = described_class.fetch(loader: loader, store: store)
      pi_key = table.keys.find { |k| k.end_with?("Math::PI") }
      expect(pi_key).not_to be_nil, "expected Math::PI in constant table; got keys sample: #{table.keys.first(5)}"
      expect(table[pi_key]).to be_a(Rigor::Type::Nominal)
      expect(table[pi_key].class_name.to_s).to include("Float")
    end

    it "writes a cache entry under the configured store root" do
      described_class.fetch(loader: loader, store: store)
      entries = Dir.glob(File.join(cache_root, "rbs.constant_type_table", "**", "*.entry"))
      expect(entries.size).to eq(1)
    end

    it "returns a structurally equal table on a cache hit" do
      first = described_class.fetch(loader: loader, store: store)
      second = described_class.fetch(loader: loader, store: store)
      expect(second.keys.sort).to eq(first.keys.sort)
      expect(second).to eq(first)
    end

    it "skips the producer block on a cache hit" do
      allow(loader).to receive(:each_constant_decl).and_call_original
      described_class.fetch(loader: loader, store: store)
      described_class.fetch(loader: loader, store: store)
      expect(loader).to have_received(:each_constant_decl).once
    end
  end

  describe "descriptor invariants" do
    it "produces a descriptor that includes the rbs gem with its locked version" do
      descriptor = Rigor::Cache::RbsDescriptor.build(loader)
      gem_entry = descriptor.gems.find { |e| e.name == "rbs" }
      expect(gem_entry).not_to be_nil
      expect(gem_entry.locked).to match(/\A\d+\.\d+\.\d+/)
    end

    it "produces an empty files slot for a loader with no signature_paths" do
      descriptor = Rigor::Cache::RbsDescriptor.build(loader)
      expect(descriptor.files).to eq([])
    end

    it "produces a configs entry capturing the libraries list" do
      descriptor = Rigor::Cache::RbsDescriptor.build(loader)
      libs_entry = descriptor.configs.find { |e| e.key == "rbs.libraries" }
      expect(libs_entry).not_to be_nil
      expect(libs_entry.value_hash).to match(/\A[0-9a-f]{64}\z/)
    end

    it "files-slot digests every .rbs under signature_paths" do
      Dir.mktmpdir("rigor-rbs-sig-") do |sig_dir|
        File.write(File.join(sig_dir, "a.rbs"), "class Foo end\n")
        File.write(File.join(sig_dir, "b.rbs"), "class Bar end\n")

        custom_loader = Rigor::Environment::RbsLoader.new(signature_paths: [sig_dir])
        descriptor = Rigor::Cache::RbsDescriptor.build(custom_loader)
        expect(descriptor.files.size).to eq(2)
        expect(descriptor.files.map(&:comparator).uniq).to eq([:digest])
      end
    end
  end
end
