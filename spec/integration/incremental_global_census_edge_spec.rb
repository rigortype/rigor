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
    found = diagnostics.select { |d| d.rule.start_with?("global.") }
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

  # Writes `use.rb`, `files` and the edited file (`before`), takes a baseline, rewrites the edited file to `after`,
  # and expects the warm recheck to re-analyse `use.rb` and answer as a full run does.
  def expect_edit(before:, after:, first:, second:, use: "$stdout = 1\n", files: {}, edited: "other.rb")
    Dir.mktmpdir do |dir|
      write_files(dir, files.merge("use.rb" => use, edited => before))
      session = session_for(dir)
      expect([mismatches(guarded_baseline(session)), full_run(dir)]).to eq([first, first])

      write_files(dir, edited => after)
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
    "a top-level include of a module RBS does not know" => "include Writable\n",
    "a top-level prepend of a module RBS does not know" => "prepend Writable\n",
    "a top-level extend of a module RBS does not know" => "extend Writable\n"
  }.each do |form, silencing|
    it "reports the write again when #{form} is removed" do
      expect_edit(before: silencing, after: bare, first: [], second: reported)
    end

    it "silences the write when #{form} is added" do
      expect_edit(before: bare, after: silencing, first: reported, second: [])
    end
  end

  # A refinement that may add `write` declines the write where any `using` is in effect, whichever class it refines,
  # so `use.rb` activates a module (`R`) that refines something else from a file that never changes; only the
  # `global_census:refines*` keys re-check the write when `q.rb` starts or stops refining `write`.
  def using_r = "using R\n$stdout = 1\n"
  def r_file = { "r.rb" => "module R\n  refine(Integer) { nil }\nend\n" }
  def q_bare = "module Q\nend\n"

  {
    "a refinement defining write" => "module Q\n  refine String do\n    def write(*) = nil\n  end\nend\n",
    "a refinement with a computed define_method" =>
      "module Q\n  refine String do\n    NAME = :w\n    define_method(NAME) { nil }\n  end\nend\n"
  }.each do |form, refining|
    it "reports the write under a using again when #{form} is removed" do
      expect_edit(use: using_r, files: r_file, edited: "q.rb", before: refining, after: q_bare, first: [],
                  second: [["use.rb", 2]])
    end

    it "silences the write under a using when #{form} is added" do
      expect_edit(use: using_r, files: r_file, edited: "q.rb", before: q_bare, after: refining,
                  first: [["use.rb", 2]], second: [])
    end
  end

  # `global.readonly-write` reads the census's aliases too.
  it "reports a read-only write again when the alias that exempted it is removed" do
    expect_edit(use: "$: = 1\n", before: "alias $foo $:\n", after: bare, first: [], second: reported)
  end

  it "exempts a read-only write when an alias of it is added" do
    expect_edit(use: "$: = 1\n", before: bare, after: "alias $foo $:\n", first: reported, second: [])
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

  # A silenced write records only the census entries that silence it, since only their vanishing flips the answer:
  # another file starting to define a hatch re-checks none of them.
  it "does not re-check writes another definition already silences when a file starts defining a hatch" do
    Dir.mktmpdir do |dir|
      users = (1..5).to_h { |i| ["use#{i}.rb", "$stdout = #{i}\n"] }
      write_files(dir, users.merge("other.rb" => "class Other\n  def write(*) = nil\nend\n", "more.rb" => bare))
      session = session_for(dir)
      expect(mismatches(guarded_baseline(session))).to eq([])

      write_files(dir, "more.rb" => "class Other\n  def respond_to?(*) = true\nend\n")
      recheck = guarded_recheck(session)
      expect((recheck.affected & users.keys.map { |name| File.join(dir, name) }).to_a).to eq([])
      expect([mismatches(recheck.diagnostics), full_run(dir)]).to eq([[], []])
    end
  end
end
