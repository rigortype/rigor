# frozen_string_literal: true

require "stringio"

require "rigor/cli"
require "rigor/cli/plugin_command"

# `rigor plugin` (singular) exposes the plugin source Rigor bundles
# under `plugins/` and `examples/` so authors (and the
# `rigor-plugin-author` skill) can read a real, working plugin as a
# worked example. The examples here exercise the real on-disk tree so
# the contract the skill + AI agents depend on is verified end-to-end.
RSpec.describe Rigor::CLI::PluginCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv.dup, out: out, err: err).run
    [status, out.string, err.string]
  end

  describe "list" do
    it "lists production and example plugins with absolute directory paths" do
      status, out, = run(["list"])
      expect(status).to eq(0)
      expect(out).to include("rigor-activerecord")
      expect(out).to include("rigor-activesupport-core-ext")
      expect(out).to include("Production plugins")
      expect(out).to include("Example plugins")
      # Every listed directory path must exist.
      out.each_line do |line|
        next unless line.start_with?("  rigor-")

        path = line.split("  ").reject(&:empty?).last.strip
        expect(File.directory?(path)).to be(true), "expected #{path.inspect} to be a directory"
      end
    end

    it "is the default when no subcommand is given" do
      status_list, out_list, = run(["list"])
      status_default, out_default, = run([])
      expect(status_default).to eq(status_list)
      expect(out_default).to eq(out_list)
    end

    it "mentions the engine source root and the Docker path caveat" do
      _status, out, = run(["list"])
      expect(out).to include("Engine source root:")
      expect(out).to include("lib/rigor/plugin.rb")
      expect(out).to match(/container/i)
    end
  end

  describe "path" do
    it "prints the absolute plugin directory on a single line" do
      status, out, = run(%w[path rigor-activerecord])
      expect(status).to eq(0)
      lines = out.strip.split("\n")
      expect(lines.size).to eq(1)
      expect(lines.first).to end_with("plugins/rigor-activerecord")
      expect(File.directory?(lines.first)).to be(true)
    end

    it "resolves a name given without the rigor- prefix" do
      status, out, = run(%w[path activerecord])
      expect(status).to eq(0)
      expect(out.strip).to end_with("plugins/rigor-activerecord")
    end

    it "exits 1 on an unknown plugin name" do
      status, _out, err = run(%w[path no-such-plugin])
      expect(status).to eq(1)
      expect(err).to include("Unknown plugin: no-such-plugin")
    end

    it "is a usage error when no name is given" do
      status, _out, err = run(["path"])
      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("requires a plugin name")
    end
  end

  describe "print" do
    it "prints a header followed by the plugin's main lib source" do
      status, out, = run(%w[print rigor-activerecord])
      expect(status).to eq(0)
      expect(out).to start_with("# Rigor plugin: rigor-activerecord")
      expect(out).to include("# Directory:")
      expect(out).to include("# Sig:")
      # The lib body follows — a real Ruby source file.
      expect(out).to match(/Rigor::Plugin|require|module/)
    end

    it "exits 1 on an unknown plugin name" do
      status, _out, err = run(%w[print no-such-plugin])
      expect(status).to eq(1)
      expect(err).to include("Unknown plugin: no-such-plugin")
    end
  end

  describe "root" do
    it "prints the gem root and key subdirectories" do
      status, out, = run(["root"])
      expect(status).to eq(0)
      expect(out).to include("rigortype gem root:")
      expect(out).to include("plugins (production plugins)")
      expect(out).to include("public plugin API")
    end
  end

  describe "unknown subcommand" do
    it "writes usage to stderr and returns EXIT_USAGE" do
      status, _out, err = run(["bogus"])
      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("Unknown subcommand: bogus")
      expect(err).to include("Usage: rigor plugin")
    end
  end

  describe "help" do
    it "writes usage to stdout and exits 0" do
      status, out, = run(["help"])
      expect(status).to eq(0)
      expect(out).to include("Usage: rigor plugin")
      expect(out).to include("print <name>")
    end
  end
end
