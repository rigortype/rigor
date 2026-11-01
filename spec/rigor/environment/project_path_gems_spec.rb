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

  def write_ruby(*files)
    files.each do |file|
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "")
    end
  end

  around do |example|
    Dir.mktmpdir("rigor-project-path-gems-") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def at(path) = File.join(@dir, path)

  it "does not count a remote that only shares a paths: entry's prefix (/proj/lib2 against /proj/lib)" do
    write_ruby(at("lib2/a.rb"), at("lib/b.rb"))
    expect(described_class.names(gem_at(at("lib2")), paths: [at("lib")])).to be_empty
  end

  it "counts a remote under a paths: entry of / without spelling a // prefix" do
    write_ruby(at("own/lib/own.rb"))
    expect(described_class.names(gem_at(at("own")), paths: ["/"])).to eq(Set["own"])
  end

  it "matches a paths: entry spelled through a symlink against the gem's real directory" do
    write_ruby(at("gems/own/lib/own.rb"))
    File.symlink(at("gems/own/lib"), at("linked"))
    expect(described_class.names(gem_at(at("gems/own")), paths: ["linked"], root: @dir)).to eq(Set["own"])
  end

  it "counts nothing without paths:" do
    write_ruby(at("own.rb"))
    expect(described_class.names(gem_at(@dir), paths: nil, root: @dir)).to be_empty
  end

  # #2592 — the gem counts only when the file walker would analyse one of its Ruby files.
  describe "exclude: patterns" do
    def names(exclude_patterns, paths: ["."])
      described_class.names(gem_at(at("vendor/gems/foo"), name: "foo"),
                            paths: paths, root: @dir, exclude_patterns: exclude_patterns, exclude_base: @dir)
    end

    before { write_ruby(at("app/x.rb"), at("vendor/gems/foo/lib/foo.rb"), at("vendor/gems/foo/lib/foo/base.rb")) }

    it "does not count a gem whose every .rb file a *.rb pattern excludes" do
      expect(names(["vendor/**/*.rb"])).to be_empty
    end

    it "does not count a gem whose Ruby all sits in an excluded subdirectory" do
      expect(names(["vendor/gems/foo/lib/**"])).to be_empty
    end

    it "does not count a gem a directory pattern excludes whole" do
      expect(names(["vendor/**"])).to be_empty
    end

    it "counts a gem when one of its .rb files survives a subdirectory pattern" do
      write_ruby(at("vendor/gems/foo/exe/foo.rb"))
      expect(names(["vendor/gems/foo/lib/**"])).to eq(Set["foo"])
    end

    it "counts a gem an unrelated pattern leaves alone" do
      expect(names(["app/**"])).to eq(Set["foo"])
    end

    it "reads only the part of the gem a paths: entry covers" do
      write_ruby(at("vendor/gems/foo/test/foo_test.rb"))
      expect(names(["vendor/gems/foo/lib/**"], paths: ["vendor/gems/foo/lib"])).to be_empty
      expect(names(["vendor/gems/foo/lib/**"], paths: ["vendor/gems/foo"])).to eq(Set["foo"])
    end

    it "does not count a reached gem directory with no Ruby" do
      FileUtils.rm_rf(at("vendor/gems/foo/lib"))
      expect(names([])).to be_empty
    end
  end
end
