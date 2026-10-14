# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #530 item 3 — the stand-in gem set for a project with no `Gemfile.lock`.
RSpec.describe Rigor::Environment::InstalledGemSet do
  # `<bundle>/ruby/X.Y.Z/gems/<name>-<version>/` with nothing in it: this resolver reads directory names,
  # not contents.
  def write_bundle(root, dirs)
    dirs.each { |name| FileUtils.mkdir_p(File.join(root, "ruby", "4.0.0", "gems", name)) }
    root
  end

  it "reads the target's own bundle tree in preference to the host's installed gems" do
    Dir.mktmpdir do |root|
      write_bundle(root, %w[faraday-2.9.0 rubocop-ast-1.30.0])
      gems = described_class.gems(bundle_path: root)

      expect(gems.keys).to contain_exactly("faraday", "rubocop-ast")
      expect(gems.fetch("rubocop-ast").version).to eq("1.30.0")
    end
  end

  it "keeps a platform-tagged directory, recording its platform as the gem's variant" do
    # A platform build (`commonmarker-2.10.0-arm64-darwin`) ships the same `lib/<name>.rb` as the `ruby` one;
    # the variant is what lets the constant index find the directory again.
    Dir.mktmpdir do |root|
      write_bundle(root, ["ffi-1.17.4-aarch64-linux-gnu", "faraday-2.9.0"])
      gems = described_class.gems(bundle_path: root)

      expect(gems.keys).to contain_exactly("ffi", "faraday")
      expect(gems.fetch("ffi").variants).to eq([%w[1.17.4 aarch64-linux-gnu]])
      expect(gems.fetch("faraday").variants).to eq([%w[2.9.0 ruby]])
    end
  end

  it "keeps every installed directory of one gem as a variant" do
    Dir.mktmpdir do |root|
      write_bundle(root, %w[nokogiri-1.16.0 nokogiri-1.16.0-x86_64-linux-gnu])
      expect(described_class.gems(bundle_path: root).fetch("nokogiri").variants)
        .to contain_exactly(%w[1.16.0 ruby], %w[1.16.0 x86_64-linux-gnu])
    end
  end

  describe ".split_install_dirname" do
    {
      "faraday-2.9.0" => %w[faraday 2.9.0 ruby],
      "rubocop-ast-1.30.0" => %w[rubocop-ast 1.30.0 ruby],
      "ffi-1.17.4-arm64-darwin" => %w[ffi 1.17.4 arm64-darwin],
      "nokogiri-1.16.0-x86_64-linux-gnu" => %w[nokogiri 1.16.0 x86_64-linux-gnu],
      "sorbet-static-0.6.13466-universal-darwin" => %w[sorbet-static 0.6.13466 universal-darwin],
      "jruby-openssl-0.15.0-java" => %w[jruby-openssl 0.15.0 java],
      # A trailing OS version must not be read as the gem version of a longer name.
      "foo-1.0-universal-darwin-23" => %w[foo 1.0 universal-darwin-23],
      # A digit-led segment inside the name is not the version, with or without a platform tail.
      "foo-2fa-1.0" => %w[foo-2fa 1.0 ruby],
      "foo-2fa-1.0-x86_64-linux" => %w[foo-2fa 1.0 x86_64-linux]
    }.each do |basename, expected|
      it "splits #{basename}" do
        expect(described_class.split_install_dirname(basename)).to eq(expected)
      end
    end

    it "declines a tail RubyGems does not recognise as a platform rather than guessing where the name ends" do
      expect(described_class.split_install_dirname("bar-1.0-weird-tag")).to be_nil
      expect(described_class.split_install_dirname("no-version")).to be_nil
    end
  end

  it "falls back to the installed specs when no bundle tree resolves" do
    # Whatever Ruby is running this must at least see itself, so the fallback is non-empty and shaped for
    # `RbsCoverageReport.classify`.
    gems = described_class.gems(bundle_path: nil)

    expect(gems).not_to be_empty
    expect(gems.each_value.first).to be_a(Rigor::Environment::LockfileResolver::LockedGem)
  end

  it "keeps the highest installed version when a gem is installed more than once" do
    stubs = [
      instance_double(Gem::StubSpecification, name: "faraday", version: Gem::Version.new("2.9.0")),
      instance_double(Gem::StubSpecification, name: "faraday", version: Gem::Version.new("2.10.0")),
      instance_double(Gem::StubSpecification, name: "faraday", version: Gem::Version.new("2.1.0"))
    ]
    allow(Gem::Specification).to receive(:stubs).and_return(stubs)

    expect(described_class.gems(bundle_path: nil).fetch("faraday").version).to eq("2.10.0")
  end

  it "yields nothing rather than a guess when the bundle root does not exist" do
    allow(Gem::Specification).to receive(:stubs).and_return([])
    expect(described_class.gems(bundle_path: "/nonexistent/bundle")).to be_empty
  end
end
