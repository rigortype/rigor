# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment/bundle_sig_discovery"
require "rigor/environment/lockfile_resolver"

RSpec.describe Rigor::Environment::BundleSigDiscovery do
  let(:tmpdir) { Dir.mktmpdir("rigor-bundle-discovery-spec-") }

  after { FileUtils.rm_rf(tmpdir) }

  def make_bundle_layout(root, *gem_entries)
    # gem_entries: [name, version, ruby_version] tuples; creates
    # <root>/ruby/<ruby_version>/gems/<name>-<version>/sig/ + a
    # stub .rbs file inside so the dir exists.
    gem_entries.each do |name, version, ruby_version|
      sig_dir = File.join(root, "ruby", ruby_version, "gems", "#{name}-#{version}", "sig")
      FileUtils.mkdir_p(sig_dir)
      File.write(File.join(sig_dir, "#{name}.rbs"), "module #{name.capitalize}_Stub\nend\n")
    end
  end

  describe ".discover with explicit bundle_path" do
    it "returns the sig directory for every gem under the bundle root" do
      bundle = File.join(tmpdir, "bundle")
      make_bundle_layout(
        bundle,
        ["acme_sdk", "1.2.3", "4.0.0"],
        ["widgets", "0.5", "4.0.0"]
      )
      result = described_class.discover(bundle_path: bundle, project_root: tmpdir, auto_detect: false)
      gem_names = result.map { |p| p.parent.basename.to_s }
      expect(gem_names).to contain_exactly("acme_sdk-1.2.3", "widgets-0.5")
    end

    it "resolves relative bundle_path against project_root" do
      bundle = File.join(tmpdir, "vendor", "bundle")
      make_bundle_layout(bundle, ["fizz", "0.1", "4.0.0"])
      result = described_class.discover(bundle_path: "vendor/bundle", project_root: tmpdir, auto_detect: false)
      expect(result.size).to eq(1)
      expect(result.first.to_s).to start_with(bundle)
    end

    it "returns [] when the bundle path doesn't exist" do
      result = described_class.discover(bundle_path: "/does/not/exist", project_root: tmpdir, auto_detect: false)
      expect(result).to eq([])
    end

    it "filters out gems in the SKIPPED_GEMS_BY_DEFAULT set (prism conflict prevention)" do
      bundle = File.join(tmpdir, "bundle")
      make_bundle_layout(
        bundle,
        ["prism", "1.9.0", "4.0.0"],
        ["custom_gem", "1.0", "4.0.0"]
      )
      result = described_class.discover(bundle_path: bundle, project_root: tmpdir, auto_detect: false)
      gem_names = result.map { |p| p.parent.basename.to_s }
      expect(gem_names).to eq(["custom_gem-1.0"])
    end

    it "allows the caller to override the skip set" do
      bundle = File.join(tmpdir, "bundle")
      make_bundle_layout(bundle, ["prism", "1.9.0", "4.0.0"])
      result = described_class.discover(
        bundle_path: bundle, project_root: tmpdir, auto_detect: false, skip_gems: Set.new
      )
      expect(result.size).to eq(1)
    end
  end

  describe ".discover with auto_detect" do
    it "reads BUNDLE_PATH from .bundle/config" do
      bundle = File.join(tmpdir, "custom_bundle_root")
      make_bundle_layout(bundle, ["thing", "1.0", "4.0.0"])
      FileUtils.mkdir_p(File.join(tmpdir, ".bundle"))
      File.write(File.join(tmpdir, ".bundle", "config"), "---\nBUNDLE_PATH: \"custom_bundle_root\"\n")
      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: true)
      expect(result.size).to eq(1)
      expect(result.first.to_s).to start_with(bundle)
    end

    it "falls back to vendor/bundle when .bundle/config is absent" do
      bundle = File.join(tmpdir, "vendor", "bundle")
      make_bundle_layout(bundle, ["fallback_gem", "0.1", "4.0.0"])
      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: true)
      expect(result.size).to eq(1)
    end

    it "returns [] when neither .bundle/config nor vendor/bundle resolves" do
      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: true)
      expect(result).to eq([])
    end

    it "returns [] when auto_detect is false and no explicit path" do
      bundle = File.join(tmpdir, "vendor", "bundle")
      make_bundle_layout(bundle, ["x", "1.0", "4.0.0"])
      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: false)
      expect(result).to eq([])
    end

    it "ignores a malformed .bundle/config silently" do
      bundle = File.join(tmpdir, "vendor", "bundle")
      make_bundle_layout(bundle, ["x", "1.0", "4.0.0"])
      FileUtils.mkdir_p(File.join(tmpdir, ".bundle"))
      File.write(File.join(tmpdir, ".bundle", "config"), "this is not yaml: [unclosed")
      # Falls through to vendor/bundle fallback rather than raising.
      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: true)
      expect(result.size).to eq(1)
    end
  end

  describe ".discover with a lockfile filter (O4 Layer 3)" do
    # The lockfile filter accepts a `{name => LockedGem}` map.
    # Only sig dirs whose `(name, version, platform)` matches a
    # lockfile entry survive.
    let(:locked_gem_klass) { Rigor::Environment::LockfileResolver::LockedGem }

    it "keeps only sig dirs whose (name, version) matches a lockfile entry" do
      bundle = File.join(tmpdir, "bundle")
      make_bundle_layout(
        bundle,
        ["acme_sdk", "1.2.3", "4.0.0"],
        ["widgets", "0.5", "4.0.0"],
        ["leftover", "9.9", "4.0.0"]
      )
      locked = {
        "acme_sdk" => locked_gem_klass.new(name: "acme_sdk", version: "1.2.3", platform: "ruby"),
        "widgets" => locked_gem_klass.new(name: "widgets", version: "0.5", platform: "ruby")
      }
      result = described_class.discover(
        bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: locked
      )
      gem_dirs = result.map { |p| p.parent.basename.to_s }.sort
      expect(gem_dirs).to eq(["acme_sdk-1.2.3", "widgets-0.5"])
    end

    it "drops sig dirs whose version does not match the lockfile (bundle drift)" do
      bundle = File.join(tmpdir, "bundle")
      # Bundle dir has acme_sdk-2.0.0 left over from before a
      # `bundle update`; lockfile now pins 1.2.3.
      make_bundle_layout(bundle, ["acme_sdk", "2.0.0", "4.0.0"])
      locked = {
        "acme_sdk" => locked_gem_klass.new(name: "acme_sdk", version: "1.2.3", platform: "ruby")
      }
      result = described_class.discover(
        bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: locked
      )
      expect(result).to eq([])
    end

    it "matches platform-tagged gem dirs against (version, platform)" do
      bundle = File.join(tmpdir, "bundle")
      sig_dir = File.join(bundle, "ruby", "4.0.0", "gems", "ffi-1.17.4-aarch64-linux-gnu", "sig")
      FileUtils.mkdir_p(sig_dir)
      File.write(File.join(sig_dir, "ffi.rbs"), "module Ffi_Stub end\n")
      locked = {
        "ffi" => locked_gem_klass.new(name: "ffi", version: "1.17.4", platform: "aarch64-linux-gnu")
      }
      result = described_class.discover(
        bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: locked
      )
      expect(result.size).to eq(1)
      expect(result.first.parent.basename.to_s).to eq("ffi-1.17.4-aarch64-linux-gnu")
    end

    it "falls back to the pre-Layer-3 behaviour when locked_gems is nil" do
      bundle = File.join(tmpdir, "bundle")
      make_bundle_layout(bundle, ["random_gem", "1.0", "4.0.0"])
      result = described_class.discover(
        bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: nil
      )
      expect(result.size).to eq(1)
    end

    it "falls back to the pre-Layer-3 behaviour when locked_gems is empty" do
      bundle = File.join(tmpdir, "bundle")
      make_bundle_layout(bundle, ["random_gem", "1.0", "4.0.0"])
      result = described_class.discover(
        bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: {}
      )
      expect(result.size).to eq(1)
    end

    it "skip_gems still wins over lockfile presence (prism conflict prevention)" do
      bundle = File.join(tmpdir, "bundle")
      make_bundle_layout(bundle, ["prism", "1.9.0", "4.0.0"])
      locked = {
        "prism" => locked_gem_klass.new(name: "prism", version: "1.9.0", platform: "ruby")
      }
      result = described_class.discover(
        bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: locked
      )
      expect(result).to eq([])
    end
  end

  describe "platform-suffixed gem dirs" do
    it "still strips the version + platform suffix to recover the gem name" do
      bundle = File.join(tmpdir, "bundle")
      # `ffi-1.17.4-aarch64-linux-gnu/sig` is a real Mastodon-bundle case.
      sig_dir = File.join(bundle, "ruby", "4.0.0", "gems", "ffi-1.17.4-aarch64-linux-gnu", "sig")
      FileUtils.mkdir_p(sig_dir)
      File.write(File.join(sig_dir, "ffi.rbs"), "module Ffi_Stub end\n")
      # `ffi` is NOT in the default skip set, so it should be returned.
      result = described_class.discover(bundle_path: bundle, project_root: tmpdir, auto_detect: false)
      expect(result.size).to eq(1)
      expect(result.first.parent.basename.to_s).to eq("ffi-1.17.4-aarch64-linux-gnu")
    end
  end
end
