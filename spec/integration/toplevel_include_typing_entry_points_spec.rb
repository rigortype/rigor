# frozen_string_literal: true

# Issue #1715 — typing a bare top-level call through a top-level `include` reads the absence of the name from the
# whole project's defined names. An entry point that builds its scope without the whole-project pre-pass holds one
# file's names at most, so it must decline: an editor's per-buffer run (`DiagnosticPublisher#run_analysis`, a
# `prebuilt:` runner with a buffer binding) and `rigor type-of`. In each project below another file defines `helper`,
# which Ruby would call, so typing the call from `Helpers#helper` would be wrong.

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tempfile"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/cli"
require "rigor/configuration"

RSpec.describe "typing through a top-level include from entry points without the project pre-pass (#1715)" do
  around do |example|
    Dir.mktmpdir("rigor-toplevel-include-entry-") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(%w[lib sig])
        File.write(".rigor.yml", "paths:\n  - lib\n")
        File.write("sig/helpers.rbs", "module Helpers\n  def helper: () -> Integer\nend\n")
        File.write("lib/a.rb", "include Helpers\nhelper.upcase\n")
        example.run
      end
    end
  end

  # What `DiagnosticPublisher#run_analysis` builds for an open buffer: the project scan as `prebuilt:`, and the
  # buffer's bytes bound to the logical path.
  def editor_run
    configuration = Rigor::Configuration.load
    scan = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, collect_stats: false)
                                  .prepare_project_scan
    path = File.expand_path("lib/a.rb")
    Tempfile.create(["rigor-buffer-", ".rb"]) do |tmp|
      tmp.write(File.read(path))
      tmp.flush
      binding = Rigor::Analysis::BufferBinding.new(logical_path: path, physical_path: tmp.path)
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, collect_stats: false,
                                           buffer: binding, prebuilt: scan)
      guarded_run(runner, [path]).diagnostics.map(&:qualified_rule)
    end
  end

  def type_of(position)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI.start(["type-of", "--format=json", position], out: out, err: err)
    [status, JSON.parse(out.string)["type"]]
  end

  { "a top-level def" => "def helper = \"x\"\n",
    "attr_reader on a class" => "class W\n  attr_reader :helper\nend\n",
    "Object.include of another module" => "module Twice\n  def helper = \"t\"\nend\nObject.include(Twice)\n" }
    .each do |shape, definer|
      it "leaves the call untyped in an editor's per-buffer run beside #{shape}" do
        File.write("lib/b.rb", definer)

        expect(editor_run).not_to include("call.undefined-method")
      end

      it "leaves the call untyped under type-of beside #{shape}" do
        File.write("lib/b.rb", definer)

        expect(type_of("lib/a.rb:2:1")).to eq([0, "Dynamic[top]"])
      end
    end

  # Editor mode (`--tmp-file` / `--instead-of`) with a path argument folds discovery over that argument alone, so the
  # pre-pass sees a subset: the names a subset holds are not evidence that the project defines a name nowhere.
  describe "editor mode over a subset of paths:" do
    def editor_check(*paths)
      File.write(".rigor.yml", "paths:\n  - lib\n  - scripts\n")
      FileUtils.mkdir_p("scripts")
      FileUtils.mv("lib/a.rb", "scripts/a.rb") if File.exist?("lib/a.rb")
      File.write("buffer.rb", File.read("scripts/a.rb"))
      out = StringIO.new
      Rigor::CLI.start(["check", "--no-cache", "--tmp-file=buffer.rb", "--instead-of=scripts/a.rb", *paths],
                       out: out, err: StringIO.new)
      out.string
    end

    { "the file" => %w[scripts/a.rb], "its directory" => %w[scripts] }.each do |label, paths|
      it "leaves the call untyped when the argument is #{label} and another root defines the name" do
        File.write("lib/b.rb", "def helper = \"x\"\n")

        expect(editor_check(*paths)).not_to include("upcase")
      end
    end

    it "types the call in editor mode over the whole project when nothing else defines it" do
      File.write("lib/b.rb", "x = 1\n")

      expect(editor_check).to include("undefined method `upcase' for Integer")
    end
  end

  # The same project, run whole, does type it when nothing else defines the name: the declines above are the entry
  # points', not the rule's.
  it "types the call under a whole-project check when no other file defines the name" do
    configuration = Rigor::Configuration.load
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))

    expect(result.diagnostics.map(&:qualified_rule)).to include("call.undefined-method")
  end
end
