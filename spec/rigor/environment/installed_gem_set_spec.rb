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

  it "skips a platform-tagged directory rather than guessing where the name ends" do
    # The must-still-resolve counterpart rides along: the pure-Ruby sibling in the same tree is still
    # claimed, so a change that dropped everything would not pass.
    Dir.mktmpdir do |root|
      write_bundle(root, ["ffi-1.17.4-aarch64-linux-gnu", "faraday-2.9.0"])
      expect(described_class.gems(bundle_path: root).keys).to eq(["faraday"])
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
