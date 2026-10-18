# frozen_string_literal: true

# Issue #2121 — `Scope#discovered_method?` answered from the project's `attr_*` / `alias_method` / `define_method`
# table without recording an ADR-46 read, so a caller that table silenced kept no edge to the file that declared the
# member. Deleting the declaration then re-analysed only the edited file, and `--incremental` served the caller's
# silent rows where a cold run reports `call.undefined-method`. A `def` was never affected: its symbol edge covers it.
#
# The receiver is a bundled class (`Mutex`, declared by core RBS), whose calls the rule checks against RBS plus the
# project's own source declarations. Ruby 4.0.5 runs every `use.rb` below with the member declared, and raises
# NoMethodError on `m.a = 1` once it is gone.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for a source-declared method (#2121)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-discovered-method-edge-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:paths) { %w[lib/patch.rb lib/use.rb] }
  let(:use) { "m = Mutex.new\nm.a = 1\n" }
  let(:reported) { [["lib/use.rb", 2, "`a='"]] }

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [d.path, d.line, d.message[/`[^']+'/]] }
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

  def expect_removal(before:, after:)
    write("lib/patch.rb", before)
    write("lib/use.rb", use)
    expect(incremental_rows).to eq([[], false])

    write("lib/patch.rb", after)
    expect(incremental_rows).to eq([reported, true])
    expect(cold_rows).to eq(reported)
  end

  {
    "attr_accessor" => "attr_accessor :a",
    "define_method" => "define_method(:a=) { |value| value }",
    "alias_method" => "alias_method :a=, :lock"
  }.each do |macro, declaration|
    it "re-checks the caller when the #{macro} that answered it is removed" do
      expect_removal(before: "class Mutex\n  #{declaration}\nend\n", after: "class Mutex\nend\n")
    end
  end

  # The file still defines `a=` after the edit, on another class, so only the class edge to the file declaring
  # `Mutex` re-checks the caller.
  it "re-checks the caller when the member moves to another class in the same file" do
    expect_removal(before: "class Mutex\n  attr_accessor :a\nend\nclass Other\nend\n",
                   after: "class Mutex\nend\nclass Other\n  attr_accessor :a\nend\n")
  end

  # A `class_eval` on the constant declares the member from a file that does not declare `Mutex`, so the class edge
  # names no file and the name edge `defines:a=` re-checks the caller.
  it "re-checks the caller when a class_eval declaration is removed" do
    expect_removal(before: "class Other\nend\nMutex.class_eval do\n  attr_accessor :a\nend\n",
                   after: "class Other\nend\n")
  end
end
