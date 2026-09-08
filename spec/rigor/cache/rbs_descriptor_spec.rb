# frozen_string_literal: true

require "spec_helper"
require "rigor/cache/rbs_descriptor"
require "rigor/environment/rbs_loader"
require "tmpdir"

RSpec.describe Rigor::Cache::RbsDescriptor do
  let(:loader) { Rigor::Environment::RbsLoader.new }

  describe ".build_run (lazy-files run descriptor)" do
    it "carries the same gems + configs as the eager .build (the cache key is unchanged)" do
      eager = described_class.build(loader)
      run = described_class.build_run(loader)
      expect(run.gems).to eq(eager.gems)
      expect(run.configs).to eq(eager.configs)
    end

    it "does not digest the RBS signature tree until #files is read" do
      allow(described_class).to receive(:file_entries).and_call_original
      run = described_class.build_run(loader)

      # Building the descriptor + reading the key slots must NOT walk the signature tree.
      run.gems
      run.configs
      expect(described_class).not_to have_received(:file_entries)

      # The file entries are computed only on first #files access.
      entries = run.files
      expect(described_class).to have_received(:file_entries).once
      expect(entries).not_to be_empty
      # ADR-87 WD1 — the validation-only run descriptor rides the stat-then-digest `:stat` tier, while the
      # env-cache KEY descriptor (`.build`) keeps deterministic `:digest` entries over the same paths.
      expect(entries.map(&:comparator).uniq).to eq([:stat])
      expect(entries.map(&:path).sort).to eq(described_class.build(loader).files.map(&:path).sort)
    end

    it "memoises #files (a second read does not re-walk the tree)" do
      allow(described_class).to receive(:file_entries).and_call_original
      run = described_class.build_run(loader)
      first = run.files
      second = run.files
      expect(first).to equal(second)
      expect(described_class).to have_received(:file_entries).once
    end
  end

  # Issue #610 — which `signature_paths:` are DEFERRED (a bundled plugin's `sig/`, allowed to stand down
  # against a colliding generic arity) changes the env built from byte-identical files, so the env-cache
  # KEY carries the partition. The run-result key does not need it — it digests the whole configuration —
  # and its boot-slimming probe cannot rebuild a plugin-derived slot, so the shared `config_entries` stay
  # byte-identical between the two loaders.
  describe "the deferred partition" do
    it "changes the env-cache key and leaves the run key's shared slots alone" do
      Dir.mktmpdir do |dir|
        sig_dir = File.join(dir, "plugin_sig")
        Dir.mkdir(sig_dir)
        File.write(File.join(sig_dir, "relation.rbs"), "class Relation[Elem]\nend\n")
        eager = Rigor::Environment::RbsLoader.new(signature_paths: [sig_dir])
        deferred = Rigor::Environment::RbsLoader.new(signature_paths: [sig_dir], deferred_signature_paths: [sig_dir])

        expect(described_class.build(deferred)).not_to eq(described_class.build(eager))
        expect(described_class.build(deferred).configs.map(&:key)).to include("rbs.deferred_signature_paths")
        expect(described_class.build(eager).configs.map(&:key)).not_to include("rbs.deferred_signature_paths")
        expect(described_class.config_entries(deferred)).to eq(described_class.config_entries(eager))
        expect(described_class.build_run(deferred).configs).to eq(described_class.build_run(eager).configs)
      end
    end
  end
end
