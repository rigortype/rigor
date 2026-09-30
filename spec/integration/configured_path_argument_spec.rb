# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

# Issue #1556 — a path argument that names a configured path. `.rigor.yml`'s `paths:` load as absolute paths, so
# `rigor check lib` compared unequal to them and widened discovery over both spellings: every file entered the
# pre-pass twice, every cross-file constant had two writers, and its publication was withheld (#644).
RSpec.describe "a path argument that names a configured path (#1556)" do
  around do |example|
    Dir.mktmpdir("rigor-overlapping-paths-") { |dir| Dir.chdir(dir) { example.run } }
  end

  before do
    FileUtils.mkdir_p("lib")
    File.write(".rigor.yml", "paths:\n  - lib\n")
    File.write("lib/a.rb", "module M\n  LIMIT = 5\nend\n")
    File.write("lib/b.rb", "module M\n  def self.f\n    LIMIT.upcase\n  end\nend\n")
  end

  def undefined_rows(paths)
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.load(".rigor.yml"), cache_store: nil)
    guarded_run(runner, paths).diagnostics
                              .select { |d| d.qualified_rule == "call.undefined-method" }
                              .map { |d| "#{File.basename(d.path)}:#{d.line}" }
  end

  it "reports under `rigor check lib` what `rigor check` reports" do
    expect(undefined_rows(nil)).to eq(["b.rb:3"])
    expect(undefined_rows(%w[lib])).to eq(["b.rb:3"])
    expect(undefined_rows(%w[./lib])).to eq(["b.rb:3"])
  end

  # A file list widens discovery to the rest of the project, and an analysed file must enter it once, under the
  # spelling the analysis uses.
  it "publishes a constant an analysed file defines to another file of the list" do
    File.write("lib/c.rb", "module M\n  WIDTH = 5\nend\n")
    File.write("lib/d.rb", "module M\n  def self.g\n    WIDTH.upcase\n  end\nend\n")
    expect(undefined_rows(nil)).to eq(["b.rb:3", "d.rb:3"])
    expect(undefined_rows(%w[lib/c.rb lib/d.rb])).to eq(["d.rb:3"])
  end

  # `exclude:` matches a path as spelled, and the configured `lib` loads absolute, so a relative pattern excludes
  # `lib/gen` from the argument's expansion and not from the configured one. The run still widens discovery over
  # the configured spelling and finds the method `lib/gen` defines.
  #
  # flip this when #1576 is fixed: once a relative `exclude:` pattern applies to the configured absolute paths,
  # the configured spelling excludes `lib/gen` as well, and this example pins behaviour that no longer exists.
  it "discovers a method defined only in a file the argument's spelling excludes" do
    File.write(".rigor.yml", "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n")
    FileUtils.mkdir_p("lib/gen")
    FileUtils.mkdir_p("sig")
    File.write("sig/widget.rbs", "class Widget\n  def initialize: () -> void\n  def name: () -> String\nend\n")
    File.write("lib/widget.rb", "class Widget\n  def initialize; end\n  def name = \"w\"\nend\n")
    File.write("lib/user.rb", "class User\n  def go\n    Widget.new.extra\n  end\nend\n")
    File.write("lib/gen/widget_ext.rb", "class Widget\n  def extra = 1\nend\n")
    expect(undefined_rows(%w[lib])).to eq(["b.rb:3"])
  end

  # Path arguments that overlap each other analyse a file twice. The widened discovery set holds it once, so it is
  # compared with the analysed files counted once too, or it never looks wider and `ext` goes undiscovered.
  it "discovers a method defined outside overlapping path arguments" do
    File.write(".rigor.yml", "paths:\n  - lib\n  - ext\n")
    FileUtils.mkdir_p("ext")
    FileUtils.mkdir_p("sig")
    File.write("sig/widget.rbs", "class Widget\n  def initialize: () -> void\n  def name: () -> String\nend\n")
    File.write("lib/widget.rb", "class Widget\n  def initialize; end\n  def name = \"w\"\nend\n")
    File.write("lib/user.rb", "class User\n  def go\n    Widget.new.extra\n  end\nend\n")
    File.write("ext/widget_ext.rb", "class Widget\n  def extra = 1\nend\n")
    expect(undefined_rows(%w[lib lib/user.rb])).to eq(["b.rb:3"])
    expect(undefined_rows(%w[lib lib])).to eq(["b.rb:3", "b.rb:3"])
    expect(undefined_rows(%w[./lib lib/user.rb])).to eq(["b.rb:3"])
  end

  # Overlapping arguments that do not widen discovery still name a file twice; the pre-pass must census it once.
  # The analysis itself still walks the file twice, as `lib lib` does, so the finding repeats. Files are identified
  # by expanded path: a symlinked alias (`src -> lib`) is a known limitation and is not folded.
  it "censuses a file once when two spellings of the same argument name it" do
    expect(undefined_rows(%w[lib ./lib])).to eq(["b.rb:3", "b.rb:3"])
  end

  # A discovered file keeps the spelling the analysis uses when it is analysed, so the run-result cache does not
  # list it a second time as discovered-not-analysed under the configured absolute spelling.
  it "keeps the analysis's spelling for a file the widened set shares with it" do
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.load(".rigor.yml"), cache_store: nil)
    absolute = File.expand_path("lib")
    project = ["#{absolute}/a.rb", "#{absolute}/b.rb", "#{absolute}/a.rb"]
    expect(runner.send(:discovery_files, project, ["lib/a.rb"])).to eq(["lib/a.rb", "#{absolute}/b.rb"])
  end
end
