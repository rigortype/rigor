# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/environment"

RSpec.describe Rigor::Environment::ProjectPathGems do
  def gem_at(dir, name: "own")
    { name => Rigor::Environment::LockfileResolver::LockedGem.new(
      name: name, version: "1.0.0", platform: "ruby", path_source: dir
    ) }
  end

  it "does not count a remote that only shares a paths: entry's prefix (/proj/lib2 against /proj/lib)" do
    expect(described_class.names(gem_at("/proj/lib2"), paths: ["/proj/lib"])).to be_empty
  end

  it "counts a remote under a paths: entry of / without spelling a // prefix" do
    expect(described_class.names(gem_at("/proj/own"), paths: ["/"])).to eq(Set["own"])
  end

  it "matches a paths: entry spelled through a symlink against the gem's real directory" do
    Dir.mktmpdir("rigor-project-path-gems-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "gems/own/lib"))
      File.symlink(File.join(dir, "gems/own/lib"), File.join(dir, "linked"))
      expect(described_class.names(gem_at(File.join(dir, "gems/own")), paths: ["linked"], root: dir))
        .to eq(Set["own"])
    end
  end

  it "counts nothing without paths:" do
    expect(described_class.names(gem_at("/proj"), paths: nil, root: "/proj")).to be_empty
  end
end
