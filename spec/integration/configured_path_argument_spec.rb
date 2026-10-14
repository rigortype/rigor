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

  # `exclude:` applies to a path whichever way it is spelled (#1576): the configured `lib` loads absolute and the
  # argument is relative, and a relative pattern excludes `lib/gen` from both. The excluded file is not read for
  # discovery either, so the method it defines stays undefined under both spellings.
  it "treats a file the exclude pattern names as absent under either spelling" do
    File.write(".rigor.yml", "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n")
    FileUtils.mkdir_p("lib/gen")
    FileUtils.mkdir_p("sig")
    File.write("sig/widget.rbs", "class Widget\n  def initialize: () -> void\n  def name: () -> String\nend\n")
    File.write("lib/widget.rb", "class Widget\n  def initialize; end\n  def name = \"w\"\nend\n")
    File.write("lib/user.rb", "class User\n  def go\n    Widget.new.extra\n  end\nend\n")
    File.write("lib/gen/widget_ext.rb", "class Widget\n  def extra = 1\nend\n")
    expect(undefined_rows(nil)).to eq(["b.rb:3", "user.rb:3"])
    expect(undefined_rows(%w[lib])).to eq(["b.rb:3", "user.rb:3"])
  end

  # Issue #1576 — the reported symptom: a file under an excluded directory is not reported.
  describe "a relative `exclude:` pattern" do
    def reported_files(paths)
      runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.load(".rigor.yml"), cache_store: nil)
      guarded_run(runner, paths).diagnostics.map { |d| File.basename(d.path) }.uniq.sort
    end

    before do
      FileUtils.mkdir_p("lib/gen")
      File.write("lib/gen/x.rb", "x = nil\nx.upcase\n")
      File.write("lib/gen2.rb", "y = nil\ny.upcase\n")
    end

    it "excludes the same files for configured paths and for `rigor check lib`" do
      File.write(".rigor.yml", "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n")
      expect(reported_files(nil)).to include("gen2.rb")
      expect(reported_files(nil)).not_to include("x.rb")
      expect(reported_files(%w[lib])).to eq(reported_files(nil))
    end

    it "keeps an absolute pattern working for both spellings" do
      File.write(".rigor.yml", "paths:\n  - lib\nexclude:\n  - \"#{File.join(Dir.pwd, 'lib/gen/**')}\"\n")
      expect(reported_files(nil)).not_to include("x.rb")
      expect(reported_files(%w[lib])).not_to include("x.rb")
    end

    it "does not exclude a file the pattern does not name" do
      File.write(".rigor.yml", "paths:\n  - lib\nexclude:\n  - \"lib/gen/**\"\n")
      expect(reported_files(nil)).to include("gen2.rb")
      expect(reported_files(%w[lib/gen2.rb])).to include("gen2.rb")
    end

    it "reports the file when no pattern names it" do
      expect(reported_files(nil)).to include("x.rb")
    end
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
