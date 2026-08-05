# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/cache/engine_source"

# Issue #285 — the engine's own source as a cache-key slot. Two regimes, and the whole design rests on
# getting the boundary between them right: a released gem must be untouched (`nil`, no walk), a working
# tree must be identified by its bytes, and anything that cannot be identified must raise so the caller
# disables the cache rather than falling back to the version-only key.
RSpec.describe Rigor::Cache::EngineSource do
  # A stand-in engine tree, so an example can EDIT engine source without touching this checkout.
  def write_engine(root, body)
    FileUtils.mkdir_p(File.join(root, "lib", "rigor", "inference"))
    File.write(File.join(root, "lib", "rigor", "inference", "narrowing.rb"), body)
    root
  end

  describe ".version_pinned?" do
    it "recognises a RubyGems install, where VERSION already pins the bytes" do
      expect(described_class.version_pinned?("/gems/#{described_class::GEM_NAME}-#{Rigor::VERSION}"))
        .to be(true)
    end

    it "rejects an install of a DIFFERENT version, and a directory that is not a gem install" do
      expect(described_class.version_pinned?("/gems/#{described_class::GEM_NAME}-9.9.9")).to be(false)
      expect(described_class.version_pinned?("/src/#{described_class::GEM_NAME}-#{Rigor::VERSION}"))
        .to be(false)
    end

    # `bundle add rigor, github:` checks out to `bundler/gems/<repo>-<sha>`: the parent is `gems`, so only
    # the basename tells a tracked branch from a release. Two commits share one Rigor::VERSION there.
    it "rejects a Bundler git checkout living under a `gems` parent" do
      expect(described_class.version_pinned?("/bundler/gems/rigor-0123456789ab")).to be(false)
    end

    # Contrived, but the predicate is the only thing standing between a working tree and a stale serve.
    it "rejects a release-shaped path that is actually a working tree" do
      Dir.mktmpdir("rigor-engine-source-") do |dir|
        root = File.join(dir, "gems", "#{described_class::GEM_NAME}-#{Rigor::VERSION}")
        FileUtils.mkdir_p(File.join(root, ".git"))

        expect(described_class.version_pinned?(root)).to be(false)
      end
    end
  end

  describe ".identity" do
    it "answers nil for a version-pinned tree, so a released gem's key gains no slot at all" do
      Dir.mktmpdir("rigor-engine-source-") do |dir|
        root = write_engine(File.join(dir, "gems", "#{described_class::GEM_NAME}-#{Rigor::VERSION}"), "# v1\n")

        expect(described_class.identity(root)).to be_nil
      end
    end

    it "is stable across calls when nothing moved, and changes when engine source is edited" do
      Dir.mktmpdir("rigor-engine-source-") do |dir|
        root = write_engine(File.join(dir, "checkout"), "# v1\n")
        before = described_class.identity(root)

        expect(described_class.identity(root)).to eq(before)

        File.write(File.join(root, "lib", "rigor", "inference", "narrowing.rb"), "# v2\n")
        expect(described_class.identity(root)).not_to eq(before)
      end
    end

    it "sees a NEW engine file and a deleted one, not only an edit to a known one" do
      Dir.mktmpdir("rigor-engine-source-") do |dir|
        root = write_engine(File.join(dir, "checkout"), "# v1\n")
        before = described_class.identity(root)

        added = File.join(root, "lib", "rigor", "inference", "extra.rb")
        File.write(added, "# added\n")
        expect(described_class.identity(root)).not_to eq(before)

        FileUtils.rm(added)
        expect(described_class.identity(root)).to eq(before)
      end
    end

    it "covers `plugins/` as well as `lib/` — a recogniser edit moves diagnostics too" do
      Dir.mktmpdir("rigor-engine-source-") do |dir|
        root = write_engine(File.join(dir, "checkout"), "# v1\n")
        plugin = File.join(root, "plugins", "rigor-units", "lib")
        FileUtils.mkdir_p(plugin)
        File.write(File.join(plugin, "units.rb"), "# p1\n")
        before = described_class.identity(root)

        File.write(File.join(plugin, "units.rb"), "# p2\n")
        expect(described_class.identity(root)).not_to eq(before)
      end
    end

    # The digest keys on ROOT-RELATIVE paths, so re-cloning or moving a checkout — and, more to the point,
    # a fresh CI checkout of the same commit — keeps the same identity. A stat tuple could not do this,
    # which is why {Descriptor::FileEntry} bars stat data from a cache KEY.
    it "is independent of where the checkout lives" do
      Dir.mktmpdir("rigor-engine-source-") do |dir|
        here = write_engine(File.join(dir, "here"), "# v1\n")
        there = write_engine(File.join(dir, "somewhere", "else"), "# v1\n")

        expect(described_class.identity(there)).to eq(described_class.identity(here))
      end
    end

    it "raises rather than answering a weaker key when there is no engine source to read" do
      Dir.mktmpdir("rigor-engine-source-") do |dir|
        expect { described_class.identity(File.join(dir, "nowhere")) }
          .to raise_error(described_class::Unavailable)

        empty = File.join(dir, "empty")
        FileUtils.mkdir_p(File.join(empty, "lib"))
        expect { described_class.identity(empty) }.to raise_error(described_class::Unavailable)
      end
    end
  end

  # The examples above all relocate the tree; this one pins the DEFAULT, so the seam they use cannot hide a
  # root that points somewhere absurd.
  it "identifies this checkout by its source, since a checkout is not version-pinned" do
    expect(described_class.root).to eq(File.expand_path("../../..", __dir__))
    expect(described_class.version_pinned?(described_class.root)).to be(false)
    expect(described_class.identity).to match(/\A[0-9a-f]{64}\z/)
  end
end
