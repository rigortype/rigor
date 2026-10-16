# frozen_string_literal: true

# Issue #1941 — a `def Const.x` written outside `Const`'s body adds to `Const`'s singleton side from a file that does
# not declare `Const`. A reader's class edge names only the declaring files, so editing that `def` (a rename, an
# addition, a removal) left a warm `--incremental` run answering what the old `def` said. Each example runs cold,
# edits the file, and expects the warm rows to equal a cold run's. Each reported call raises `ArgumentError` in Ruby
# 4.0.5: the last singleton `def` of a name wins, and `lib/d.rb` loads first.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "an incremental recheck after editing a def Const.x outside the class body (#1941)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-incremental-def-const-singleton-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:workers) { 0 }
  let(:paths) { %w[lib/d.rb lib/patch.rb lib/use.rb] }

  let(:declaration) { "class D\n  def self.own(a) = a\n  def self.keep(a) = a\nend\n" }
  let(:use) { "D.own(1, 2)\nD.keep(1, 2)\n" }

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => workers))
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.wrong-arity" }.map { |d| [d.path, d.line] }.sort
  end

  def incremental_rows
    root = File.join(Dir.pwd, ".rigor", "cache")
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                      cache_store: Rigor::Cache::Store.new(root: root))
    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    [rows(diagnostics), warm]
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    rows(guarded_run(runner, paths).diagnostics)
  end

  # Writes the three files, runs cold, rewrites `lib/patch.rb`, and expects the warm and cold rows both to be
  # `expected` (the cold rows are asserted too, so the example pins the answer the warm run must reach).
  def expect_transition(before:, after:, expected:, use_source: use, declaration_source: declaration)
    write("lib/d.rb", declaration_source)
    write("lib/patch.rb", before)
    write("lib/use.rb", use_source)
    _, warm = incremental_rows
    expect(warm).to be(false)

    write("lib/patch.rb", after)
    expect(incremental_rows).to eq([expected, true])
    expect(cold_rows).to eq(expected)
  end

  it "re-checks the reader when the def is renamed" do
    expect_transition(before: "def D.own(a, b) = a\n", after: "def D.keep(a, b) = a\n",
                      expected: [["lib/use.rb", 1]])
  end

  it "re-checks the reader when the def is added" do
    expect_transition(before: "x = 1\n", after: "def D.keep(a, b) = a\n", expected: [["lib/use.rb", 1]])
  end

  it "re-checks the reader when the def is removed" do
    expect_transition(before: "def D.own(a, b) = a\n", after: "x = 1\n",
                      expected: [["lib/use.rb", 1], ["lib/use.rb", 2]])
  end

  it "re-checks the reader when the def's constant resolves through the enclosing module" do
    expect_transition(
      declaration_source: "module M\n  class E\n    def self.own(a) = a\n    def self.keep(a) = a\n  end\nend\n",
      before: "module M\n  def E.own(a, b) = a\nend\n", after: "module M\n  def E.keep(a, b) = a\nend\n",
      use_source: "M::E.own(1, 2)\nM::E.keep(1, 2)\n", expected: [["lib/use.rb", 1]]
    )
  end

  it "re-checks the reader when the def sits in another class's body" do
    expect_transition(before: "class Other\n  def D.own(a, b) = a\nend\n",
                      after: "class Other\n  def D.keep(a, b) = a\nend\n", expected: [["lib/use.rb", 1]])
  end

  it "re-checks the reader when the file that renames the def also requires it" do
    expect_transition(before: "require_relative \"use\"\ndef D.own(a, b) = a\n",
                      after: "require_relative \"use\"\ndef D.keep(a, b) = a\n", expected: [["lib/use.rb", 1]])
  end

  context "when another file also defines the name" do
    let(:paths) { %w[lib/d.rb lib/patch.rb lib/patch2.rb lib/use.rb] }

    # `lib/patch2.rb` still defines `D.own(a, b)`, so after the rename `D.own` keeps its two parameters and only the
    # rename's new `D.keep(a, b)` moves an answer.
    it "re-checks the reader when one of them is renamed" do
      write("lib/patch2.rb", "def D.own(a, b) = a\n")
      expect_transition(before: "def D.own(a, b) = a\n", after: "def D.keep(a, b) = a\n", expected: [])
    end
  end

  context "with a worker pool" do
    let(:workers) { 2 }

    it "re-checks the reader when the def is renamed" do
      expect_transition(before: "def D.own(a, b) = a\n", after: "def D.keep(a, b) = a\n",
                        expected: [["lib/use.rb", 1]])
    end
  end

  # Guards: these forms already fired `class:D` before #1941, through the class-declaration diff or the
  # singleton-rewrite key #1933 added.
  it "re-checks the reader when the def moves into the class body (guard)" do
    expect_transition(before: "def D.own(a, b) = a\n", after: "class D\n  def self.keep(a, b) = a\nend\n",
                      expected: [["lib/use.rb", 1]])
  end

  it "re-checks the reader when a class << D def is renamed (guard)" do
    expect_transition(before: "class << D\n  def own(a, b) = a\nend\n",
                      after: "class << D\n  def keep(a, b) = a\nend\n", expected: [["lib/use.rb", 1]])
  end

  it "re-checks the reader when an alias in class << D is renamed (guard)" do
    expect_transition(declaration_source: "#{declaration}class D\n  def self.two(a, b) = a\nend\n",
                      before: "class << D\n  alias own two\nend\n", after: "class << D\n  alias keep two\nend\n",
                      expected: [["lib/use.rb", 1]])
  end

  it "re-checks the reader when a singleton_class.define_method name is renamed (guard)" do
    expect_transition(before: "D.singleton_class.define_method(:own) { |a, b| a }\n",
                      after: "D.singleton_class.define_method(:keep) { |a, b| a }\n", expected: [["lib/use.rb", 1]])
  end

  it "names the constant a def Const.x writes among the file's singleton sources" do
    write("lib/patch.rb", "def D.own(a, b) = a\nmodule M\n  def E.x = 1\nend\ndef Zork.y = 1\ndef self.z = 1\n")
    index = Rigor::Inference::ScopeIndexer.discovered_project_index_incremental(["lib/patch.rb"], seed_bundles: {})
    bundle = index.fetch(:bundles).fetch("lib/patch.rb")

    expect(bundle[:singleton_class_source_names]).to contain_exactly("D", "E", "Zork")
  end
end
