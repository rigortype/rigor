# frozen_string_literal: true

# Issue #684 — `rigor check path/to/one_file.rb` MUST report what `rigor check .` reports for that file.
#
# The cross-file discovery pre-pass ran over the INVOCATION's file set, so a run over an explicit file list
# discovered only the files it was handed. A class the project declares in `sig/` without declaring every
# one of its methods was then RBS-known while source discovery could not supply the method, and
# `call.undefined-method` fired on correct code — for any method whose defining file was outside the list.
#
# That is what an editor integration, a pre-commit hook and `git diff --name-only | xargs rigor check` all
# do, and it is why per-directory sums over a tree over-reported against a whole-tree run.
#
# Discovery now spans the configured project on such a run; the analysis still targets only the files given.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/cache/store"
require "rigor/configuration"

RSpec.describe "an explicit file list and call.undefined-method (#684)" do
  # `sig/` declares the module and NOT its singleton method — the abridged project signature every real
  # project has, since a `sig/` is written incrementally.
  def abridged_rbs
    <<~RBS
      module Indexer
      end
    RBS
  end

  def write_project(defines_block_body: true, caller_source: nil)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "indexer.rbs"), abridged_rbs)
    File.write(File.join("lib", "indexer.rb"), <<~RUBY)
      module Indexer
        #{defines_block_body ? 'def self.block_body(node) = node' : 'def self.other(node) = node'}
      end
    RUBY
    File.write(File.join("lib", "caller.rb"), caller_source || <<~RUBY)
      def run(node)
        Indexer.block_body(node)
      end
    RUBY
  end

  def config
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0
      )
    )
  end

  def run(paths, cache_store: nil)
    guarded_run(
      Rigor::Analysis::Runner.new(configuration: config, cache_store: cache_store), paths
    )
  end

  # Every diagnostic the run reported about `lib/caller.rb`, rule and position only — the comparable
  # projection of two runs that analysed different file sets.
  def caller_diagnostics(result)
    result.diagnostics
          .select { |d| d.path.to_s.end_with?("caller.rb") }
          .map { |d| "#{d.line}:#{d.column} #{d.qualified_rule}" }
          .sort
  end

  def undefined_messages(result)
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-explicit-file-list-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not fire for a method whose defining file is outside the list" do
    write_project
    expect(undefined_messages(run(%w[lib/caller.rb]))).to be_empty
  end

  it "agrees with the whole-project run over the same file" do
    # The property, stated directly: a file's diagnostics do not depend on what else was on the command
    # line. It is the half a "reports nothing" assertion cannot carry — the whole-project run is the
    # reference answer, and the point is agreement with it, not silence.
    # The caller makes BOTH calls, so the comparison is between two non-empty answers: the file's real
    # error survives in each run, and only the false one differs. Two empty sets would have compared equal
    # under a fix that silenced the class outright.
    write_project(caller_source: <<~RUBY)
      def run(node)
        Indexer.block_body(node)
        Indexer.definitely_missing(node)
      end
    RUBY
    subset = caller_diagnostics(run(%w[lib/caller.rb]))
    whole = caller_diagnostics(run(%w[lib]))
    expect(subset).to eq(whole)
    expect(whole).to eq(["3:11 call.undefined-method"])
  end

  it "still fires for a method the project does not define anywhere" do
    # Mandatory must-still-fire: widening discovery must not silence the class. `other` exists on the
    # module and `block_body` does not, so this is the same receiver answering differently — a fixture
    # that merely reported nothing would pass a broken fix too.
    write_project(defines_block_body: false)
    expect(undefined_messages(run(%w[lib/caller.rb]))).to eq(
      ["undefined method `block_body' for singleton(Indexer)"]
    )
  end

  it "re-reports when the defining file stops defining the method, through the run cache" do
    # The cache half of the change. A widened run's diagnostics are a function of files it did NOT
    # analyse, so those files ride the run-result dependency descriptor; without that entry the second
    # run here is served from the first one's cache and stays silent about code that no longer works.
    #
    # A fresh `Cache::Store` per run, on one root, is what makes the second run a real cache read rather
    # than an in-process memo hit.
    root = File.join(Dir.pwd, ".rigor", "cache")
    write_project
    expect(undefined_messages(run(%w[lib/caller.rb], cache_store: Rigor::Cache::Store.new(root: root)))).to be_empty

    write_project(defines_block_body: false)
    expect(
      undefined_messages(run(%w[lib/caller.rb], cache_store: Rigor::Cache::Store.new(root: root)))
    ).to eq(["undefined method `block_body' for singleton(Indexer)"])
  end

  it "serves an unchanged widened run from the cache" do
    # The other direction of the same entry: adding the discovered files to the descriptor must not make
    # every subset run a permanent miss. Nothing changed between the two runs, so the second is a hit —
    # asserted through the diagnostics being identical AND the run being cacheable at all.
    root = File.join(Dir.pwd, ".rigor", "cache")
    write_project
    first = run(%w[lib/caller.rb], cache_store: Rigor::Cache::Store.new(root: root))
    second = run(%w[lib/caller.rb], cache_store: Rigor::Cache::Store.new(root: root))
    expect(second.diagnostics.map(&:message)).to eq(first.diagnostics.map(&:message))
  end
end
