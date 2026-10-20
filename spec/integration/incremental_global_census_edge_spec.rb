# frozen_string_literal: true

# Issue #2158 — `global.write-type-mismatch` declines a write when any file may let the literal answer the setter
# (a `write`, `to_str`, `to_int` or hatch defined in any spelling on any receiver, an alias of the variable, a
# top-level mixin), and that answer read the whole-program `GlobalWriteCensus` without recording an ADR-46 read. A
# file that stopped writing the entry re-analysed only itself, and `--incremental` kept the write silent where a cold
# run reports it. The rule now records a `global_census:` key per entry it asks about, and the recheck fires the keys
# of every entry that appeared in or vanished from a changed file's census.
require "spec_helper"
require "tmpdir"

RSpec.describe "incremental edges for the global write census (#2158)" do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir])
  end

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(
      configuration: configuration(dir), paths: [dir], environment: shared_environment
    )
  end

  def mismatches(diagnostics)
    found = diagnostics.select { |d| d.rule == "global.write-type-mismatch" }
    found.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, environment: shared_environment
    )
    mismatches(guarded_run(runner).diagnostics)
  end

  def write_files(dir, files)
    files.each { |name, source| File.write(File.join(dir, name), source) }
  end

  def reported = [["use.rb", 1]]
  def bare = "class Other\nend\n"

  # Writes `use.rb` and `other.rb` (`before`), takes a baseline, rewrites `other.rb` to `after`, and expects the warm
  # recheck to re-analyse `use.rb` and answer as a full run does.
  def expect_edit(before:, after:, first:, second:, use: "$stdout = 1\n")
    Dir.mktmpdir do |dir|
      write_files(dir, "use.rb" => use, "other.rb" => before)
      session = session_for(dir)
      expect([mismatches(guarded_baseline(session)), full_run(dir)]).to eq([first, first])

      write_files(dir, "other.rb" => after)
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(File.join(dir, "use.rb"))
      expect([mismatches(recheck.diagnostics), full_run(dir)]).to eq([second, second])
    end
  end

  {
    "a def of write" => "class Other\n  def write(*) = nil\nend\n",
    "a def_delegator of write" =>
      "require \"forwardable\"\nclass Other\n  extend Forwardable\n  def_delegator :@io, :write\nend\n",
    "a class_eval string defining write" => "class Other\n  class_eval \"def write(*) = nil\"\nend\n",
    "an alias of the variable" => "alias $stdout $my_out\n",
    "a computed define_method" => "class Other\n  NAME = :w\n  define_method(NAME) { nil }\nend\n",
    "a def of method_missing" => "class Other\n  def method_missing(*) = nil\nend\n",
    "a top-level mixin of a module RBS does not know" => "include Writable\n"
  }.each do |form, silencing|
    it "reports the write again when #{form} is removed" do
      expect_edit(before: silencing, after: bare, first: [], second: reported)
    end

    it "silences the write when #{form} is added" do
      expect_edit(before: bare, after: silencing, first: reported, second: [])
    end
  end

  # Guards: a refinement that adds `write` declines the write only where a `using` is in effect, so `use.rb` activates
  # the module `other.rb` declares, with or without the refinement. The `using` already files an edge to the file that
  # declares the module, so these pass without the `global_census:refines*` keys.
  def using_write = "using R\n$stdout = 1\n"
  def refining_write = "module R\n  refine Integer do\n    def write(*) = nil\n  end\nend\n"

  it "reports the write again when a refinement adding write is removed" do
    expect_edit(use: using_write, before: refining_write, after: "module R\nend\n", first: [], second: [["use.rb", 2]])
  end

  it "silences the write when a refinement adding write is added" do
    expect_edit(use: using_write, before: "module R\nend\n", after: refining_write, first: [["use.rb", 2]], second: [])
  end

  # The precision half: an edit that leaves the file's census as it was fires no `global_census:` key, and the
  # silenced write is not re-analysed.
  it "does not re-check the write when a file edits something the census does not record" do
    Dir.mktmpdir do |dir|
      write_files(dir, "use.rb" => "$stdout = 1\n", "other.rb" => "class Other\n  def write(*) = nil\nend\n")
      session = session_for(dir)
      expect(mismatches(guarded_baseline(session))).to eq([])

      write_files(dir, "other.rb" => "class Other\n  def write(*) = nil\n  def zzz = 1\nend\n")
      recheck = guarded_recheck(session)
      expect(recheck.affected).not_to include(File.join(dir, "use.rb"))
      expect(mismatches(recheck.diagnostics)).to eq([])
    end
  end
end
