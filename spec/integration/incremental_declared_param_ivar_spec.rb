# frozen_string_literal: true

# Issue #1154 — the class-ivar census types `@x = x` with the declared type of the parameter, read from `sig/`, and
# declines when another file declares the class. A warm `--incremental` run must answer what a cold run answers when
# the signature changes and when a reopening appears or goes away.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental runs over a declared-parameter ivar (#1154)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-declared-param-ivar-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [d.path, d.line, d.message] }.sort
  end

  def cold_rows
    rows(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
           .diagnostics)
  end

  def incremental_rows
    paths = Dir.glob("lib/**/*.rb")
    root = File.join(Dir.pwd, ".rigor", "cache")
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                      cache_store: Rigor::Cache::Store.new(root: root))
    rows(guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint).first)
  end

  let(:source) { "class K\n  def initialize(x) = @x = x\n  def use = @x.nope\nend\n" }
  let(:string_row) { [["lib/k.rb", 3, "undefined method `nope' for String"]] }

  def expect_warm_equals_cold(expected)
    expect(incremental_rows).to eq(expected)
    expect(cold_rows).to eq(expected)
  end

  it "follows an edit to the sig/ initialize declaration" do
    write("lib/k.rb", source)
    write("sig/k.rbs", "class K\n  def initialize: (String x) -> void\nend\n")
    expect_warm_equals_cold(string_row)

    write("sig/k.rbs", "class K\n  def initialize: (untyped x) -> void\nend\n")
    expect_warm_equals_cold([])
  end

  it "follows a reopening of the class appearing and going away" do
    write("lib/k.rb", source)
    write("sig/k.rbs", "class K\n  def initialize: (String x) -> void\nend\n")
    expect_warm_equals_cold(string_row)

    write("lib/k2.rb", "class K\n  def other = 1\nend\n")
    expect_warm_equals_cold([])

    FileUtils.rm("lib/k2.rb")
    expect_warm_equals_cold(string_row)
  end
end
