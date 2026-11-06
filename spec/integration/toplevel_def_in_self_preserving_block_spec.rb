# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

require "rigor/analysis/incremental_session"

# Issue #2861 — #316's opaque-`self` mark declined a cross-file top-level `def` in EVERY block, so inside
# `rows.map { |r| format(r).bit_length }` the call fell through to `Kernel#format` and reported `bit_length` on a
# `String` while Ruby runs the project's `def format(x) = 42` and returns 6. Two changes, pinned here:
#
# 1. A block whose call provably runs it under the caller's `self` (a catalogued core iterator on a typed explicit
#    receiver, `Inference::SelfPreservingBlock`) enters without the opaque mark, so the def binds there as it does
#    beside the call.
# 2. Where the mark still declines (a receiverless DSL call, `instance_exec` on an object), the call answers
#    `Dynamic[Top]`, never the `Kernel` / `Object` method of the same name: the block's real `self` reaches either
#    its own method of that name or the top-level `def`, never Kernel's.
#
# Ruby witnesses (`ruby -e`, helpers defined first): `[1, 2].map { |r| format(r).bit_length }` => [6, 6];
# `BasicObject.new.instance_eval { format(1) }` raises NoMethodError; `Fmt.new.instance_exec { format(1) }` =>
# `Fmt#format`'s value; `Class.new { format(1) }` => 42; `[1].map { |r| format(r) }` inside `Fmt#go` => `Fmt#format`'s.
RSpec.describe "a cross-file top-level def called from a block (#2861)", type: :runner do
  let(:helpers) { "def format(x) = 42\ndef myhelper(x) = 42\n" }

  def run_files(files, overrides = {})
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, source| File.write(File.join(lib, name), source) }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [lib], "workers" => 0, **overrides)
      )
      guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), [lib]).diagnostics
    end
  end

  # `[basename, line, message]` of every `call.undefined-method` the run reports.
  def undefined(files, overrides = {})
    run_files(files, overrides)
      .select { |d| d.rule == "call.undefined-method" }
      .map { |d| [File.basename(d.path), d.line, d.message] }
  end

  def script(*lines) = "#{lines.join("\n")}\n"

  # Each line of `script` that reports, with the substring its message must contain.
  def expect_reports(files, expected, overrides = {})
    actual = undefined(files, overrides)
    expect(actual.map { |file, line, _| [file, line] }).to match_array(expected.map { |file, line, _| [file, line] })
    expected.each do |file, line, fragment|
      message = actual.find { |f, l, _| f == file && l == line }&.last
      expect(message).to include(fragment)
    end
  end

  context "with the issue's repro" do
    let(:use) do
      script(
        "rows = [1, 2]",
        "rows.map { |r| format(r).bit_length }",
        "rows.map { |r| myhelper(r).upcase }",
        "rows.map { |r| myhelper(r).bit_length }",
        "rows.map { |r| myhelper(r) }.first.upcase",
        "rows.each_slice(1).map { |r| myhelper(r) }.each { |v| v.upcase }"
      )
    end

    # File order is not load order: the def sorts after the caller in one run and before it in the other.
    it "binds the def in a core iterator block whichever file sorts first" do
      expect_reports({ "a_helpers.rb" => helpers, "b_script.rb" => use },
                     [["b_script.rb", 3, "for 42"], ["b_script.rb", 5, "for 42"], ["b_script.rb", 6, "for 42"]])
      expect_reports({ "z_helpers.rb" => helpers, "b_script.rb" => use },
                     [["b_script.rb", 3, "for 42"], ["b_script.rb", 5, "for 42"], ["b_script.rb", 6, "for 42"]])
    end

    it "binds the same way across Ractor workers" do
      expect_reports({ "helpers.rb" => helpers, "script.rb" => use },
                     [["script.rb", 3, "for 42"], ["script.rb", 5, "for 42"], ["script.rb", 6, "for 42"]],
                     "workers" => 2)
    end

    # The must-fire sibling of the silenced row: without a helpers file, `format` is Kernel's and the chain reports.
    it "still dispatches to Kernel#format where the project defines no top-level format" do
      expect_reports({ "script.rb" => script("[1].map { |r| format(r).bit_length }") },
                     [["script.rb", 1, "for String"]])
    end
  end

  context "without proof that the block keeps the caller's self" do
    # `runit` hands the block to `instance_exec`, so the mark declines the bind; the shadowing name answers
    # `Dynamic[Top]` instead of `Kernel#format`'s `String`, and the non-shadowing one stays untyped as before.
    it "answers Dynamic, not the Kernel method, for a receiverless DSL block" do
      use = script(
        "def runit(&b) = instance_exec(&b)",
        "runit { format(1).bit_length }",
        "runit { myhelper(1).upcase }"
      )

      expect(undefined("helpers.rb" => helpers, "script.rb" => use)).to eq([])
    end

    # A core iterator keeps the `self` it is called under, so nested in a DSL block it keeps that block's mark, and a
    # DSL block nested in a core iterator takes the mark afresh.
    it "keeps the mark across nesting in either order" do
      use = script(
        "def runit(&b) = instance_exec(&b)",
        "runit { [1].map { |r| format(r).bit_length } }",
        "runit { [1].map { |r| myhelper(r).upcase } }",
        "[1].map { runit { format(1).bit_length } }",
        "[1].map { runit { myhelper(1).upcase } }"
      )

      expect(undefined("helpers.rb" => helpers, "script.rb" => use)).to eq([])
    end

    # Issue #2829's value-position subtree keeps the #316 mark off through a core iterator to the DSL block below it,
    # as it did before: the walk's unknown-`self` mark passes through the iterator unchanged.
    it "keeps a value-position block's subtree unmarked through a core iterator" do
      use = script(
        "def runit(&b) = instance_exec(&b)",
        "puts([1].map { [2].each { runit { myhelper(1).upcase } } })"
      )

      expect_reports({ "helpers.rb" => helpers, "script.rb" => use }, [["script.rb", 2, "for 42"]])
    end

    # The must-fire sibling of the Object / Kernel reopening row: with no reopening, `tap` / `then` keep the caller's
    # `self` (main), which reaches the top-level def.
    it "binds through tap and then when nothing reopens them" do
      use = script(
        "class Foo",
        "end",
        "Foo.new.tap { myhelper(1).upcase }",
        "Foo.new.then { myhelper(1).upcase }"
      )

      expect_reports({ "helpers.rb" => helpers, "script.rb" => use },
                     [["script.rb", 3, "for 42"], ["script.rb", 4, "for 42"]])
    end

    # A project reopening of a catalogued iterator may run the block on another object.
    it "keeps the mark where the project redefines the iterator" do
      use = script(
        "class Integer",
        "  def times(&b) = instance_exec(&b)",
        "end",
        "3.times { myhelper(1).upcase }"
      )

      expect(undefined("helpers.rb" => helpers, "script.rb" => use)).to eq([])
    end

    # The class's own `myhelper` returns a String, which Ruby runs; the top-level def must not capture it.
    # `ClosureEscapeAnalyzer` answers `tap` / `then` for every class, so a project definition every receiver reaches
    # (`Object`, `Kernel`) must count for every receiver. Ruby runs `Foo#format` here ("FOO").
    it "keeps the mark where the project defines tap on Module, for a class-object receiver" do
      use = script(
        "class Module",
        "  def tap(&b) = (instance_exec(&b); self)",
        "end",
        "class Foo",
        "  def self.myhelper(x) = \"foo\"",
        "end",
        "Foo.tap { myhelper(1).upcase }"
      )

      expect(undefined("helpers.rb" => helpers, "script.rb" => use)).to eq([])
    end

    {
      "tap on Object" => ["class Object", "  def tap(&b) = (instance_exec(&b); self)", "end"],
      "then on Kernel" => ["module Kernel", "  def then(&b) = instance_exec(&b)", "end"]
    }.each do |label, reopening|
      it "keeps the mark where the project defines #{label}" do
        name = reopening.join[/def (\w+)/, 1]
        use = script(
          *reopening,
          "class Foo",
          "  def format(x) = \"foo\"",
          "  def myhelper(x) = \"foo\"",
          "end",
          "Foo.new.#{name} { format(1).upcase }",
          "Foo.new.#{name} { myhelper(1).upcase }"
        )

        expect(undefined("helpers.rb" => helpers, "script.rb" => use)).to eq([])
      end
    end

    it "answers Dynamic for instance_exec on an object whose class defines the name" do
      use = script(
        "class Fmt",
        "  def format(x) = :sym",
        "  def myhelper(x) = \"s\"",
        "end",
        "Fmt.new.instance_exec { format(1).bit_length }",
        "Fmt.new.instance_exec { myhelper(1).upcase }"
      )

      expect(undefined("helpers.rb" => helpers, "script.rb" => use)).to eq([])
    end

    it "answers Dynamic for instance_eval on a BasicObject" do
      use = script("BasicObject.new.instance_eval { format(1).bit_length }")

      expect(undefined("helpers.rb" => helpers, "script.rb" => use)).to eq([])
    end

    # Unchanged: a `Class.new` body narrows `self` to the new class, which reaches the top-level def.
    it "binds the def in a Class.new body" do
      use = script("Class.new { format(1).bit_length }", "Class.new { myhelper(1).upcase }")

      expect_reports({ "helpers.rb" => helpers, "script.rb" => use }, [["script.rb", 2, "for 42"]])
    end
  end

  it "uses the class's own method in a block inside one of its methods" do
    use = script(
      "class Fmt",
      "  def format(x) = \"s\"",
      "  def go = [1].map { |r| format(r).bit_length }",
      "end"
    )

    expect_reports({ "helpers.rb" => helpers, "script.rb" => use }, [["script.rb", 3, "for String"]])
  end

  # A def only one `if` arm runs binds in the block exactly as it does at the top level of the caller's file: the
  # block adds no certainty the top-level call lacks.
  it "reads a def guarded by an if as the top-level call does" do
    guarded = script("if ENV[\"X\"]", "  def onlyif(x) = 42", "end")
    use = script("onlyif(1).upcase", "[1].map { |r| onlyif(r).upcase }")

    reports = undefined("helpers.rb" => guarded, "script.rb" => use)
    expect(reports.map { |_, line, _| line }).to contain_exactly(1, 2)
    expect(reports.map(&:last).uniq.size).to eq(1)
  end

  describe "a warm incremental recheck after the def is removed" do
    def session_for(dir)
      Rigor::Analysis::IncrementalSession.new(configuration: Rigor::Configuration.new("paths" => [dir]),
                                              environment: Rigor::Environment.for_project)
    end

    it "drops the stale bind" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "helpers.rb"), "def myhelper(x) = 42\n")
        File.write(File.join(dir, "script.rb"), "[1, 2].map { |r| myhelper(r).upcase }\n")
        session = session_for(dir)
        expect(guarded_baseline(session).map(&:rule)).to include("call.undefined-method")

        File.write(File.join(dir, "helpers.rb"), "# gone\n")
        rules = guarded_recheck(session).diagnostics.select { |d| File.basename(d.path) == "script.rb" }.map(&:rule)

        expect(rules).to eq(["call.unresolved-toplevel"])
      end
    end
  end
end
