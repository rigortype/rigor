# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

FFI_INCREMENTAL_PLUGIN_LIB = File.expand_path("../../plugins/rigor-ffi/lib", __dir__)
$LOAD_PATH.unshift(FFI_INCREMENTAL_PLUGIN_LIB) unless $LOAD_PATH.include?(FFI_INCREMENTAL_PLUGIN_LIB)
require "rigor-ffi"

# Issue #1532 follow-up — rigor-ffi detects its `:ffx` / `:ffi` target by reading `./Gemfile.lock` literally,
# whatever `bundler.lockfile:` resolves to, and the target decides whether `plugin.ffi.ffx.unsupported-*`
# fires. The `--incremental` snapshot fingerprint digests the RESOLVED lockfile, so the plugin declares its
# detected target through `incremental_state_fingerprint` (ADR-88 channel c): flipping the target must send
# the warm snapshot cold instead of serving the stale diagnostics.
RSpec.describe "rigor check --incremental over rigor-ffi target detection" do
  before do
    Rigor::Plugin.unregister!
    Rigor::Plugin.register(Rigor::Plugin::FFI)
  end

  after { Rigor::Plugin.unregister! }

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def check(*flags)
    out = StringIO.new
    err = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *flags]
    Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: err).run
    [out.string, err.string]
  end

  def rules(json)
    JSON.parse(json).fetch("diagnostics").map { |diagnostic| diagnostic.fetch("rule") }
  end

  def write_project(extra_config = "")
    FileUtils.mkdir_p("deps")
    File.write(".rigor.yml",
               "paths:\n  - .\nbundler:\n  lockfile: deps/my.lock\nplugins:\n  - gem: rigor-ffi\n    id: ffi\n" +
               extra_config)
    File.write("deps/my.lock", "GEM\n  specs:\n")
    File.write("Gemfile.lock", "GEM\n  specs:\n    ffi (1.17.0)\n")
    File.write("a.rb", "module L\n  extend FFI::Library\n  callback :cb, [:int], :void\nend\n")
    File.write("b.rb", "class B\n  def x = 1\nend\n")
  end

  it "goes cold when ./Gemfile.lock gains ffx although bundler.lockfile: points elsewhere" do
    write_project
    expect(check("--incremental")[1]).to include("--incremental cold")
    expect(check("--incremental")[1]).to include("--incremental warm")

    File.write("Gemfile.lock", "GEM\n  specs:\n    ffi (1.17.0)\n    ffx (1.0.0)\n")
    File.write("b.rb", "class B\n  def x = 2\nend\n")
    out, err = check("--incremental")

    expect(err).to include("--incremental cold")
    expect(rules(out)).to include("ffx.unsupported-callback")
    expect(rules(out)).to eq(rules(check("--no-cache").first))
  end

  it "goes cold when an ext/**/extconf.rb gains FFX.create_makefile although the lockfile is unchanged" do
    write_project
    expect(check("--incremental")[1]).to include("--incremental cold")
    expect(check("--incremental")[1]).to include("--incremental warm")

    FileUtils.mkdir_p("ext/x")
    File.write("ext/x/extconf.rb", "require \"mkmf\"\nFFX.create_makefile(\"x\")\n")
    File.write("b.rb", "class B\n  def x = 2\nend\n")
    out, err = check("--incremental")

    expect(err).to include("--incremental cold")
    expect(rules(out)).to include("ffx.unsupported-callback")
    expect(rules(out)).to eq(rules(check("--no-cache").first))
  end

  it "stays warm across an edit that does not change the detected target" do
    write_project
    check("--incremental")
    File.write("b.rb", "class B\n  def x = 2\nend\n")

    expect(check("--incremental")[1]).to include("--incremental warm")
  end

  # Issue #1652 — with no source edit, the run-result slot answers before the engine or the plugin loads, so it
  # sees a target flip only through the rows of the reads the target was detected from, which the plugin makes
  # through its IoBoundary.
  context "with no source edit between runs" do
    def prime(*flags, config: "")
      write_project(config)
      check(*flags)
      check(*flags)
    end

    it "reports the ffx diagnostics once ./Gemfile.lock gains ffx" do
      prime("--incremental")
      File.write("Gemfile.lock", "GEM\n  specs:\n    ffi (1.17.0)\n    ffx (1.0.0)\n")
      out, = check("--incremental")

      expect(rules(out)).to include("ffx.unsupported-callback")
      expect(rules(out)).to eq(rules(check("--no-cache").first))
    end

    # `ext/` is excluded from analysis, or the new extconf.rb would be a new analysed file: another path set,
    # which no slot is keyed by.
    it "reports them once an extconf.rb in a new ext/ subdirectory calls FFX.create_makefile" do
      FileUtils.mkdir_p("ext/old")
      File.write("ext/old/extconf.rb", "require \"mkmf\"\ncreate_makefile(\"old\")\n")
      prime("--incremental", config: "exclude:\n  - \"**/ext/**\"\n")
      FileUtils.mkdir_p("ext/x")
      File.write("ext/x/extconf.rb", "require \"mkmf\"\nFFX.create_makefile(\"x\")\n")
      out, = check("--incremental")

      expect(rules(out)).to include("ffx.unsupported-callback")
      expect(rules(out)).to eq(rules(check("--no-cache").first))
    end

    it "is still served from the slot, with no analysis, while the target's inputs are unchanged" do
      prime("--incremental")
      allow(Rigor::Analysis::IncrementalSession).to receive(:new).and_call_original
      out, err = check("--incremental")

      expect(err).to include("--incremental warm")
      expect(Rigor::Analysis::IncrementalSession).not_to have_received(:new)
      expect(rules(out)).to eq(rules(check("--no-cache").first))
    end

    it "reports them from a plain cached run too once ./Gemfile.lock gains ffx" do
      prime
      File.write("Gemfile.lock", "GEM\n  specs:\n    ffi (1.17.0)\n    ffx (1.0.0)\n")
      out, = check

      expect(rules(out)).to include("ffx.unsupported-callback")
    end
  end
end
