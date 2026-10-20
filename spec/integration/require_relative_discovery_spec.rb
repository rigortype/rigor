# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/analysis/incremental_session"
require "rigor/analysis/runner"
require "rigor/cli/check_command"
require "rigor/configuration"

# Issue #2021 — `rigor check plug/outer/plug.rb` with `paths: [lib]`. A run over path arguments discovers the
# configured paths as well (#684), but the argument lies outside them, so its sibling `plug/outer/plug/effects.rb`
# was not discovered: the bare `Effects` inside `Outer::Plug` fell through to the project's `Outer::Effects`, and
# each call on it drew a false `call.undefined-method` that checking `plug` did not. The file `require_relative`s
# the sibling, so discovery now follows that.
#
# The oracle is the same check over the argument's directory, which analyses the sibling too.
RSpec.describe "discovery through require_relative outside the configured paths (#2021)" do
  around do |example|
    Dir.mktmpdir("rigor-require-relative-discovery-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:extra_config) { {} }

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS
        .merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
        .merge(extra_config)
    )
  end

  def write(path, source)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  # The project's own `Outer::Effects`, which the lexical lookup reaches when the nearer one is not in view. Its
  # signature is what makes a call it does not answer a `call.undefined-method`, as `Rigor::Effects`'s is in #2021.
  def write_outer_effects
    write("sig/outer.rbs", <<~RBS)
      module Outer
        module Effects
          def self.outer_only: () -> Symbol
        end
      end
    RBS
    write("lib/outer/effects.rb", <<~RUBY)
      module Outer
        module Effects
          def self.outer_only = :outer
        end
      end
    RUBY
  end

  def write_plug(call: "Effects.entry_points", requires: ['require_relative "plug/effects"'])
    write("plug/outer/plug.rb", <<~RUBY)
      #{requires.join("\n")}

      module Outer
        class Plug
          def run = #{call}
        end
      end
    RUBY
  end

  def write_sibling(body = "module Effects\n      def self.entry_points = []\n    end",
                    path: "plug/outer/plug/effects.rb")
    write(path, <<~RUBY)
      module Outer
        class Plug
          #{body}
        end
      end
    RUBY
  end

  def rows(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }
          .map { |d| [File.basename(d.path.to_s), d.line, d.message] }.sort
  end

  def check(paths)
    rows(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), paths))
  end

  before { write_outer_effects }

  it "resolves a nested module a required sibling declares, as the directory run does" do
    write_plug
    write_sibling
    expect(check(%w[plug])).to eq([])
    expect(check(%w[plug/outer/plug.rb])).to eq([])
  end

  it "still reports the outer constant's missing method when the required file does not exist" do
    # A guard (passes without the fix): following the graph must not silence a call the outer constant misses.
    write_plug
    expect(check(%w[plug/outer/plug.rb])).to eq(
      [["plug.rb", 5, "undefined method `entry_points' for singleton(Outer::Effects)"]]
    )
  end

  it "still reports the outer constant's missing method when the required sibling declares no nested one" do
    # A guard (passes without the fix): a discovered sibling that declares no nearer constant leaves the outer one.
    write_plug
    write_sibling("def self.unrelated = 1")
    expected = [["plug.rb", 5, "undefined method `entry_points' for singleton(Outer::Effects)"]]
    expect(check(%w[plug]).select { |row| row.first == "plug.rb" }).to eq(expected)
    expect(check(%w[plug/outer/plug.rb])).to eq(expected)
  end

  it "resolves a qualified path whose first segment the required sibling declares" do
    write("sig/table.rbs", "module Outer\n  module Effects\n    module Table\n    end\n  end\nend\n")
    write_plug(call: "Effects::Table.rows")
    write_sibling("module Effects\n      module Table\n        def self.rows = []\n      end\n    end")
    expect(check(%w[plug/outer/plug.rb])).to eq([])
  end

  it "resolves a nested class the required sibling declares" do
    write_plug
    write_sibling("class Effects\n      def self.entry_points = []\n    end")
    expect(check(%w[plug/outer/plug.rb])).to eq([])
  end

  it "resolves a nested value constant the required sibling declares" do
    write("lib/outer/limit.rb", "module Outer\n  LIMIT = 3\nend\n")
    write_plug(call: "LIMIT.upcase")
    write_sibling('LIMIT = "x"')
    expect(check(%w[plug])).to eq([])
    expect(check(%w[plug/outer/plug.rb])).to eq([])
  end

  it "follows a required file's own require_relative" do
    write_plug(requires: ['require_relative "plug/loader"'])
    write("plug/outer/plug/loader.rb", "require_relative \"effects\"\n")
    write_sibling
    expect(check(%w[plug/outer/plug.rb])).to eq([])
  end

  it "does not follow a plain require, which names a gem's load path" do
    # A guard: it passes without the fix too. A `require` is resolved against `$LOAD_PATH`, which a gem owns.
    write_plug(requires: ['require "outer/plug/effects"'])
    write_sibling
    expect(check(%w[plug/outer/plug.rb])).to eq(
      [["plug.rb", 5, "undefined method `entry_points' for singleton(Outer::Effects)"]]
    )
  end

  it "does not follow a require_relative out of a file under the configured paths" do
    # The run over the configured paths does not follow it either, and a file's answer under `paths:` must not
    # depend on whether it was named on the command line.
    write("lib/outer/user.rb", <<~RUBY)
      require_relative "../../plug/outer/plug/effects"

      module Outer
        class Plug
          def run = Effects.entry_points
        end
      end
    RUBY
    write_sibling
    expected = [["user.rb", 5, "undefined method `entry_points' for singleton(Outer::Effects)"]]
    expect(check(nil)).to eq(expected)
    expect(check(%w[lib/outer/user.rb])).to eq(expected)
  end

  {
    "a def" => 'def load_effects = require_relative("plug/effects")',
    "an if" => 'if ENV.key?("X") then require_relative "plug/effects" end',
    "a rescuing begin" => 'begin; require_relative "plug/effects"; rescue LoadError; end'
  }.each do |construct, line|
    it "follows a require_relative written inside #{construct}" do
      write_plug(requires: [line])
      write_sibling
      expect(check(%w[plug/outer/plug.rb])).to eq([])
    end
  end

  it "follows a require_relative spelled with the .rb extension" do
    write_plug(requires: ['require_relative "plug/effects.rb"'])
    write_sibling
    expect(check(%w[plug/outer/plug.rb])).to eq([])
  end

  it "does not follow a target that is a directory, not a file" do
    write_plug(requires: ['require_relative "plug/effects"'])
    write_sibling(path: "plug/outer/plug/effects.rb/inner.rb")
    expect(check(%w[plug/outer/plug.rb])).to eq(
      [["plug.rb", 5, "undefined method `entry_points' for singleton(Outer::Effects)"]]
    )
  end

  it "discovers no target that is not a file" do
    # The incremental session digests this set; a missing or directory target is an existence input instead.
    write_plug(requires: ['require_relative "plug/effects"', 'require_relative "plug/absent"'])
    write_sibling(path: "plug/outer/plug/effects.rb/inner.rb")
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    expect(runner.discovery_only_file_set(%w[plug/outer/plug.rb]).grep(%r{plug/outer/plug/})).to eq([])
  end

  it "stops the walk at a target under the configured paths" do
    # The run over the configured paths does not follow `mid.rb`'s require_relative out of them, so a walk that
    # passed through it would discover a nearer constant only when `plug.rb` is named.
    write_plug(requires: ['require_relative "../../lib/outer/mid"'])
    write("lib/outer/mid.rb", "require_relative \"../../plug/outer/plug/effects\"\n")
    write_sibling
    expect(check(%w[plug/outer/plug.rb])).to eq(
      [["plug.rb", 5, "undefined method `entry_points' for singleton(Outer::Effects)"]]
    )
  end

  # The walk sees one entry point's load graph. A file it does not reach (here through a plain `require`) may
  # redefine a method a walked file defines, so a walked file's methods exist but their bodies are not read.
  context "when a walked file's method may be redefined elsewhere" do
    before do
      write_plug(call: "Helper.value.upcase", requires: ['require_relative "plug/helper"', 'require "outer/override"'])
      write("plug/outer/plug/helper.rb", "module Outer\n  module Helper\n    def self.value = 1\n  end\nend\n")
      write("vendor/outer/override.rb", "module Outer\n  module Helper\n    def self.value = \"s\"\n  end\nend\n")
    end

    it "does not read the walked method's return type" do
      expect(check(%w[plug/outer/plug.rb])).to eq([])
    end

    it "does not read the walked method's return type under --incremental" do
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: %w[plug/outer/plug.rb])
      expect(guarded_baseline(session).select { |d| d.rule == "call.undefined-method" }).to eq([])
    end

    it "does not check a call's arity against the walked method" do
      write_plug(call: "Helper.value(1, 2)", requires: ['require_relative "plug/helper"'])
      expect(check(%w[plug/outer/plug.rb]).map(&:first)).to eq([])
      expect(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil),
                         %w[plug/outer/plug.rb]).diagnostics.map(&:rule)).not_to include("call.wrong-arity")
    end
  end

  it "answers an argument spelled through a symlinked directory as it answers the relative one" do
    # The configured `lib` and a walked `../../lib/outer/limit.rb` name the same file. Compared by spelling, it
    # joined discovery twice, and two writers withhold the constant (#644).
    write("lib/outer/limit.rb", "module Outer\n  LIMIT = 3\nend\n")
    write_plug(call: "LIMIT.upcase", requires: ['require_relative "../../lib/outer/limit"'])
    File.symlink(Dir.pwd, "alias")
    expected = [["plug.rb", 5, "undefined method `upcase' for 3"]]
    expect(check(%w[plug/outer/plug.rb])).to eq(expected)
    expect(check([File.join(Dir.pwd, "alias", "plug/outer/plug.rb")])).to eq(expected)
  end

  context "when the configured path is spelled through a symlinked directory" do
    let(:extra_config) { { "paths" => [File.join(Dir.pwd, "alias", "lib")] } }

    it "does not discover a configured file a second time through its real spelling" do
      write("lib/outer/limit.rb", "module Outer\n  LIMIT = 3\nend\n")
      write_plug(call: "LIMIT.upcase", requires: ['require_relative "../../lib/outer/limit"'])
      File.symlink(Dir.pwd, "alias")
      expect(check(%w[plug/outer/plug.rb])).to eq([["plug.rb", 5, "undefined method `upcase' for 3"]])
    end
  end

  context "when `exclude:` matches the required sibling" do
    let(:extra_config) { { "exclude" => ["plug/outer/plug/**"] } }

    it "leaves the excluded file out of discovery" do
      write_plug
      write_sibling
      expect(check(%w[plug/outer/plug.rb])).to eq(
        [["plug.rb", 5, "undefined method `entry_points' for singleton(Outer::Effects)"]]
      )
    end
  end

  context "with the fork pool" do
    let(:extra_config) { { "workers" => 2 } }

    it "resolves the required sibling's nested constant in a worker" do
      write_plug
      write_sibling
      write("plug/outer/both.rb", "require_relative \"plug\"\n")
      expect(check(%w[plug/outer/plug.rb plug/outer/both.rb])).to eq([])
    end
  end

  describe "with --incremental" do
    let(:paths) { %w[plug/outer/plug.rb] }

    def session
      Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths)
    end

    before do
      write_plug
      write_sibling
    end

    it "keeps the required sibling in view on a recheck and re-baselines when it is edited" do
      live = session
      expect(rows_of(guarded_baseline(live))).to eq([])
      File.write("plug/outer/plug.rb", "#{File.read('plug/outer/plug.rb')}# edited\n")
      expect(rows_of(guarded_recheck(live).diagnostics)).to eq([])
      expect(rows_of(guarded_reanalyze_subset(live, paths))).to eq([])

      write_sibling("def self.unrelated = 1")
      expect(rows_of(guarded_recheck(live).diagnostics)).to eq(
        [["plug.rb", 5, "undefined method `entry_points' for singleton(Outer::Effects)"]]
      )
    end

    def rows_of(diagnostics)
      diagnostics.select { |d| d.rule == "call.undefined-method" }
                 .map { |d| [File.basename(d.path.to_s), d.line, d.message] }.sort
    end
  end

  describe "through the CLI" do
    def cli(*argv)
      out = StringIO.new
      Rigor::CLI::CheckCommand.new(
        argv: ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *argv], out: out, err: StringIO.new
      ).run
      JSON.parse(out.string).fetch("diagnostics").select { |d| d.fetch("rule") == "call.undefined-method" }
          .map { |d| [File.basename(d.fetch("path")), d.fetch("line")] }
    end

    before do
      File.write(".rigor.yml", "paths:\n  - lib\n")
      write_plug
      write_sibling
    end

    it "re-checks a cached run when the required sibling stops declaring the nested constant" do
      expect(cli("plug/outer/plug.rb")).to eq([])
      expect(cli("plug/outer/plug.rb")).to eq([])
      write_sibling("def self.unrelated = 1")
      expect(cli("plug/outer/plug.rb")).to eq([["plug.rb", 5]])
    end

    it "reads the require_relative from an editor buffer" do
      File.write("buf.rb", File.read("plug/outer/plug.rb"))
      write_plug(requires: [])
      expect(cli("plug/outer/plug.rb")).to eq([["plug.rb", 5]])
      expect(cli("--tmp-file=buf.rb", "--instead-of=plug/outer/plug.rb", "plug/outer/plug.rb")).to eq([])
    end

    it "re-checks a cached run when a missing required file appears" do
      FileUtils.rm_rf("plug/outer/plug")
      expect(cli("plug/outer/plug.rb")).to eq([["plug.rb", 5]])
      expect(cli("plug/outer/plug.rb")).to eq([["plug.rb", 5]])
      write_sibling
      expect(cli("plug/outer/plug.rb")).to eq([])
    end

    it "re-checks an --incremental run when a missing required file appears" do
      FileUtils.rm_rf("plug/outer/plug")
      expect(cli("--incremental", "plug/outer/plug.rb")).to eq([["plug.rb", 5]])
      expect(cli("--incremental", "plug/outer/plug.rb")).to eq([["plug.rb", 5]])
      write_sibling
      expect(cli("--incremental", "plug/outer/plug.rb")).to eq([])
    end
  end
end
