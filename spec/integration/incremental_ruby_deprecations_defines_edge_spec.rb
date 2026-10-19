# frozen_string_literal: true

# Issue #2133 — `call.deprecated-ruby2-keywords` is silenced when the project defines a method of the same name
# anywhere (`RubyDeprecations#project_defines?`), and that answer read the project's `def` and `attr_*` /
# `alias_method` / `define_method` tables whole without recording an ADR-46 read. A file that started or stopped
# defining the name then re-analysed only itself, and `--incremental` kept the caller's previous verdict where a cold
# run disagrees. The defining class is unrelated to the call's receiver, so no class or symbol edge covers it.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for a deprecation silenced by a project definition (#2133)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-ruby-deprecations-edge-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:paths) { %w[lib/other.rb lib/use.rb] }
  let(:use) { "Hash.ruby2_keywords_hash?({})\n" }
  let(:reported) { [["lib/use.rb", 1]] }

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0, "target_ruby" => "4.1")
    )
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.deprecated-ruby2-keywords" }.map { |d| [d.path, d.line] }
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    rows(guarded_run(runner, %w[lib]).diagnostics).sort
  end

  def incremental_rows
    root = File.join(Dir.pwd, ".rigor", "cache")
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                      cache_store: Rigor::Cache::Store.new(root: root))
    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    [rows(diagnostics).sort, warm]
  end

  def expect_edit(before:, after:, first:, second:)
    write("lib/other.rb", before)
    write("lib/use.rb", use)
    expect(incremental_rows).to eq([first, false])

    write("lib/other.rb", after)
    expect(incremental_rows).to eq([second, true])
    expect(cold_rows).to eq(second)
  end

  {
    "def" => "def ruby2_keywords_hash?(value) = value",
    "alias_method" => "alias_method :ruby2_keywords_hash?, :nil?",
    "define_method" => "define_method(:ruby2_keywords_hash?) { |value| value }"
  }.each do |form, declaration|
    it "reports the call again when the #{form} that silenced it is removed" do
      expect_edit(before: "class Other\n  #{declaration}\nend\n", after: "class Other\nend\n",
                  first: [], second: reported)
    end

    it "silences the call when a #{form} of the name is added" do
      expect_edit(before: "class Other\nend\n", after: "class Other\n  #{declaration}\nend\n",
                  first: reported, second: [])
    end
  end
end
