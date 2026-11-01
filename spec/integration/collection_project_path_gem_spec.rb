# frozen_string_literal: true

# Issue #2441 — `rbs collection install` resolves the project's own Gemfile.lock, where the project's gems are
# `PATH`-sourced (rails: `actionpack`, `activesupport`, …), and its generator skips only a `gemspec` source. It
# therefore installs community RBS for the very library under analysis, which double-declares every member the
# project's `sig/` declares: on rails 2398 classes failed to build with `DuplicatedMethodDefinitionError`. A
# collection entry for a `PATH` gem inside the project root is now skipped whole, the way a vendored name is.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/environment"

RSpec.describe "rbs collection entries for the project's own path gems" do
  COLLECTION_LOCK = <<~YAML
    ---
    path: ".gem_rbs_collection"
    gems:
    - name: mygem
      version: '1.0'
      source:
        type: git
        name: ruby/gem_rbs_collection
        remote: https://github.com/ruby/gem_rbs_collection.git
        revision: abc
        repo_dir: gems
    gemfile_lock_path: Gemfile.lock
  YAML

  # The project's `sig/` and the collection both declare `Mygem.deprecator`, with different returns so the one
  # that loaded is visible.
  def write_project
    FileUtils.mkdir_p("sig")
    File.write("sig/mygem.rbs", "module Mygem\n  def self.deprecator: () -> Integer\nend\n")
    FileUtils.mkdir_p(".gem_rbs_collection/mygem/1.0")
    File.write(".gem_rbs_collection/mygem/1.0/mygem.rbs", "module Mygem\n  def self.deprecator: () -> String\nend\n")
    File.write("rbs_collection.lock.yaml", COLLECTION_LOCK)
  end

  def write_path_lockfile(remote)
    File.write("Gemfile.lock", <<~LOCK)
      PATH
        remote: #{remote}
        specs:
          mygem (1.0.0)

      GEM
        remote: https://rubygems.org/
        specs:

      PLATFORMS
        ruby

      DEPENDENCIES
        mygem!

      BUNDLED WITH
         2.6.0
    LOCK
  end

  def write_gem_lockfile
    File.write("Gemfile.lock", <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
          mygem (1.0.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        mygem

      BUNDLED WITH
         2.6.0
    LOCK
  end

  def loader
    Rigor::Environment.for_project(
      root: Dir.pwd, bundler_auto_detect: true, rbs_collection_auto_detect: true
    ).rbs_loader
  end

  def collection_loaded?(rbs_loader)
    rbs_loader.signature_paths.any? { |path| path.to_s.end_with?(".gem_rbs_collection/mygem/1.0") }
  end

  def deprecator_types(rbs_loader)
    rbs_loader.singleton_method(class_name: "Mygem", method_name: :deprecator)&.method_types&.map(&:to_s)
  end

  around do |example|
    Dir.mktmpdir("rigor-collection-path-gem-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "skips the collection entry of a gem the lockfile sources from the project root" do
    write_project
    write_path_lockfile(".")
    rbs_loader = loader
    expect(collection_loaded?(rbs_loader)).to be(false)
    expect(deprecator_types(rbs_loader)).to eq(["() -> ::Integer"])
  end

  it "skips the collection entry of a gem the lockfile sources from a directory under the project root" do
    write_project
    FileUtils.mkdir_p("gems/mygem")
    write_path_lockfile("gems/mygem")
    expect(collection_loaded?(loader)).to be(false)
  end

  it "keeps the collection entry of a path gem outside the project root (a sibling checkout)" do
    write_project
    write_path_lockfile("../mygem")
    expect(collection_loaded?(loader)).to be(true)
  end

  it "keeps the collection entry of the same gem sourced from rubygems" do
    write_project
    write_gem_lockfile
    expect(collection_loaded?(loader)).to be(true)
  end

  it "keeps the collection entry when the project has no Gemfile.lock" do
    write_project
    expect(collection_loaded?(loader)).to be(true)
  end
end
