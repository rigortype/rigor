# frozen_string_literal: true

require "spec_helper"
require "rigor/environment/rbs_coverage_report"
require "rigor/environment/lockfile_resolver"
require "rigor/environment/bundle_sig_discovery"

RSpec.describe Rigor::Environment::RbsCoverageReport do
  let(:locked_gem_klass) { Rigor::Environment::LockfileResolver::LockedGem }

  def locked(name, version, platform: "ruby")
    locked_gem_klass.new(name: name, version: version, platform: platform)
  end

  describe ".classify" do
    it "tags gems whose name matches DEFAULT_LIBRARIES as :default_library" do
      locked_gems = { "json" => locked("json", "2.0") }
      rows = described_class.classify(
        locked_gems: locked_gems,
        default_libraries: %w[json yaml],
        bundle_sig_paths: [],
        rbs_collection_paths: []
      )
      expect(rows.size).to eq(1)
      expect(rows.first.source).to eq(:default_library)
    end

    it "tags gems whose name matches VENDORED_GEM_NAMES as :vendored_gem_sig" do
      locked_gems = { "pg" => locked("pg", "1.5") }
      rows = described_class.classify(
        locked_gems: locked_gems,
        default_libraries: [],
        bundle_sig_paths: [],
        rbs_collection_paths: []
      )
      expect(rows.first.source).to eq(:vendored_gem_sig)
    end

    it "tags gems whose sig directory was discovered in the bundle as :bundle_sig" do
      locked_gems = { "rack" => locked("rack", "3.0") }
      # BundleSigDiscovery returns `<bundle>/.../gems/rack-3.0/sig/`
      bundle_path = Pathname.new("/tmp/bundle/ruby/4.0.0/gems/rack-3.0/sig")
      rows = described_class.classify(
        locked_gems: locked_gems,
        default_libraries: [],
        bundle_sig_paths: [bundle_path],
        rbs_collection_paths: []
      )
      expect(rows.first.source).to eq(:bundle_sig)
    end

    it "tags gems whose collection directory was discovered as :rbs_collection" do
      locked_gems = { "activerecord" => locked("activerecord", "7.1") }
      # RbsCollectionDiscovery returns `<collection>/<name>/<version>/`
      collection_path = Pathname.new("/tmp/.gem_rbs_collection/activerecord/7.1")
      rows = described_class.classify(
        locked_gems: locked_gems,
        default_libraries: [],
        bundle_sig_paths: [],
        rbs_collection_paths: [collection_path]
      )
      expect(rows.first.source).to eq(:rbs_collection)
    end

    it "tags uncovered gems as :missing" do
      locked_gems = { "rare_gem" => locked("rare_gem", "0.1") }
      rows = described_class.classify(
        locked_gems: locked_gems,
        default_libraries: %w[json],
        bundle_sig_paths: [],
        rbs_collection_paths: []
      )
      expect(rows.first.source).to eq(:missing)
    end

    it "returns rows sorted by gem name for deterministic output" do
      locked_gems = {
        "zoo" => locked("zoo", "1.0"),
        "alpha" => locked("alpha", "1.0"),
        "mid" => locked("mid", "1.0")
      }
      rows = described_class.classify(
        locked_gems: locked_gems, default_libraries: [],
        bundle_sig_paths: [], rbs_collection_paths: []
      )
      expect(rows.map(&:gem_name)).to eq(%w[alpha mid zoo])
    end

    it "respects DEFAULT_LIBRARIES precedence over VENDORED_GEM_NAMES (DEFAULT wins)" do
      # If a gem is in both lists, the order in `classify` puts
      # default_library first. In practice this is a theoretical
      # case — DEFAULT_LIBRARIES and vendored_gem_sigs are
      # curated to not overlap — but the contract is stable.
      locked_gems = { "json" => locked("json", "2.0") }
      rows = described_class.classify(
        locked_gems: locked_gems,
        default_libraries: ["json"],
        bundle_sig_paths: [],
        rbs_collection_paths: []
      )
      expect(rows.first.source).to eq(:default_library)
    end
  end

  describe ".missing" do
    it "filters classify output to :missing rows only" do
      rows = [
        described_class::Coverage.new(gem_name: "a", version: "1", source: :default_library),
        described_class::Coverage.new(gem_name: "b", version: "1", source: :missing),
        described_class::Coverage.new(gem_name: "c", version: "1", source: :missing)
      ]
      expect(described_class.missing(rows).map(&:gem_name)).to eq(%w[b c])
    end
  end

  describe "VENDORED_GEM_NAMES" do
    it "matches the gem names under data/vendored_gem_sigs/" do
      vendored_dir = File.expand_path("../../../data/vendored_gem_sigs", __dir__)
      on_disk = Dir.children(vendored_dir).reject { |n| n == "README.md" }.to_set
      expect(described_class::VENDORED_GEM_NAMES).to eq(on_disk)
    end
  end
end
