# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment/lockfile_resolver"

RSpec.describe Rigor::Environment::LockfileResolver do
  let(:tmpdir) { Dir.mktmpdir("rigor-lockfile-resolver-spec-") }

  # A minimal valid Gemfile.lock body. Two pure-Ruby gems + one platform-tagged gem. Matches what `bundle lock` emits.
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

    it "marks a rubygems-sourced entry as git_source: false" do
      path = write_lockfile(simple_lockfile_body)
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result.fetch("rack").git_source).to be(false)
    end

    it "records a PATH gem's directory against the lockfile's own directory, and nil for other sources" do
      body = <<~LOCKFILE
        PATH
          remote: gems/own
          specs:
            own (0.1.0)

        GIT
          remote: https://example.com/fetched.git
          revision: abc
          specs:
            fetched (2.0.0)

        #{simple_lockfile_body}
      LOCKFILE
      path = write_lockfile(body)
      result = described_class.locked_gems(lockfile_path: path, project_root: Dir.pwd, auto_detect: false)
      expect(result.fetch("own").path_source).to eq(File.join(File.expand_path(tmpdir), "gems/own"))
      expect(result.fetch("fetched").path_source).to be_nil
      expect(result.fetch("rack").path_source).to be_nil
    end

    it "keeps a multi-platform PATH gem's directory when its platform variants are folded together" do
      body = <<~LOCKFILE
        PATH
          remote: gems/own
          specs:
            own (0.1.0)
            own (0.1.0-arm64-darwin)

        #{simple_lockfile_body}
      LOCKFILE
      path = write_lockfile(body)
      own = described_class.locked_gems(lockfile_path: path, project_root: Dir.pwd, auto_detect: false).fetch("own")
      expect(own.variants.size).to eq(2)
      expect(own.path_source).to eq(File.join(File.expand_path(tmpdir), "gems/own"))
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
      # Truncating mid-section forces Bundler's state machine into an unparseable transition (the exact form varies by
      # Bundler version, so the test just asserts the contract: never crash, never return junk).
      path = write_lockfile("GEM\n  remote:")
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result).to eq({})
    end

    it "warns to stderr (naming the path and error) when the parser raises" do
      # Deterministically drive the malformed-lockfile rescue: a real corrupt body's failure mode is
      # Bundler-version-dependent, so force the raise and assert the warning the user relies on to learn why their
      # lockfile was ignored.
      require "bundler"
      path = write_lockfile(simple_lockfile_body)
      allow(Bundler::LockfileParser).to receive(:new).and_raise(RuntimeError.new("boom"))

      result = nil
      expect do
        result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      end.to output(/ignoring malformed .*Gemfile\.lock.*RuntimeError.*boom/).to_stderr
      expect(result).to eq({})
    end

    # #1064 — inside a Ractor worker Bundler's parser raises `Ractor::IsolationError` on a lockfile that is fine.
    # Driven by a stub rather than a real Ractor: the wording is what is under test, and the Ractor pool itself
    # never reaches this rescue any more (its coordinator resolves the lockfile and hands the map in).
    it "does not call a Ractor isolation failure a malformed lockfile" do
      require "bundler"
      path = write_lockfile(simple_lockfile_body)
      allow(Bundler::LockfileParser).to receive(:new).and_raise(Ractor::IsolationError.new("can not access"))

      warning = /rigor: cannot read \S*Gemfile\.lock inside a Ractor worker.*Ractor::IsolationError: can not access\)\n/
      results = []
      expect do
        results << described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
        results << described_class.direct_dependency_names(lockfile_path: path, project_root: tmpdir,
                                                           auto_detect: false)
      end.to output(/\A(?:#{warning}){2}\z/).to_stderr
      expect(results).to eq([{}, Set.new])
    end

    it "warns to stderr and returns empty when bundler cannot be required" do
      # The LoadError rescue: bundler is always present in the test env, so stub the require to drive the branch that
      # tells the user their lockfile could not be read.
      path = write_lockfile(simple_lockfile_body)
      allow(described_class).to receive(:require).with("bundler").and_raise(LoadError.new("no bundler"))

      result = nil
      expect do
        result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      end.to output(/cannot read .*Gemfile\.lock.*bundler is not available.*no bundler/).to_stderr
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
      # The active spec depends on which platform Bundler selected at parse time; either "ruby" or the platform-tagged
      # form is acceptable. The point is the resolver returns *some* consistent platform string.
      expect(ffi.platform).to be_a(String)
      expect(ffi.platform).not_to be_empty
    end

    # #1844 — each platform variant of a name used to overwrite the previous one, so the result named only the
    # last-listed platform and the host's own `<name>-<version>-<platform>` install was filtered out of discovery.
    it "keeps every locked platform variant of a name" do
      path = write_lockfile(<<~LOCKFILE)
        GEM
          remote: https://rubygems.org/
          specs:
            ffi (1.17.4)
            ffi (1.17.4-aarch64-linux-gnu)
            ffi (1.17.4-arm64-darwin)
            ffi (1.17.4-x86_64-linux-gnu)

        PLATFORMS
          aarch64-linux-gnu
          arm64-darwin
          ruby
          x86_64-linux-gnu

        DEPENDENCIES
          ffi

        BUNDLED WITH
           2.5.3
      LOCKFILE
      ffi = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false).fetch("ffi")
      expect(ffi.variants).to contain_exactly(
        ["1.17.4", "ruby"], ["1.17.4", "aarch64-linux-gnu"], ["1.17.4", "arm64-darwin"], ["1.17.4", "x86_64-linux-gnu"]
      )
      expect([ffi.version, ffi.platform]).to eq(%w[1.17.4 ruby])
      expect(Ractor.shareable?(ffi)).to be(true)
    end

    it "picks the last variant as the representative when no ruby variant is locked" do
      path = write_lockfile(<<~LOCKFILE)
        GEM
          remote: https://rubygems.org/
          specs:
            nokogiri (1.16.0-arm64-darwin)
            nokogiri (1.16.0-x86_64-linux-gnu)

        PLATFORMS
          arm64-darwin
          x86_64-linux-gnu

        DEPENDENCIES
          nokogiri

        BUNDLED WITH
           2.5.3
      LOCKFILE
      nokogiri = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
                                .fetch("nokogiri")
      expect(nokogiri.variants).to contain_exactly(%w[1.16.0 arm64-darwin], %w[1.16.0 x86_64-linux-gnu])
      expect(nokogiri.variants).to include([nokogiri.version, nokogiri.platform])
    end

    it "rejects a representative that is not one of the variants" do
      expect do
        described_class::LockedGem.new(name: "ffi", version: "1", platform: "ruby", variants: [%w[2 ruby]])
      end.to raise_error(ArgumentError, /not one of its variants/)
    end
  end

  describe ".locked_gems with a GIT-sourced entry (issue #611)" do
    let(:git_and_gem_lockfile_body) do
      <<~LOCKFILE
        GIT
          remote: https://example.com/acme_git_fork.git
          revision: 3a357404c083916d379104428a3d51c8a25f7d0
          specs:
            acme_git_fork (3.0.0)

        GEM
          remote: https://rubygems.org/
          specs:
            rack (3.0.2)

        PLATFORMS
          ruby

        DEPENDENCIES
          acme_git_fork!
          rack

        BUNDLED WITH
           2.5.3
      LOCKFILE
    end

    it "marks a GIT-stanza entry as git_source: true, still carrying its (name, version)" do
      path = write_lockfile(git_and_gem_lockfile_body)
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      fork = result.fetch("acme_git_fork")
      expect(fork.git_source).to be(true)
      expect(fork.version).to eq("3.0.0")
    end

    it "leaves a same-lockfile GEM-stanza entry marked git_source: false" do
      path = write_lockfile(git_and_gem_lockfile_body)
      result = described_class.locked_gems(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result.fetch("rack").git_source).to be(false)
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

  describe ".resolve_lockfile_path with a `~/` lockfile" do
    before { allow(Dir).to receive(:home).and_return(tmpdir) }

    def resolve
      described_class.resolve_lockfile_path(lockfile_path: "~/x.lock", project_root: tmpdir, auto_detect: false)
    end

    it "resolves under the home directory, and not at all while the file is absent" do
      expect(described_class.configured_lockfile_path("~/x.lock")).to eq(File.join(tmpdir, "x.lock"))
      expect(resolve).to be_nil

      File.write(File.join(tmpdir, "x.lock"), "x")
      expect(resolve.to_s).to eq(File.join(tmpdir, "x.lock"))
    end
  end
end
