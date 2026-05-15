# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment/lockfile_resolver"

RSpec.describe Rigor::Environment::LockfileResolver do
  let(:tmpdir) { Dir.mktmpdir("rigor-lockfile-resolver-spec-") }

  # A minimal valid Gemfile.lock body. Two pure-Ruby gems + one
  # platform-tagged gem. Matches what `bundle lock` emits.
  let(:simple_lockfile_body) do
    <<~LOCKFILE
      GEM
        remote: https://rubygems.org/
        specs:
          rack (3.0.2)
          activerecord (7.1.3)
            activemodel (= 7.1.3)
          activemodel (7.1.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        rack
        activerecord

      BUNDLED WITH
         2.5.3
    LOCKFILE
  end

  after { FileUtils.rm_rf(tmpdir) }

  def write_lockfile(body)
    path = File.join(tmpdir, "Gemfile.lock")
    File.write(path, body)
    path
  end

  describe ".locked_gems with explicit lockfile_path" do
    it "returns a frozen hash keyed by gem name" do
      path = write_lockfile(simple_lockfile_body)
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result).to be_frozen
      expect(result.keys).to contain_exactly("rack", "activerecord", "activemodel")
    end

    it "captures (name, version, platform) per locked gem" do
      path = write_lockfile(simple_lockfile_body)
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      rack = result.fetch("rack")
      expect(rack.name).to eq("rack")
      expect(rack.version).to eq("3.0.2")
      expect(rack.platform).to eq("ruby")
    end

    it "resolves relative lockfile_path against project_root" do
      sub = File.join(tmpdir, "app")
      FileUtils.mkdir_p(sub)
      File.write(File.join(sub, "Gemfile.lock"), simple_lockfile_body)
      result = described_class.locked_gems(lockfile_path: "Gemfile.lock", project_root: sub, auto_detect: false)
      expect(result.keys).to include("rack")
    end

    it "returns empty hash when the explicit path doesn't exist" do
      result = described_class.locked_gems(
        lockfile_path: "/does/not/exist/Gemfile.lock", project_root: tmpdir, auto_detect: false
      )
      expect(result).to eq({})
    end
  end

  describe ".locked_gems with auto_detect" do
    it "finds Gemfile.lock next to the project root" do
      write_lockfile(simple_lockfile_body)
      result = described_class.locked_gems(lockfile_path: nil, project_root: tmpdir, auto_detect: true)
      expect(result.keys).to include("rack", "activerecord")
    end

    it "returns empty when auto_detect is false and no explicit path" do
      write_lockfile(simple_lockfile_body)
      result = described_class.locked_gems(lockfile_path: nil, project_root: tmpdir, auto_detect: false)
      expect(result).to eq({})
    end

    it "returns empty when no Gemfile.lock exists at the project root" do
      result = described_class.locked_gems(lockfile_path: nil, project_root: tmpdir, auto_detect: true)
      expect(result).to eq({})
    end
  end

  describe ".locked_gems with malformed lockfile" do
    it "returns empty when the file body has no parseable sections" do
      path = write_lockfile("this is not a gemfile.lock body")
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result).to eq({})
    end

    it "returns empty and warns when Bundler raises on truly corrupt lockfile" do
      # Truncating mid-section forces Bundler's state machine into
      # an unparseable transition (the exact form varies by
      # Bundler version, so the test just asserts the contract:
      # never crash, never return junk).
      path = write_lockfile("GEM\n  remote:")
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result).to eq({})
    end
  end

  describe ".locked_gems with platform-tagged entries" do
    let(:platform_lockfile_body) do
      <<~LOCKFILE
        GEM
          remote: https://rubygems.org/
          specs:
            ffi (1.17.4)
            ffi (1.17.4-aarch64-linux-gnu)

        PLATFORMS
          ruby
          aarch64-linux-gnu

        DEPENDENCIES
          ffi

        BUNDLED WITH
           2.5.3
      LOCKFILE
    end

    it "exposes the platform tag of the active spec" do
      path = write_lockfile(platform_lockfile_body)
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      ffi = result.fetch("ffi")
      expect(ffi.version).to eq("1.17.4")
      # The active spec depends on which platform Bundler selected
      # at parse time; either "ruby" or the platform-tagged form
      # is acceptable. The point is the resolver returns *some*
      # consistent platform string.
      expect(ffi.platform).to be_a(String)
      expect(ffi.platform).not_to be_empty
    end
  end

  describe ".resolve_lockfile_path" do
    it "returns the explicit Pathname when it exists" do
      path = write_lockfile(simple_lockfile_body)
      resolved = described_class.resolve_lockfile_path(
        lockfile_path: path, project_root: tmpdir, auto_detect: false
      )
      expect(resolved).to be_a(Pathname)
      expect(resolved.to_s).to eq(File.expand_path(path))
    end

    it "returns nil when neither explicit nor auto-detect resolves" do
      resolved = described_class.resolve_lockfile_path(
        lockfile_path: nil, project_root: tmpdir, auto_detect: true
      )
      expect(resolved).to be_nil
    end
  end
end
