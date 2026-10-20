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

  # Issue #2013 — a reopening's `define_method(:bar)` contests the slot another file's `private def bar` writes, with
  # the replacement mark, so the private call declines whichever file folds later. `lib/zfoo.rb` sorts after
  # `lib/vis.rb`, `lib/foo.rb` before it.
  def define_bar = "class Foo\n  define_method(:bar) { 1 }\nend\n"
  def private_bar_files(path) = { path => "class Foo\n  private def bar = 1\nend\n", "lib/use.rb" => "Foo.new.bar\n" }

  %w[lib/foo.rb lib/zfoo.rb].each do |private_path|
    it "re-checks a private call when a reopening starts a define_method (#{private_path} private)" do
      expect_toggle(private_bar_files(private_path), before: "\n", after: define_bar, first: mismatch, second: [])
    end

    it "re-checks a private call when a reopening drops its define_method (#{private_path} private)" do
      expect_toggle(private_bar_files(private_path), before: define_bar, after: "\n", first: [], second: mismatch)
    end
  end

  it "re-checks an override when a reopening's define_method starts replacing the private override" do
    expect_toggle(override_files, before: "\n", after: "class Child < Parent\n  define_method(:foo) { 3 }\nend\n",
                                  first: reduced, second: [])
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

  # `def.override-return-widened` stops at a parent's private method. Here `def.override-visibility-reduced` reads
  # `Parent#foo`'s visibility in the same file first, which files the key.
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

  # `respond_to_missing?` is implicitly private, so `def.override-visibility-reduced` skips it and only the return
  # rule's contested-slot check in `DefinerResolution` reads the parent's slot: a conditional `private` contests it.
  it "re-checks a widened override whose only read of the parent's slot is its contest" do
    write("sig/x.rbs", "class Parent\n  def respond_to_missing?: (Symbol, bool) -> bool\nend\n" \
                       "class Child < Parent\n  def respond_to_missing?: (Symbol, bool) -> String\nend\n")
    expect_toggle(
      { "lib/parent.rb" => "class Parent\n  def respond_to_missing?(name, all = false) = false\nend\n",
        "lib/child.rb" => "class Child < Parent\n  def respond_to_missing?(name, all = false) = \"a\"\nend\n" },
      before: "\n", after: "Parent.class_eval do\n  private :respond_to_missing? if ENV[\"X\"]\nend\n",
      first: [["def.override-return-widened", "lib/child.rb", 2]], second: []
    )
  end

  # Issue #2161 — a module that `extend`s itself reads its private instance method's visibility for the singleton
  # call (`Es.two(1)` is a private call), unless some file's `module_function` row for the name gives it a public
  # singleton copy (`DefinerResolution.module_function_row?`). Swapping `private :two` for `module_function :two` in a
  # reopening keeps the file's visibility table and declared classes, so only the row entry `visibility_entries`
  # carries fires `visibility:Es#two`.
  def self_extended_files
    { "lib/es.rb" => "module Es\n  extend self\n  private def two(a, b) = a\nend\n",
      "lib/use.rb" => "def b = Es.two(1)\n" }
  end

  def private_two = "module Es\n  private :two\nend\n"
  def module_function_two = "module Es\n  module_function :two\nend\n"

  it "re-checks a self-extended singleton call when a reopening swaps private for module_function" do
    expect_toggle(self_extended_files, before: private_two, after: module_function_two, first: mismatch, second: arity)
  end

  it "re-checks a self-extended singleton call when a reopening swaps module_function back for private" do
    expect_toggle(self_extended_files, before: module_function_two, after: private_two, first: arity, second: mismatch)
  end

  # The `:both` row a `module_function def` writes (`ModuleFunctionState.deferred_module_function?`), against a
  # `private def` of the same body: the file's def, visibility entries and declared classes stay as they were.
  def extending_files
    { "lib/es.rb" => "module Es\n  extend self\nend\n", "lib/use.rb" => "def b = Es.two(1)\n" }
  end

  def private_def_two = "module Es\n  private def two(a, b) = a\nend\n"
  def module_function_def_two = "module Es\n  module_function def two(a, b) = a\nend\n"

  it "re-checks a self-extended singleton call when a private def becomes a module_function def" do
    expect_toggle(extending_files, before: private_def_two, after: module_function_def_two, first: mismatch,
                                   second: arity)
  end

  it "re-checks a self-extended singleton call when a module_function def becomes a private def" do
    expect_toggle(extending_files, before: module_function_def_two, after: private_def_two, first: arity,
                                   second: mismatch)
  end
end
