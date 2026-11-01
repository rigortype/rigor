# frozen_string_literal: true

# Issue #2441 — `rbs collection install` resolves the project's own Gemfile.lock, where the project's gems are
# `PATH`-sourced (rails: `actionpack`, `activesupport`, …), and its generator skips only a `gemspec` source. It
# therefore installs community RBS for the very library under analysis, which double-declares every member the
# project's `sig/` declares: on rails 2398 classes failed to build with `DuplicatedMethodDefinitionError`. A
# collection entry for a `PATH` gem Rigor analyses as project source (its directory is at, under or above a
# `paths:` entry) is now skipped whole, the way a vendored name is, and the gem is not `:missing` RBS either.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/environment"

RSpec.describe "rbs collection entries for the project's own path gems" do
  def collection_lock(name)
    <<~YAML
      ---
      path: ".gem_rbs_collection"
      gems:
      - name: #{name}
        version: '1.0'
        source:
          type: git
          name: ruby/gem_rbs_collection
          remote: https://github.com/ruby/gem_rbs_collection.git
          revision: abc
          repo_dir: gems
      gemfile_lock_path: Gemfile.lock
    YAML
  end

  # The project's `sig/` and the collection both declare `Mygem.deprecator`, with different returns so the one
  # that loaded is visible.
  def write_project
    FileUtils.mkdir_p("sig")
    File.write("sig/mygem.rbs", "module Mygem\n  def self.deprecator: () -> Integer\nend\n")
    write_collection("mygem", "module Mygem\n  def self.deprecator: () -> String\nend\n")
  end

  def write_collection(name, rbs)
    FileUtils.mkdir_p(".gem_rbs_collection/#{name}/1.0")
    File.write(".gem_rbs_collection/#{name}/1.0/#{name}.rbs", rbs)
    File.write("rbs_collection.lock.yaml", collection_lock(name))
  end

  def write_path_lockfile(remote, name: "mygem")
    File.write("Gemfile.lock", <<~LOCK)
      PATH
        remote: #{remote}
        specs:
          #{name} (1.0.0)

      GEM
        remote: https://rubygems.org/
        specs:

      PLATFORMS
        ruby

      DEPENDENCIES
        #{name}!

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

  def loader(paths: ["lib"])
    Rigor::Environment.for_project(
      root: Dir.pwd, bundler_auto_detect: true, rbs_collection_auto_detect: true, paths: paths
    ).rbs_loader
  end

  def collection_loaded?(rbs_loader, name = "mygem")
    rbs_loader.signature_paths.any? { |path| path.to_s.end_with?(".gem_rbs_collection/#{name}/1.0") }
  end

  def deprecator_types(rbs_loader)
    rbs_loader.singleton_method(class_name: "Mygem", method_name: :deprecator)&.method_types&.map(&:to_s)
  end

  around do |example|
    Dir.mktmpdir("rigor-collection-path-gem-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "skips the collection entry of a gem the lockfile sources from the project root, which contains paths:" do
    write_project
    write_path_lockfile(".")
    rbs_loader = loader
    expect(collection_loaded?(rbs_loader)).to be(false)
    expect(deprecator_types(rbs_loader)).to eq(["() -> ::Integer"])
  end

  it "skips the collection entry of a path gem whose lib/ is a paths: entry (the rails layout)" do
    write_project
    FileUtils.mkdir_p("mygem/lib")
    write_path_lockfile("mygem")
    expect(collection_loaded?(loader(paths: ["mygem/lib"]))).to be(false)
  end

  it "keeps the collection entry of a path gem outside the project root (a sibling checkout)" do
    write_project
    write_path_lockfile("../mygem")
    expect(collection_loaded?(loader)).to be(true)
  end

  it "keeps the collection entry of a vendored path gem no paths: entry reaches" do
    FileUtils.mkdir_p("sig")
    File.write("sig/own.rbs", "class MyX < Foo::Base\nend\n")
    write_collection("foo", "module Foo\n  class Base\n    def bar: () -> Integer\n  end\nend\n")
    FileUtils.mkdir_p("vendor/gems/foo")
    write_path_lockfile("vendor/gems/foo", name: "foo")
    rbs_loader = loader
    expect(collection_loaded?(rbs_loader, "foo")).to be(true)
    # `Foo::Base.new.bar.upcase` still reports: `bar` answers the collection's Integer through the subclass too.
    expect(rbs_loader.instance_method(class_name: "MyX", method_name: :bar)&.method_types&.map(&:to_s))
      .to eq(["() -> ::Integer"])
  end

  # Guard (positive control): no line of the fix is what keeps it passing; it fails if the skip widens to every
  # locked gem.
  it "keeps the collection entry of the same gem sourced from rubygems" do
    write_project
    write_gem_lockfile
    expect(collection_loaded?(loader)).to be(true)
  end

  # Guard: behaviour without a lockfile is unchanged.
  it "keeps the collection entry when the project has no Gemfile.lock" do
    write_project
    expect(collection_loaded?(loader)).to be(true)
  end

  it "does not load the activesupport overlay for the project's own activesupport" do
    # Skipping the collection entry left `activesupport` classified `:missing`, so the ADR-72 overlay loaded
    # beside the project's own sig and `Object` failed to build against `core_ext.rbs`.
    FileUtils.mkdir_p(["sig", "activesupport/lib"])
    File.write("sig/blank.rbs", "class Object\n  def blank?: () -> bool\nend\n")
    write_collection("activesupport", "module ActiveSupport\nend\n")
    write_path_lockfile("activesupport", name: "activesupport")
    rbs_loader = loader(paths: ["activesupport/lib"])
    expect(rbs_loader.signature_paths.map(&:to_s)).not_to include(a_string_ending_with("gem_overlay/activesupport"))
    expect(rbs_loader.instance_method(class_name: "Object", method_name: :blank?)).not_to be_nil
    expect(rbs_loader.definition_build_failures).to be_empty
  end
end
