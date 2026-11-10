# frozen_string_literal: true

# Issue #3030 — running Rigor in a gem_rbs_collection `_test/` directory once its `bin/test` setup has run. That
# setup writes an `rbs_collection.yaml` with a `local` source pointing at the collection's own `gems/` tree, and
# `rbs collection install` SYMLINKS each `gems/<name>/<version>/` into `.gem_rbs_collection/`, `_test/` fixtures
# included. Two things went wrong:
#
# (a) every collected gem's `_test/**` fixtures loaded as signatures — rbs itself loads a collection gem as a
#     library and skips each file below a `_`-prefixed directory (`RBS::FileFinder`, `skip_hidden: true`);
# (b) with `signature_paths: [".."]` (the author's working tree) the gem loaded twice, once from there and once
#     from the lockfile, declaring every member twice.
#
# The fixtures build that layout under a tmpdir: `gems/<name>/1.0/` working trees, `gems/mygem/1.0/_test/` as the
# project, its lock with `local` sources, and `.gem_rbs_collection/<name>/1.0` symlinks (or a plain copy, for the
# `git`-source shape of (b)).

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/environment"

RSpec.describe "rbs collection RBS in a gem_rbs_collection _test/ directory" do
  def lock_yaml(names)
    entries = names.map do |name|
      <<~YAML.chomp
        - name: #{name}
          version: '1.0'
          source:
            type: local
            path: "#{File.join(@repo, 'gems')}"
      YAML
    end
    "---\npath: \".gem_rbs_collection\"\ngems:\n#{entries.join("\n")}\n"
  end

  def write_gem(name, files)
    files.each do |relative, rbs|
      path = File.join(@repo, "gems", name, "1.0", relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, rbs)
    end
  end

  # The `_test/` dir of `mygem`, set up as `bin/test` leaves it: a lock over `names` and one symlink per gem, or a
  # copy for each gem in `copy:`.
  def write_test_dir(names, copy: [])
    FileUtils.mkdir_p(test_dir)
    File.write(File.join(test_dir, "rbs_collection.lock.yaml"), lock_yaml(names))
    names.each do |name|
      FileUtils.mkdir_p(File.join(test_dir, ".gem_rbs_collection", name))
      installed = File.join(test_dir, ".gem_rbs_collection", name, "1.0")
      source = File.join(@repo, "gems", name, "1.0")
      next File.symlink(source, installed) unless copy.include?(name)

      # A `git` source copies the gem without its `_`-prefixed entries (`Sources::Git#cp_r`).
      FileUtils.mkdir_p(installed)
      Dir.children(source).reject { |child| child.start_with?("_") }.each do |child|
        FileUtils.cp_r(File.join(source, child), installed)
      end
    end
  end

  def test_dir = File.join(@repo, "gems", "mygem", "1.0", "_test")

  def loader(signature_paths: nil)
    Rigor::Environment.for_project(
      root: test_dir, signature_paths: signature_paths, rbs_collection_auto_detect: true
    ).rbs_loader
  end

  def instance_types(rbs_loader, class_name, method_name)
    rbs_loader.instance_method(class_name: class_name, method_name: method_name)&.method_types&.map(&:to_s)
  end

  def collection_entry?(rbs_loader, name)
    rbs_loader.signature_paths.any? { |path| path.to_s.end_with?(".gem_rbs_collection/#{name}/1.0") }
  end

  around do |example|
    Dir.mktmpdir("rigor-collection-test-dir-") do |dir|
      @repo = File.realpath(dir)
      Dir.chdir(@repo) { example.run }
    end
  end

  describe "(a) a collected gem's _-prefixed directories" do
    # `helper`'s `_test/test.rbs` redeclares `Helper#call`, as rails-dom-testing's and activerecord's fixtures
    # redeclare their gem's classes; loaded, it fails `Helper`'s definition build.
    before do
      write_gem("mygem", { "mygem.rbs" => "class Mygem\n  def run: () -> Integer\nend\n" })
      write_gem("helper", {
                  "helper.rbs" => "class Helper\n  def call: () -> Integer\nend\n",
                  "_test/test.rbs" => "class Helper\n  def call: () -> Integer\nend\nclass HelperFixture\nend\n",
                  "_scripts/gen.rbs" => "class HelperScript\nend\n",
                  "_private.rbs" => "class HelperUnderscoreFile\nend\n"
                })
      write_test_dir(%w[mygem helper])
    end

    it "skips the files below a _-prefixed directory, so the gem's class builds" do
      rbs_loader = loader

      expect(instance_types(rbs_loader, "Helper", :call)).to eq(["() -> ::Integer"])
      expect(rbs_loader.class_known?("HelperFixture")).to be(false)
      expect(rbs_loader.class_known?("HelperScript")).to be(false)
      expect(rbs_loader.definition_build_failures).to eq([])
      expect(rbs_loader.quarantined_signatures).to eq([])
    end

    it "still loads a _-prefixed FILE name, as rbs does" do
      expect(loader.class_known?("HelperUnderscoreFile")).to be(true)
    end

    # The control: rbs reads an explicit signature directory (`-I`, a Steepfile `signature`) whole.
    it "reads a signature_paths: directory whole, _-prefixed directories included" do
      FileUtils.mkdir_p(File.join(test_dir, "sig", "_private"))
      File.write(File.join(test_dir, "sig", "_private", "own.rbs"), "class OwnPrivate\nend\n")

      rbs_loader = loader(signature_paths: [File.join(test_dir, "sig")])

      expect(rbs_loader.class_known?("OwnPrivate")).to be(true)
      expect(collection_entry?(rbs_loader, "helper")).to be(true)
    end
  end

  describe "(b) a signature_paths: copy of a locked gem" do
    def write_gems
      write_gem("mygem", {
                  "mygem.rbs" => "class Mygem\n  def run: () -> Integer\nend\n",
                  "_test/test.rbs" => "class MygemFixture\nend\n"
                })
      write_gem("other", { "other.rbs" => "class Other\nend\n" })
    end

    it "loads the gem once, from the working tree signature_paths: names" do
      write_gems
      write_test_dir(%w[mygem other])

      rbs_loader = loader(signature_paths: [File.join(test_dir, "..")])

      expect(collection_entry?(rbs_loader, "mygem")).to be(false)
      expect(collection_entry?(rbs_loader, "other")).to be(true)
      expect(instance_types(rbs_loader, "Mygem", :run)).to eq(["() -> ::Integer"])
      expect(rbs_loader.definition_build_failures).to eq([])
      # The working tree is the author's, read whole: its own `_test/` signatures load from it.
      expect(rbs_loader.class_known?("MygemFixture")).to be(true)
    end

    it "loads the gem once whatever the lockfile's order" do
      write_gems
      write_test_dir(%w[other mygem])

      rbs_loader = loader(signature_paths: [File.join(test_dir, "..")])

      expect(collection_entry?(rbs_loader, "mygem")).to be(false)
      expect(collection_entry?(rbs_loader, "other")).to be(true)
      expect(rbs_loader.definition_build_failures).to eq([])
    end

    # A `git` source installs a COPY: the working tree is preferred over it, edits and all.
    it "prefers the signature_paths: copy over a lockfile copy with other contents" do
      write_gems
      write_test_dir(%w[mygem other], copy: %w[mygem])
      File.write(File.join(@repo, "gems", "mygem", "1.0", "mygem.rbs"), "class Mygem\n  def run: () -> String\nend\n")

      rbs_loader = loader(signature_paths: [File.join(test_dir, "..")])

      expect(collection_entry?(rbs_loader, "mygem")).to be(false)
      expect(instance_types(rbs_loader, "Mygem", :run)).to eq(["() -> ::String"])
    end

    # The dropped entry still counts as RBS for the gem: a locked gem with an ADR-72 overlay (activesupport) is
    # not `:missing`, so its overlay stays unloaded as it would beside the lockfile copy.
    it "still counts the gem as covered, so no gem overlay loads for it" do
      write_gem("activesupport", { "activesupport.rbs" => "module ActiveSupport\nend\n" })
      write_test_dir(%w[activesupport])
      File.write(File.join(test_dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            activesupport (1.0.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          activesupport

        BUNDLED WITH
           2.6.0
      LOCK
      rbs_loader = Rigor::Environment.for_project(
        root: test_dir, signature_paths: [File.join(@repo, "gems", "activesupport", "1.0")],
        rbs_collection_auto_detect: true, bundler_auto_detect: true
      ).rbs_loader

      expect(collection_entry?(rbs_loader, "activesupport")).to be(false)
      expect(rbs_loader.signature_paths.map(&:to_s).grep(%r{gem_overlay/activesupport})).to eq([])
    end

    # The control: a signature root whose real path does not end in a locked `<name>/<version>`.
    it "keeps the lockfile copy beside a signature_paths: root that names no locked gem" do
      write_gems
      write_test_dir(%w[mygem other])
      FileUtils.mkdir_p(File.join(test_dir, "sig"))
      File.write(File.join(test_dir, "sig", "local.rbs"), "class LocalSig\nend\n")

      rbs_loader = loader(signature_paths: [File.join(test_dir, "sig")])

      expect(collection_entry?(rbs_loader, "mygem")).to be(true)
      expect(rbs_loader.class_known?("LocalSig")).to be(true)
      expect(instance_types(rbs_loader, "Mygem", :run)).to eq(["() -> ::Integer"])
    end
  end
end
