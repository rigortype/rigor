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
    # gem_entries: [name, version, ruby_version] tuples; creates <root>/ruby/<ruby_version>/gems/<name>-<version>/sig/ +
    # a stub .rbs file inside so the dir exists.
    gem_entries.each do |name, version, ruby_version|
      sig_dir = File.join(root, "ruby", ruby_version, "gems", "#{name}-#{version}", "sig")
      FileUtils.mkdir_p(sig_dir)
      File.write(File.join(sig_dir, "#{name}.rbs"), "module #{name.capitalize}_Stub\nend\n")
    end
  end

  def make_git_bundle_layout(root, *gem_entries)
    # gem_entries: [repo_name, short_sha, ruby_version] tuples; creates
    # <root>/ruby/<ruby_version>/bundler/gems/<repo_name>-<short_sha>/sig/ — the `git:`-sourced layout
    # (`Bundler::Source::Git#install_path`: "#{base_name}-#{revision[0..11]}").
    gem_entries.each do |repo_name, short_sha, ruby_version|
      sig_dir = File.join(root, "ruby", ruby_version, "bundler", "gems", "#{repo_name}-#{short_sha}", "sig")
      FileUtils.mkdir_p(sig_dir)
      File.write(File.join(sig_dir, "#{repo_name}.rbs"), "module #{repo_name.capitalize}_Stub\nend\n")
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
      # `home:` points at an empty dir so the real user `~/.bundle/config` is not consulted — the test stays hermetic.
      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: true, home: tmpdir)
      expect(result).to eq([])
    end

    it "falls back to the user-global ~/.bundle/config path when no project-local bundle exists" do
      home = File.join(tmpdir, "home")
      bundle = File.join(tmpdir, "global_bundle_root")
      make_bundle_layout(bundle, ["globalgem", "2.0", "4.0.0"])
      FileUtils.mkdir_p(File.join(home, ".bundle"))
      File.write(File.join(home, ".bundle", "config"), "---\nBUNDLE_PATH: #{bundle.inspect}\n")

      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: true, home: home)

      expect(result.size).to eq(1)
      expect(result.first.to_s).to start_with(bundle)
    end

    it "prefers a project-local vendor/bundle over the user-global config" do
      home = File.join(tmpdir, "home")
      global_bundle = File.join(tmpdir, "global_bundle_root")
      local_bundle = File.join(tmpdir, "vendor", "bundle")
      make_bundle_layout(global_bundle, ["globalgem", "2.0", "4.0.0"])
      make_bundle_layout(local_bundle, ["localgem", "1.0", "4.0.0"])
      FileUtils.mkdir_p(File.join(home, ".bundle"))
      File.write(File.join(home, ".bundle", "config"), "---\nBUNDLE_PATH: #{global_bundle.inspect}\n")

      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: true, home: home)

      expect(result.map { |p| p.parent.basename.to_s }).to eq(["localgem-1.0"])
    end

    it "ignores a user-global config path that does not exist" do
      home = File.join(tmpdir, "home")
      FileUtils.mkdir_p(File.join(home, ".bundle"))
      File.write(File.join(home, ".bundle", "config"), "---\nBUNDLE_PATH: \"/no/such/bundle/root\"\n")

      result = described_class.discover(bundle_path: nil, project_root: tmpdir, auto_detect: true, home: home)

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
    # The lockfile filter accepts a `{name => LockedGem}` map. Only sig dirs whose `(name, version, platform)` matches a
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
      # Bundle dir has acme_sdk-2.0.0 left over from before a `bundle update`; lockfile now pins 1.2.3.
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

  describe "git-sourced gem dirs (bundler/gems/ layout, issue #611)" do
    it "discovers a sig dir installed under bundler/gems/ alongside the plain gems/ layout" do
      bundle = File.join(tmpdir, "bundle")
      make_bundle_layout(bundle, ["acme_sdk", "1.2.3", "4.0.0"])
      make_git_bundle_layout(bundle, ["tcp_user_timeout", "3a357404c083", "4.0.0"])

      result = described_class.discover(bundle_path: bundle, project_root: tmpdir, auto_detect: false)
      gem_dirs = result.map { |p| p.parent.basename.to_s }.sort
      expect(gem_dirs).to eq(["acme_sdk-1.2.3", "tcp_user_timeout-3a357404c083"])
    end

    it "recovers the gem name from a git-layout dir via gem_name_from_sig_path" do
      bundle = File.join(tmpdir, "bundle")
      make_git_bundle_layout(bundle, ["tcp_user_timeout", "3a357404c083", "4.0.0"])
      sig_dir = described_class.discover(bundle_path: bundle, project_root: tmpdir, auto_detect: false).first
      expect(described_class.gem_name_from_sig_path(sig_dir)).to eq("tcp_user_timeout")
    end

    it "recovers the gem name even when the short revision starts with a letter, not a digit" do
      # The rubygems-layout heuristic strips from the first `-<digit>`; a hex revision that happens to start
      # with a letter (a-f) must not fall through to that heuristic and swallow part of the repo name.
      bundle = File.join(tmpdir, "bundle")
      make_git_bundle_layout(bundle, ["tcp_user_timeout", "affe07404c08", "4.0.0"])
      sig_dir = described_class.discover(bundle_path: bundle, project_root: tmpdir, auto_detect: false).first
      expect(described_class.gem_name_from_sig_path(sig_dir)).to eq("tcp_user_timeout")
    end

    it "applies skip_gems to git-sourced dirs by name, same as the rubygems layout" do
      bundle = File.join(tmpdir, "bundle")
      make_git_bundle_layout(bundle, ["prism", "3a357404c083", "4.0.0"])
      result = described_class.discover(bundle_path: bundle, project_root: tmpdir, auto_detect: false)
      expect(result).to eq([])
    end

    it "does NOT match a bundler/ dir missing the intervening gems/ segment (glob precision control)" do
      bundle = File.join(tmpdir, "bundle")
      # `bundler/<name>-<sha>/sig`, one level off the real `bundler/gems/<name>-<sha>/sig` layout.
      sig_dir = File.join(bundle, "ruby", "4.0.0", "bundler", "acme_decoy-3a357404c083", "sig")
      FileUtils.mkdir_p(sig_dir)
      File.write(File.join(sig_dir, "acme_decoy.rbs"), "module AcmeDecoy_Stub end\n")

      result = described_class.discover(bundle_path: bundle, project_root: tmpdir, auto_detect: false)
      expect(result).to eq([])
    end

    describe "under the O4 Layer 3 lockfile filter" do
      let(:locked_gem_klass) { Rigor::Environment::LockfileResolver::LockedGem }

      it "keeps a git-sourced sig dir whose gem name matches a git-sourced lockfile entry" do
        bundle = File.join(tmpdir, "bundle")
        make_git_bundle_layout(bundle, ["tcp_user_timeout", "3a357404c083", "4.0.0"])
        # A git gem's lockfile entry still carries name + version (the pinned gemspec version) — just not
        # the revision, which is what the on-disk directory encodes instead.
        locked = {
          "tcp_user_timeout" => locked_gem_klass.new(
            name: "tcp_user_timeout", version: "3.0.0", platform: "ruby", git_source: true
          )
        }
        result = described_class.discover(
          bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: locked
        )
        expect(result.size).to eq(1)
      end

      it "drops a git-sourced sig dir whose lockfile entry is NOT git-sourced (stale bundler/gems/ leftover)" do
        # Regression coverage: a gem that used to be `git:`-sourced and has since moved to a released
        # version keeps its old `bundler/gems/<repo>-<sha>/` directory in the bundle tree until a `bundle
        # clean` runs. Its NAME is still present in the lockfile — now via the rubygems entry — so matching
        # by name alone would wrongly readmit the stale directory. This repo's own `vendor/bundle` hit
        # exactly this case after `binpacker` moved from `git:` to a released gem.
        bundle = File.join(tmpdir, "bundle")
        make_git_bundle_layout(bundle, ["acme_sdk", "3a357404c083", "4.0.0"])
        locked = {
          "acme_sdk" => locked_gem_klass.new(
            name: "acme_sdk", version: "1.2.3", platform: "ruby", git_source: false
          )
        }
        result = described_class.discover(
          bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: locked
        )
        expect(result).to eq([])
      end

      it "drops a git-sourced sig dir whose gem name is absent from the lockfile" do
        bundle = File.join(tmpdir, "bundle")
        make_git_bundle_layout(bundle, ["leftover_fork", "3a357404c083", "4.0.0"])
        locked = {
          "acme_sdk" => locked_gem_klass.new(name: "acme_sdk", version: "1.2.3", platform: "ruby")
        }
        result = described_class.discover(
          bundle_path: bundle, project_root: tmpdir, auto_detect: false, locked_gems: locked
        )
        expect(result).to eq([])
      end
    end
  end
end
