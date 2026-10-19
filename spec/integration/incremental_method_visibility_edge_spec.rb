# frozen_string_literal: true

# Issue #2134 — `Scope#discovered_method_visibility` answered from the project's visibility table without recording
# an ADR-46 read, so a verdict that read a `private :foo` kept no edge to the file that wrote it. Toggling the
# modifier in a file the caller had no other edge to re-analysed only that file, and `--incremental` served the
# caller's previous rows where a cold run disagrees.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for a source-recorded method visibility (#2134)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-method-visibility-edge-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  def rows(diagnostics)
    rules = %w[def.method-visibility-mismatch def.override-visibility-reduced def.override-return-widened
               call.wrong-arity]
    diagnostics.select { |d| rules.include?(d.rule) }.map { |d| [d.rule, d.path, d.line] }
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

  # Writes `files`, runs once, rewrites `lib/vis.rb` to `after`, and expects the warm run to equal a cold one.
  def expect_toggle(files, before:, after:, first:, second:)
    files.merge("lib/vis.rb" => before).each { |path, source| write(path, source) }
    paths = (files.keys + ["lib/vis.rb"]).sort
    expect(incremental_rows(paths)).to eq([first, false])
    expect(cold_rows).to eq(first)

    write("lib/vis.rb", after)
    expect(incremental_rows(paths)).to eq([second, true])
    expect(cold_rows).to eq(second)
  end

  let(:mismatch) { [["def.method-visibility-mismatch", "lib/use.rb", 1]] }
  let(:reduced) { [["def.override-visibility-reduced", "lib/child.rb", 2]] }
  let(:singleton) { [["def.method-visibility-mismatch", "lib/use.rb", 2]] }
  let(:arity) { [["call.wrong-arity", "lib/use.rb", 1]] }
  let(:override_files) do
    { "lib/parent.rb" => "class Parent\n  def foo = 1\nend\n",
      "lib/child.rb" => "class Child < Parent\n  private def foo = 2\nend\n" }
  end
  let(:singleton_files) do
    { "lib/widget.rb" => "class Widget\nend\n", "lib/use.rb" => "def make\n  Widget.new\nend\n" }
  end
  let(:private_new) { "class Widget\n  private_class_method :new\nend\n" }
  let(:arity_files) { { "lib/foo.rb" => "class Foo\n  def bar = 1\nend\n", "lib/use.rb" => "Foo.new.bar(1)\n" } }

  # A guard: the call's own resolution files the class edge to the reopening.
  it "re-checks an explicit-receiver call when a reopening stops making the method private" do
    expect_toggle(
      { "lib/foo.rb" => "class Foo\n  def bar = 1\nend\n", "lib/use.rb" => "Foo.new.bar\n" },
      before: "class Foo\n  private :bar\nend\n", after: "\n", first: mismatch, second: []
    )
  end

  # The override rule reads the parent's visibility with no edge to a file that only writes it.
  {
    "a reopening" => "class Parent\n  private :foo\nend\n",
    "a class_eval block" => "Parent.class_eval do\n  private :foo\nend\n"
  }.each do |form, private_source|
    it "re-checks an override when #{form} starts making the parent's method private" do
      expect_toggle(override_files, before: "\n", after: private_source, first: reduced, second: [])
    end

    it "re-checks an override when #{form} stops making the parent's method private" do
      expect_toggle(override_files, before: private_source, after: "\n", first: [], second: reduced)
    end
  end

  # Guards, as are the wrong-arity examples below: the chain read files the class edge to the reopening.
  it "re-checks a singleton call when a reopening starts making the method private" do
    expect_toggle(singleton_files, before: "\n", after: private_new, first: [], second: singleton)
  end

  it "re-checks a singleton call when a reopening stops making the method private" do
    expect_toggle(singleton_files, before: private_new, after: "\n", first: singleton, second: [])
  end

  {
    "a reopening" => "class Foo\n  protected :bar\nend\n",
    "a class_eval block" => "Foo.class_eval do\n  protected :bar\nend\n"
  }.each do |form, protected_source|
    it "re-checks a wrong-arity call when #{form} stops making the method protected" do
      expect_toggle(arity_files, before: protected_source, after: "\n", first: [], second: arity)
    end

    it "re-checks a wrong-arity call when #{form} starts making the method protected" do
      expect_toggle(arity_files, before: "\n", after: protected_source, first: arity, second: [])
    end
  end

  # The singleton rule first asks whether any class records the name private; while none does, it reads no chain,
  # so only the `visibility:*#build` key re-checks the call when a file makes the extended module's method private,
  # or drops a `public :build` that hid another file's `private :build`.
  def extended_files
    { "lib/factory.rb" => "module Factory\n  def build = 1\nend\n",
      "lib/widget.rb" => "class Widget\n  extend Factory\nend\n",
      "lib/use.rb" => "def make\n  Widget.build\nend\n" }
  end

  it "re-checks a singleton call when a reopening of the extended module starts making the method private" do
    expect_toggle(extended_files, before: "\n", after: "module Factory\n  private :build\nend\n",
                                  first: [], second: singleton)
  end

  it "re-checks a singleton call when a file drops the public call that hid a private one" do
    files = extended_files.merge("lib/factory.rb" => "module Factory\n  def build = 1\n  private :build\nend\n")
    expect_toggle(files, before: "module Factory\n  public :build\nend\n", after: "\n", first: [], second: singleton)
  end

  # A splat may make every singleton name public, which contests the wildcard slot from a file that declares nothing.
  it "re-checks a singleton call when a file starts contesting the class's wildcard slot" do
    files = { "lib/widget.rb" => "class Widget\n  private_class_method :new\nend\n",
              "lib/use.rb" => "def make\n  Widget.new\nend\n" }
    expect_toggle(files, before: "\n", after: "Widget.public_class_method(*NAMES)\n", first: singleton, second: [])
  end

  # `def.override-return-widened` stops at a parent's private method; the relevance read of the parent's visibility
  # is what re-checks it.
  it "re-checks a widened override when a class_eval block starts making the parent's method private" do
    write("sig/x.rbs",
          "class Parent\n  def foo: () -> Integer\nend\nclass Child < Parent\n  def foo: () -> String\nend\n")
    expect_toggle(
      { "lib/parent.rb" => "class Parent\n  def foo = 1\nend\n",
        "lib/child.rb" => "class Child < Parent\n  def foo = \"a\"\nend\n" },
      before: "\n", after: "Parent.class_eval do\n  private :foo\nend\n",
      first: [["def.override-return-widened", "lib/child.rb", 2]], second: []
    )
  end
end
