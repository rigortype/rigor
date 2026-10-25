# frozen_string_literal: true

# Issue #2284 — a call on a class object types from a farther `def self.x` only while no nearer entry defines `x`
# without a `def`. Adding or removing that definer in a file the call has no other edge to must re-check the call:
# `--incremental` must serve what a cold run reports.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for a nearer def-less singleton definer (#2284)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-singleton-definer-edge-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [d.rule, d.path, d.line] }
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    rows(guarded_run(runner, %w[lib]).diagnostics).sort
  end

  def incremental_rows(paths)
    root = File.join(Dir.pwd, ".rigor", "cache")
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                      cache_store: Rigor::Cache::Store.new(root: root))
    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    [rows(diagnostics).sort, warm]
  end

  # Writes `files`, runs once, rewrites `lib/near.rb` to `after`, and expects the warm run to equal a cold one.
  def expect_toggle(files, before:, after:, first:, second:)
    files.merge("lib/near.rb" => before).each { |path, source| write(path, source) }
    paths = (files.keys + ["lib/near.rb"]).sort
    expect(incremental_rows(paths)).to eq([first, false])
    expect(cold_rows).to eq(first)

    write("lib/near.rb", after)
    expect(incremental_rows(paths)).to eq([second, true])
    expect(cold_rows).to eq(second)
  end

  let(:files) do
    { "lib/base.rb" => "class Bo\n  def self.name = nil\nend\n",
      "lib/sub.rb" => "class S1 < Bo\nend\n",
      "lib/use.rb" => "S1.name.upcase\n" }
  end
  let(:fired) { [["call.undefined-method", "lib/use.rb", 1]] }

  it "re-checks the call when a reopening adds or removes a define_singleton_method" do
    expect_toggle(files, before: "class S1\nend\n",
                         after: "class S1\n  define_singleton_method(:name) { \"s\" }\nend\n",
                         first: fired, second: [])
  end

  it "re-checks the call when a reopening removes a define_singleton_method" do
    expect_toggle(files, before: "class S1\n  define_singleton_method(:name) { \"s\" }\nend\n",
                         after: "class S1\nend\n",
                         first: [], second: fired)
  end
end
