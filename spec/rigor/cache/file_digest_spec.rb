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

  # A collecting run validates the effects entry and the diagnostics entry against the same
  # dependency descriptor; under the run's stable-filesystem premise the second stat pass is pure
  # repetition, so the validation side shares one stat per path per run scope.
  # ADR-45 WD2 (#1507) — a writer re-recording an entry refreshes its tuple after a `touch`, so the next
  # validation is a stat again; it must never turn a changed file's stale entry into a fresh one.
  describe ".refresh_stat" do
    def tuple(packed)
      packed.split[1, 4]
    end

    # Moves mtime/ctime (and the inode) without changing the bytes, as a checkout does.
    def rewrite_same_bytes
      bytes = File.binread(path)
      FileUtils.rm_f(path)
      File.binwrite(path, bytes)
      File.utime(Time.now - 10, Time.now - 10, path)
    end

    it "keeps an entry whose tuple still matches" do
      entry = described_class.with_run { described_class.pack_stat(path, expected) }
      expect(described_class.with_run { described_class.refresh_stat(path, entry) }).to eq(entry)
    end

    it "re-packs a touched file, whose bytes still match, against its current stat" do
      entry = described_class.with_run { described_class.pack_stat(path, expected) }
      rewrite_same_bytes
      refreshed = described_class.with_run { described_class.refresh_stat(path, entry) }

      expect(tuple(refreshed)).not_to eq(tuple(entry))
      expect(refreshed.split.first).to eq(expected)
      allow(described_class).to receive(:hexdigest).and_call_original
      expect(described_class.stat_fresh?(path, refreshed)).to be(true)
      expect(described_class).not_to have_received(:hexdigest)
    end

    it "leaves a changed file's entry as it was, so it stays stale" do
      entry = described_class.with_run { described_class.pack_stat(path, expected) }
      File.write(path, "x = 2\n")
      File.utime(Time.now - 10, Time.now - 10, path)
      refreshed = described_class.with_run { described_class.refresh_stat(path, entry) }

      expect(refreshed).to eq(entry)
      expect(described_class.stat_fresh?(path, refreshed)).to be(false)
    end

    it "answers nil for an entry that is not a stat pack, and the entry itself for a vanished file" do
      entry = described_class.pack_stat(path, expected)
      expect(described_class.refresh_stat(path, "missing")).to be_nil
      FileUtils.rm_f(path)
      expect(described_class.refresh_stat(path, entry)).to eq(entry)
    end
  end

  describe "the validation stat memo" do
    def packed
      described_class.pack_stat(path, expected)
    end

    it "stats a path once across repeated validations inside one run scope" do
      entry = packed
      allow(File).to receive(:stat).and_call_original
      described_class.with_run do
        expect(described_class.stat_fresh?(path, entry)).to be(true)
        expect(described_class.stat_fresh?(path, entry)).to be(true)
      end
      expect(File).to have_received(:stat).with(path).once
    end

    it "stats directly when no run scope is active" do
      entry = packed
      allow(File).to receive(:stat).and_call_original
      described_class.stat_fresh?(path, entry)
      described_class.stat_fresh?(path, entry)
      expect(File).to have_received(:stat).with(path).twice
    end

    # The recording side packs the tuple a FUTURE run validates, after the content was read — it must
    # describe that moment, never an earlier probe's, or a mid-run edit could pair a pre-edit tuple
    # with post-edit content in the stored entry.
    it "keeps the recording side un-memoised even after a validation warmed the table" do
      entry = packed
      described_class.with_run do
        described_class.stat_fresh?(path, entry)
        allow(File).to receive(:stat).and_call_original
        described_class.pack_stat(path, expected)
        expect(File).to have_received(:stat).with(path).once
      end
    end
  end
end
