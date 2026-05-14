# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Cache::Descriptor do
  describe "construction" do
    it "defaults every slot to an empty array" do
      d = described_class.new
      expect(d.files).to eq([])
      expect(d.gems).to eq([])
      expect(d.plugins).to eq([])
      expect(d.configs).to eq([])
    end

    it "accepts entries via keyword arguments" do
      d = described_class.new(
        files: [described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")],
        gems: [described_class::GemEntry.new(name: "rbs", requirement: "*", locked: "4.0.0")]
      )
      expect(d.files.size).to eq(1)
      expect(d.gems.size).to eq(1)
    end

    it "freezes its slots so callers cannot mutate after construction" do
      d = described_class.new(files: [described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")])
      expect(d.files).to be_frozen
      expect { d.files << :nope }.to raise_error(FrozenError)
    end
  end

  describe "FileEntry" do
    it "rejects an unknown comparator" do
      expect do
        described_class::FileEntry.new(path: "a.rb", comparator: :checksum, value: "x")
      end.to raise_error(ArgumentError, /comparator/)
    end

    it "accepts :digest, :mtime, :exists" do
      %i[digest mtime exists].each do |c|
        entry = described_class::FileEntry.new(path: "a.rb", comparator: c, value: "x")
        expect(entry.comparator).to eq(c)
      end
    end
  end

  describe "DependencyEntry" do
    it "rejects an unknown mode" do
      expect do
        described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :strict)
      end.to raise_error(ArgumentError, /mode/)
    end

    it "accepts the three ADR-10 modes" do
      %i[disabled when_missing full].each do |m|
        entry = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: m)
        expect(entry.mode).to eq(m)
      end
    end

    it "is value-equal across construction sites" do
      a = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      b = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "freezes after construction" do
      entry = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      expect(entry).to be_frozen
    end
  end

  describe ".compose" do
    let(:file_a_digest) { described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc") }
    let(:file_a_mtime) do
      described_class::FileEntry.new(path: "a.rb", comparator: :mtime, value: "2026-05-05T00:00:00Z")
    end
    let(:file_b_digest) { described_class::FileEntry.new(path: "b.rb", comparator: :digest, value: "def") }
    let(:rbs_pinned_old) { described_class::GemEntry.new(name: "rbs", requirement: ">= 4", locked: "4.0.0") }
    let(:rbs_pinned_new) { described_class::GemEntry.new(name: "rbs", requirement: ">= 4", locked: "4.1.0") }
    let(:prism_gem) { described_class::GemEntry.new(name: "prism", requirement: "*", locked: "1.0.0") }

    it "unions disjoint slots by key" do
      a = described_class.new(files: [file_a_digest])
      b = described_class.new(files: [file_b_digest])
      composed = described_class.compose(a, b)
      expect(composed.files.map(&:path)).to contain_exactly("a.rb", "b.rb")
    end

    it "unions matching entries idempotently" do
      a = described_class.new(files: [file_a_digest], gems: [rbs_pinned_old])
      b = described_class.new(files: [file_a_digest], gems: [rbs_pinned_old])
      composed = described_class.compose(a, b)
      expect(composed.files.size).to eq(1)
      expect(composed.gems.size).to eq(1)
    end

    it "prefers the stricter comparator on file conflicts (digest > mtime > exists)" do
      a = described_class.new(files: [file_a_mtime])
      b = described_class.new(files: [file_a_digest])
      composed = described_class.compose(a, b)
      expect(composed.files.first.comparator).to eq(:digest)
    end

    it "raises a Conflict on disagreeing values under the stricter comparator" do
      other = described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "different")
      a = described_class.new(files: [file_a_digest])
      b = described_class.new(files: [other])
      expect { described_class.compose(a, b) }.to raise_error(described_class::Conflict)
    end

    it "raises a Conflict on disagreeing gem `locked` versions" do
      a = described_class.new(gems: [rbs_pinned_old])
      b = described_class.new(gems: [rbs_pinned_new])
      expect { described_class.compose(a, b) }.to raise_error(described_class::Conflict)
    end

    it "unions disjoint gems by name" do
      a = described_class.new(gems: [rbs_pinned_old])
      b = described_class.new(gems: [prism_gem])
      composed = described_class.compose(a, b)
      expect(composed.gems.map(&:name)).to contain_exactly("rbs", "prism")
    end

    it "unions disjoint dependency entries by gem_name" do
      rack = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      faraday = described_class::DependencyEntry.new(gem_name: "faraday", gem_version: "2.7.0", mode: :when_missing)
      composed = described_class.compose(
        described_class.new(dependencies: [rack]),
        described_class.new(dependencies: [faraday])
      )
      expect(composed.dependencies.map(&:gem_name)).to contain_exactly("rack", "faraday")
    end

    it "unions matching dependency entries idempotently" do
      rack = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      composed = described_class.compose(
        described_class.new(dependencies: [rack]),
        described_class.new(dependencies: [rack])
      )
      expect(composed.dependencies.size).to eq(1)
    end

    it "raises a Conflict when two dependency entries disagree on gem_version" do
      old = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      new_ver = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.1.0", mode: :when_missing)
      a = described_class.new(dependencies: [old])
      b = described_class.new(dependencies: [new_ver])
      expect { described_class.compose(a, b) }.to raise_error(described_class::Conflict)
    end

    it "raises a Conflict when two dependency entries disagree on mode" do
      lenient = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing)
      strict = described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :full)
      expect do
        described_class.compose(
          described_class.new(dependencies: [lenient]),
          described_class.new(dependencies: [strict])
        )
      end.to raise_error(described_class::Conflict)
    end
  end

  describe "per-gem-version invalidation (ADR-10 slice 3)" do
    let(:rack_old) { described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :when_missing) }
    let(:rack_new) { described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.1.0", mode: :when_missing) }
    let(:rack_full) { described_class::DependencyEntry.new(gem_name: "rack", gem_version: "3.0.0", mode: :full) }
    let(:faraday) do
      described_class::DependencyEntry.new(gem_name: "faraday", gem_version: "2.7.0", mode: :when_missing)
    end

    it "produces a different cache key when the gem_version bumps" do
      a = described_class.new(dependencies: [rack_old])
      b = described_class.new(dependencies: [rack_new])
      key_a = a.cache_key_for(producer_id: "p", params: {})
      key_b = b.cache_key_for(producer_id: "p", params: {})
      expect(key_a).not_to eq(key_b)
    end

    it "produces a different cache key when the mode changes" do
      a = described_class.new(dependencies: [rack_old])
      b = described_class.new(dependencies: [rack_full])
      key_a = a.cache_key_for(producer_id: "p", params: {})
      key_b = b.cache_key_for(producer_id: "p", params: {})
      expect(key_a).not_to eq(key_b)
    end

    it "leaves other gems' slices stable when one gem bumps" do
      before = described_class.new(dependencies: [rack_old, faraday])
      after = described_class.new(dependencies: [rack_new, faraday])
      # The invariant that matters: the descriptor for a producer
      # keyed only on `faraday` does not change when `rack`
      # bumps. Slice 3 lands the *primitive* — composing a
      # producer's per-gem descriptor with the index's
      # contribution is the consumer's job (slice 4+).
      faraday_only_before = described_class.new(dependencies: [faraday])
      faraday_only_after = described_class.new(dependencies: [faraday])
      expect(faraday_only_before.cache_key_for(producer_id: "p", params: {}))
        .to eq(faraday_only_after.cache_key_for(producer_id: "p", params: {}))
      # And the multi-gem composite does change, as expected.
      expect(before.cache_key_for(producer_id: "p", params: {}))
        .not_to eq(after.cache_key_for(producer_id: "p", params: {}))
    end
  end

  describe "#to_canonical_bytes" do
    it "serialises to canonical JSON with sorted keys and slots" do
      d = described_class.new(
        gems: [described_class::GemEntry.new(name: "rbs", requirement: ">= 4", locked: "4.0.0")],
        files: [described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")]
      )
      bytes = d.to_canonical_bytes
      # Slots must appear in lexicographic order regardless of construction order.
      expect(bytes).to include('"configs":[]')
      expect(bytes).to include('"dependencies":[]')
      expect(bytes).to include('"files":[')
      expect(bytes).to include('"gems":[')
      expect(bytes).to include('"plugins":[]')
      slot_order = %w[configs dependencies files gems plugins].map { |s| bytes.index(%("#{s}")) }
      expect(slot_order).to eq(slot_order.sort)
    end

    it "produces identical bytes for descriptors built in different orders" do
      a = described_class.new(
        files: [
          described_class::FileEntry.new(path: "b.rb", comparator: :digest, value: "B"),
          described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "A")
        ]
      )
      b = described_class.new(
        files: [
          described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "A"),
          described_class::FileEntry.new(path: "b.rb", comparator: :digest, value: "B")
        ]
      )
      expect(a.to_canonical_bytes).to eq(b.to_canonical_bytes)
    end
  end

  describe "#cache_key_for" do
    it "produces a stable hex SHA-256 over (schema_version, producer_id, params, descriptor)" do
      d = described_class.new
      key1 = d.cache_key_for(producer_id: "test.producer", params: { x: 1 })
      key2 = d.cache_key_for(producer_id: "test.producer", params: { x: 1 })
      expect(key1).to eq(key2)
      expect(key1).to match(/\A[0-9a-f]{64}\z/)
    end

    it "differs by producer_id" do
      d = described_class.new
      a = d.cache_key_for(producer_id: "a", params: {})
      b = d.cache_key_for(producer_id: "b", params: {})
      expect(a).not_to eq(b)
    end

    it "differs when the descriptor changes" do
      empty = described_class.new
      with_file = described_class.new(
        files: [described_class::FileEntry.new(path: "a.rb", comparator: :digest, value: "abc")]
      )
      expect(empty.cache_key_for(producer_id: "p", params: {}))
        .not_to eq(with_file.cache_key_for(producer_id: "p", params: {}))
    end

    it "is invariant to params hash key insertion order" do
      d = described_class.new
      a = d.cache_key_for(producer_id: "p", params: { a: 1, b: 2 })
      b = d.cache_key_for(producer_id: "p", params: { b: 2, a: 1 })
      expect(a).to eq(b)
    end
  end
end
