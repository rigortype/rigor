# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "digest"
require "rigor/cache/file_digest"

RSpec.describe Rigor::Cache::FileDigest do
  let(:tmpdir) { Dir.mktmpdir("rigor-file-digest-spec-") }
  let(:path) { File.join(tmpdir, "a.rb") }

  before { File.write(path, "x = 1\n") }
  after { FileUtils.rm_rf(tmpdir) }

  def expected
    Digest::SHA256.file(path).hexdigest
  end

  describe ".hexdigest" do
    it "returns the file's SHA-256 hex digest" do
      expect(described_class.hexdigest(path)).to eq(expected)
    end

    it "digests directly (no memo) when no run scope is active" do
      allow(Digest::SHA256).to receive(:file).and_call_original
      described_class.hexdigest(path)
      described_class.hexdigest(path)
      # Without an active per-run table, every call recomputes.
      expect(Digest::SHA256).to have_received(:file).with(path).twice
    end

    it "digests a path at most once inside a run scope (memo dedup)" do
      exp = expected # capture before mocking so the assertion below adds no digest call
      described_class.with_run do
        allow(Digest::SHA256).to receive(:file).and_call_original
        first = described_class.hexdigest(path)
        second = described_class.hexdigest(path)
        expect(first).to eq(exp)
        expect(second).to eq(first)
        expect(Digest::SHA256).to have_received(:file).with(path).once
      end
    end

    it "returns identical digests across memoised and direct calls" do
      memoised = described_class.with_run { described_class.hexdigest(path) }
      expect(memoised).to eq(described_class.hexdigest(path))
    end
  end

  describe ".with_run" do
    it "installs a fresh table per scope (a file edited between runs re-digests)" do
      first = described_class.with_run { described_class.hexdigest(path) }
      File.write(path, "y = 2\n")
      second = described_class.with_run { described_class.hexdigest(path) }
      expect(second).not_to eq(first)
      expect(second).to eq(expected)
    end

    it "restores the previous table on exit, even on a raise" do
      described_class.with_run do
        outer = described_class.hexdigest(path)
        begin
          described_class.with_run { raise "boom" }
        rescue RuntimeError
          nil
        end
        # The inner scope's failure did not disturb the outer scope's memo.
        allow(Digest::SHA256).to receive(:file).and_call_original
        expect(described_class.hexdigest(path)).to eq(outer)
        expect(Digest::SHA256).not_to have_received(:file)
      end
    end

    it "does not leak the table after the block returns" do
      described_class.with_run { described_class.hexdigest(path) }
      allow(Digest::SHA256).to receive(:file).and_call_original
      described_class.hexdigest(path)
      described_class.hexdigest(path)
      # Back outside a run scope: no memo, both calls recompute.
      expect(Digest::SHA256).to have_received(:file).with(path).twice
    end

    it "propagates a read failure without memoising it" do
      missing = File.join(tmpdir, "gone.rb")
      described_class.with_run do
        expect { described_class.hexdigest(missing) }.to raise_error(SystemCallError)
        File.write(missing, "z = 3\n")
        # The earlier failure was not cached, so a now-readable path digests successfully.
        expect(described_class.hexdigest(missing)).to eq(Digest::SHA256.file(missing).hexdigest)
      end
    end
  end
end
