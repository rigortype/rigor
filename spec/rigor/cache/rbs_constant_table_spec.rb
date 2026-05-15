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

    it "files slot for a loader with no signature_paths still digests the bundled vendored gem stubs" do
      # Vendored gem RBS stubs ship with rigor and are loaded by
      # default (`Environment::RbsLoader.vendored_gem_sig_paths`),
      # so the descriptor's files slot is never empty even without
      # any user-supplied `signature_paths:`. The vendored set is
      # part of the cache invalidation contract: bumping a stub
      # bumps the cache.
      descriptor = Rigor::Cache::RbsDescriptor.build(loader)
      expect(descriptor.files).not_to be_empty
      expect(descriptor.files.map(&:comparator).uniq).to eq([:digest])
      vendored_root = Rigor::Environment::RbsLoader.vendored_gem_sig_paths.first.to_s
      expect(descriptor.files.map(&:path)).to all(start_with(vendored_root.split("/")[0..-2].join("/")))
    end

    it "produces a configs entry capturing the libraries list" do
      descriptor = Rigor::Cache::RbsDescriptor.build(loader)
      libs_entry = descriptor.configs.find { |e| e.key == "rbs.libraries" }
      expect(libs_entry).not_to be_nil
      expect(libs_entry.value_hash).to match(/\A[0-9a-f]{64}\z/)
    end

    it "files-slot digests every .rbs under signature_paths plus the vendored gem stubs" do
      Dir.mktmpdir("rigor-rbs-sig-") do |sig_dir|
        File.write(File.join(sig_dir, "a.rbs"), "class Foo end\n")
        File.write(File.join(sig_dir, "b.rbs"), "class Bar end\n")

        custom_loader = Rigor::Environment::RbsLoader.new(signature_paths: [sig_dir])
        descriptor = Rigor::Cache::RbsDescriptor.build(custom_loader)
        # The two user files MUST be present; vendored stubs add
        # their own entries on top.
        custom_paths = descriptor.files.map(&:path).select { |p| p.start_with?(sig_dir) }
        expect(custom_paths.size).to eq(2)
        expect(descriptor.files.map(&:comparator).uniq).to eq([:digest])
        # Sanity: the descriptor SHOULD also include the bundled
        # vendored stubs so a stub edit invalidates the cache.
        vendored_root = Rigor::Environment::RbsLoader.vendored_gem_sig_paths.first.to_s
        expect(descriptor.files.size).to be > custom_paths.size
        expect(descriptor.files.map(&:path).any? { |p| p.start_with?(File.dirname(vendored_root)) }).to be(true)
      end
    end
  end
end
