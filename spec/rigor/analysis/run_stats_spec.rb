# frozen_string_literal: true

require "rigor/analysis/run_stats"

RSpec.describe Rigor::Analysis::RunStats do
  describe ".partition_classes" do
    it "returns (0, total) when no signature paths are configured" do
      paths = { "::Foo" => "/proj/sig/foo.rbs", "::Bar" => "/gems/rbs/core/object.rbs" }.freeze
      project, bundled = described_class.partition_classes(
        class_decl_paths: paths, signature_paths: []
      )
      expect(project).to eq(0)
      expect(bundled).to eq(2)
    end

    it "buckets classes whose source path lives under signature_paths as project-sig" do
      Dir.mktmpdir do |dir|
        sig_dir = File.join(dir, "sig")
        FileUtils.mkdir_p(sig_dir)
        paths = {
          "::Project::Foo" => File.join(sig_dir, "foo.rbs"),
          "::Project::Bar" => File.join(sig_dir, "nested", "bar.rbs"),
          "::Object" => "/gems/rbs/core/object.rbs"
        }.freeze

        project, bundled = described_class.partition_classes(
          class_decl_paths: paths, signature_paths: [sig_dir]
        )
        expect(project).to eq(2)
        expect(bundled).to eq(1)
      end
    end

    it "handles Pathname signature_paths" do
      Dir.mktmpdir do |dir|
        sig_dir = Pathname.new(dir) / "sig"
        sig_dir.mkpath
        paths = { "::Foo" => (sig_dir / "foo.rbs").to_s }.freeze
        project, _bundled = described_class.partition_classes(
          class_decl_paths: paths, signature_paths: [sig_dir]
        )
        expect(project).to eq(1)
      end
    end
  end

  describe ".peak_rss_bytes" do
    it "returns a non-negative integer (bytes after unit normalisation)" do
      bytes = described_class.peak_rss_bytes
      expect(bytes).to be_a(Integer)
      expect(bytes).to be >= 0
    end
  end

  describe ".attribution_available?" do
    it "returns false when every entry carries the cached sentinel" do
      paths = { "::Foo" => described_class::CACHED_SENTINEL, "::Bar" => described_class::CACHED_SENTINEL }
      expect(described_class.attribution_available?(class_decl_paths: paths)).to be(false)
    end

    it "returns true when at least one entry carries a real source path" do
      paths = { "::Foo" => "/proj/sig/foo.rbs", "::Bar" => described_class::CACHED_SENTINEL }
      expect(described_class.attribution_available?(class_decl_paths: paths)).to be(true)
    end

    it "returns false when the snapshot is empty" do
      expect(described_class.attribution_available?(class_decl_paths: {})).to be(false)
    end
  end

  describe "#format" do
    let(:stats) do
      described_class.new(
        wall_seconds: 1.234,
        peak_rss_bytes: 245 * 1024 * 1024,
        target_files: 42,
        rbs_classes_total: 1284,
        rbs_classes_project_sig: 14,
        rbs_classes_bundled: 1270,
        gem_walk_classes: 460,
        gem_walk_gems: 3
      )
    end

    it "renders a multi-section summary with every captured field" do
      io = StringIO.new
      stats.format(io)
      out = io.string

      expect(out).to include("Check targets")
      expect(out).to include("Ruby source files: 42")
      expect(out).to include("Type universe")
      expect(out).to include("RBS classes available: 1284")
      expect(out).to include("project sig/:        14")
      expect(out).to include("bundled (core+stdlib+gems): 1270")
      expect(out).to include("Gem source-walk classes: 460")
      expect(out).to include("3 gems")
      expect(out).to include("Wall time:   1.23s")
      expect(out).to include("Memory peak: 245.0 MB")
    end

    it "elides the gem source-walk row when no opt-in gems contributed" do
      io = StringIO.new
      described_class.new(
        wall_seconds: 0.5, peak_rss_bytes: 10 * 1024 * 1024,
        target_files: 1,
        rbs_classes_total: 1, rbs_classes_project_sig: 0, rbs_classes_bundled: 1,
        gem_walk_classes: 0, gem_walk_gems: 0
      ).format(io)

      expect(io.string).not_to include("Gem source-walk")
    end

    it "prints `unavailable` when peak_rss_bytes is nil" do
      io = StringIO.new
      described_class.new(
        wall_seconds: 0.5, peak_rss_bytes: nil,
        target_files: 1,
        rbs_classes_total: 1, rbs_classes_project_sig: 0, rbs_classes_bundled: 1,
        gem_walk_classes: 0, gem_walk_gems: 0
      ).format(io)

      expect(io.string).to include("Memory peak: unavailable")
    end

    it "elides the breakdown row + notes the cache-hit limitation when attribution unavailable" do
      io = StringIO.new
      described_class.new(
        wall_seconds: 0.5, peak_rss_bytes: 10 * 1024 * 1024,
        target_files: 1,
        rbs_classes_total: 1134, rbs_classes_project_sig: 0, rbs_classes_bundled: 1134,
        gem_walk_classes: 0, gem_walk_gems: 0,
        rbs_attribution_available: false
      ).format(io)

      expect(io.string).to include("RBS classes available: 1134")
      expect(io.string).not_to include("project sig/:")
      expect(io.string).to include("source attribution unavailable")
    end
  end

  describe "#to_h" do
    it "exposes every field as a Ruby Hash for the JSON formatter" do
      stats = described_class.new(
        wall_seconds: 1.0, peak_rss_bytes: 1024,
        target_files: 3,
        rbs_classes_total: 100, rbs_classes_project_sig: 5, rbs_classes_bundled: 95,
        gem_walk_classes: 10, gem_walk_gems: 1
      )
      expect(stats.to_h).to include(
        target_files: 3,
        rbs_classes_total: 100,
        rbs_classes_project_sig: 5,
        rbs_classes_bundled: 95,
        gem_walk_classes: 10,
        gem_walk_gems: 1,
        wall_seconds: 1.0,
        peak_rss_bytes: 1024
      )
    end
  end
end
