# frozen_string_literal: true

# Issue #2946 — `rbs collection install` records a collection gem's stdlib dependencies in
# `rbs_collection.lock.yaml` as `source: { type: stdlib }` entries, and the `rbs` CLI loads each as an RBS
# library. Rigor dropped them, so a signature subclassing one (actionview's `NodeParser < ::Ripper`) failed
# with `RBS::NoSuperclassFoundError` and the class read `Dynamic[top]`. They now load as libraries, appended to
# `DEFAULT_LIBRARIES + libraries:`, and the run cache key's `rbs.libraries` slot names them.

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/environment"
require "rigor/configuration"
require "rigor/analysis/run_cache_key"
require "rigor/cache/rbs_descriptor"
require "rigor/cli/check_command"

RSpec.describe "rbs collection lockfile stdlib entries" do
  def write_lockfile(*names)
    gems = names.map { |name| "- name: #{name}\n  version: '0'\n  source:\n    type: stdlib\n" }.join
    File.write("rbs_collection.lock.yaml", "---\npath: \".gem_rbs_collection\"\ngems:\n#{gems}")
  end

  def write_project
    FileUtils.mkdir_p(%w[sig app .gem_rbs_collection])
    File.write("sig/node_parser.rbs", "class NodeParser < ::Ripper\n  def parse_nodes: () -> Array[untyped]\nend\n")
    File.write("app/use_parser.rb", <<~RUBY)
      class UseParser
        def call
          NodeParser.new("1 + 1").parse_nodes
          NodeParser.new("1 + 1").no_such_method
        end
      end
    RUBY
  end

  def loader
    Rigor::Environment.for_project(root: Dir.pwd, rbs_collection_auto_detect: true).rbs_loader
  end

  # `Ripper#parse` is inherited, so it resolves only when the superclass built.
  def inherited_parse(rbs_loader)
    rbs_loader.instance_method(class_name: "NodeParser", method_name: :parse)
  end

  around do |example|
    Dir.mktmpdir("rigor-collection-stdlib-") { |dir| Dir.chdir(dir) { example.run } }
  end

  before { write_project }

  it "loads a stdlib entry as a library, so a signature subclassing it builds" do
    write_lockfile("ripper")
    rbs_loader = loader
    expect(rbs_loader.libraries).to include("ripper")
    expect(inherited_parse(rbs_loader)).not_to be_nil
  end

  it "reads the lockfile under root:, not the working directory" do
    FileUtils.mkdir_p("proj")
    FileUtils.cp_r("sig", "proj")
    Dir.chdir("proj") { write_lockfile("ripper") }
    rbs_loader = Rigor::Environment.for_project(root: File.expand_path("proj"), rbs_collection_auto_detect: true)
                                   .rbs_loader
    expect(rbs_loader.libraries).to include("ripper")
  end

  it "skips an unknown stdlib entry without failing the build" do
    write_lockfile("this_stdlib_does_not_exist_xyz", "ripper")
    expect(inherited_parse(loader)).not_to be_nil
  end

  it "keys the probe's rbs.libraries slot on the stdlib entries, matching the loader's" do
    configuration = Rigor::Configuration.new({})
    without = Rigor::Analysis::RunCacheKey.libraries_config_entries(configuration)
    write_lockfile("ripper")
    with = Rigor::Analysis::RunCacheKey.libraries_config_entries(configuration)
    expect(with).not_to eq(without)
    expect(with).to eq([Rigor::Cache::RbsDescriptor.libraries_entry(loader.libraries)])
  end

  it "reports the typo on the subclass in rigor check, with no definition-build failure" do
    write_lockfile("ripper")
    File.write(".rigor.yml", "paths:\n  - app\n")
    out = StringIO.new
    Rigor::CLI::CheckCommand.new(
      argv: ["--no-cache", "--no-ci-detect", "--no-stats", "--workers=0", "--format=json", "--config", ".rigor.yml"],
      out: out, err: StringIO.new
    ).run
    diagnostics = JSON.parse(out.string).fetch("diagnostics")
    expect(diagnostics.map { |d| [d["rule"], d["line"]] }).to include(["call.undefined-method", 4])
    expect(diagnostics.map { |d| d["rule"] }).not_to include("rbs.coverage.definition-build-failed")
  end
end
