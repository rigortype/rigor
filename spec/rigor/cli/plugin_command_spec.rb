# frozen_string_literal: true

require "stringio"

require "rigor/cli"
require "rigor/cli/plugin_command"

# `rigor plugin` (singular) exposes the plugin source Rigor bundles under `plugins/` and `examples/` so authors (and the
# `rigor-plugin-author` skill) can read a real, working plugin as a worked example. The examples here exercise the real
# on-disk tree so the contract the skill + AI agents depend on is verified end-to-end.
RSpec.describe Rigor::CLI::PluginCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv.dup, out: out, err: err).run
    [status, out.string, err.string]
  end

  describe "the default and --list" do
    it "lists production and example plugins with absolute directory paths" do
      status, out, err = run([])
      expect(status).to eq(0)
      expect(err).to eq("")
      expect(out).to include("rigor-activerecord")
      expect(out).to include("rigor-activesupport-core-ext")
      expect(out).to include("Production plugins")
      expect(out).to include("Example plugins")
      out.each_line do |line|
        next unless line.start_with?("  rigor-")

        path = line.split("  ").reject(&:empty?).last.strip
        expect(File.directory?(path)).to be(true), "expected #{path.inspect} to be a directory"
      end
    end

    it "gives --list the same listing as no argument" do
      expect(run(["--list"])).to eq(run([]))
    end

    it "mentions the engine source root and the Docker path caveat" do
      _status, out, = run(["--list"])
      expect(out).to include("Engine source root:")
      expect(out).to include("lib/rigor/plugin.rb")
      expect(out).to match(/container/i)
    end
  end

  describe "--path" do
    it "prints the absolute plugin directory on a single line" do
      status, out, = run(%w[--path rigor-activerecord])
      expect(status).to eq(0)
      lines = out.strip.split("\n")
      expect(lines.size).to eq(1)
      expect(lines.first).to end_with("plugins/rigor-activerecord")
      expect(File.directory?(lines.first)).to be(true)
    end

    it "resolves a name given without the rigor- prefix" do
      status, out, = run(%w[--path activerecord])
      expect(status).to eq(0)
      expect(out.strip).to end_with("plugins/rigor-activerecord")
    end

    it "exits 1 on an unknown plugin name" do
      status, _out, err = run(%w[--path no-such-plugin])
      expect(status).to eq(1)
      expect(err).to include("Unknown plugin: no-such-plugin")
    end

    it "raises a parse error, which the CLI reports as a usage error, when no name is given" do
      expect { run(["--path"]) }.to raise_error(OptionParser::MissingArgument)
    end
  end

  describe "<name>" do
    it "prints a header followed by the plugin's main lib source" do
      status, out, err = run(%w[rigor-activerecord])
      expect(status).to eq(0)
      expect(err).to eq("")
      expect(out).to start_with("# Rigor plugin: rigor-activerecord")
      expect(out).to include("# Directory:")
      expect(out).to include("# Sig:")
      expect(out).to match(/Rigor::Plugin|require|module/)
    end

    it "exits 1 on an unknown plugin name, with no did-you-mean for plugin names" do
      status, _out, err = run(%w[no-such-plugin])
      expect(status).to eq(1)
      expect(err).to include("Unknown plugin: no-such-plugin")
    end
  end

  describe "--root" do
    it "prints the gem root and key subdirectories" do
      status, out, = run(["--root"])
      expect(status).to eq(0)
      expect(out).to include("rigortype gem root:")
      expect(out).to include("plugins (production plugins)")
      expect(out).to include("public plugin API")
    end
  end

  describe "the deprecated verbs" do
    {
      %w[list] => %w[--list],
      %w[path rigor-activerecord] => %w[--path rigor-activerecord],
      %w[print rigor-activerecord] => ["rigor-activerecord"],
      %w[root] => %w[--root],
      %w[path no-such-plugin] => %w[--path no-such-plugin],
      %w[print no-such-plugin] => %w[no-such-plugin]
    }.each do |old, replacement|
      it "keeps `#{old.join(' ')}` working as `#{replacement.join(' ')}` does, with the notice on stderr only" do
        status_old, out_old, err_old = run(old)
        status_new, out_new, err_new = run(replacement)

        expect([status_old, out_old]).to eq([status_new, out_new])
        expect(err_old).to start_with("rigor: `rigor plugin #{old.first}` is deprecated")
        expect(err_old).to include("use `rigor plugin")
        expect(err_new).not_to include("deprecated")
      end
    end

    it "names the replacement of each verb" do
      expect(run(["list"])[2]).to include("`rigor plugin --list`")
      expect(run(%w[path activerecord])[2]).to include("`rigor plugin --path <name>`")
      expect(run(%w[print activerecord])[2]).to include("`rigor plugin <name>`")
      expect(run(["root"])[2]).to include("`rigor plugin --root`")
    end

    it "keeps the usage error for a verb missing its name" do
      status, _out, err = run(["path"])
      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("requires a plugin name")
      expect(err).to include("deprecated")
    end
  end

  describe "help" do
    it "writes usage to stdout and exits 0 for help, -h and --help" do
      %w[help -h --help].each do |flag|
        status, out, = run([flag])
        expect(status).to eq(0)
        expect(out).to start_with("Usage: rigor plugin")
        expect(out).to include("--path <name>")
      end
    end

    it "answers --help on the deprecated verbs with the usage and no notice or side effect" do
      %w[list path print root].each do |verb|
        expect(run([verb, "--help"])).to eq([0, described_class::USAGE, ""])
      end
    end
  end

  describe "#option_parser" do
    it "describes the switches the command parses" do
      flags = described_class.new(argv: []).option_parser.top.list.filter_map { |sw| sw.long.first }
      expect(flags).to eq(%w[--path --list --root])
    end
  end
end
