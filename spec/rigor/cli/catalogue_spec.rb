# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/mcp/server"

# ADR-126 WD3 / #2505 — the CLI surface is read from one catalogue, and this spec is the drift gate: a command that is
# dispatched but not catalogued, a tool with no command behind it, a command that does not answer `--help`, or a
# `--format` that is checked late all fail here.
RSpec.describe Rigor::CLI::Catalogue do
  # OptionParser answers its built-in `--help` on `$stdout` and then exits, not on the command's `out:`, so both are
  # captured: `$stdout` is swapped for the same buffer and a `SystemExit` is read as the status.
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = begin
      original = $stdout
      $stdout = out
      Rigor::CLI.start(argv, out: out, err: err)
    rescue SystemExit => e
      e.status
    ensure
      $stdout = original
    end

    [status, out.string, err.string]
  end

  let(:entries) { described_class.entries }
  let(:by_name) { entries.to_h { |entry| [entry.fetch("name"), entry] } }

  it "names exactly the dispatched commands plus help and version" do
    expect(entries.map { |entry| entry.fetch("name") })
      .to match_array(Rigor::CLI::HANDLERS.keys + %w[help version])
  end

  it "maps every MCP tool to a catalogued command" do
    tool_names = Rigor::MCP::Server::TOOLS.map { |tool| tool.fetch(:name) }
    mapped = entries.filter_map { |entry| entry["mcp_tool"] }

    expect(mapped).to match_array(tool_names)
  end

  it "gives every entry a summary and a usage line" do
    entries.each do |entry|
      expect(entry.fetch("summary")).not_to be_empty, entry.fetch("name")
      expect(entry.fetch("usage")).to start_with("Usage: rigor "), entry.fetch("name")
    end
  end

  it "reads the flags of an OptionParser command from its parser" do
    flags = by_name.fetch("check").fetch("flags").map { |flag| flag.fetch("name") }

    expect(flags).to include("--format", "--config", "--workers")
  end

  it "lists a subcommand's own flags" do
    drift = by_name.fetch("baseline").fetch("subcommands").find { |sub| sub["name"] == "drift" }

    expect(drift.fetch("flags").map { |flag| flag.fetch("name") }).to include("--only")
  end

  it "gives every subcommand the same entry shape, declared or parsed" do
    shapes = entries.flat_map { |entry| entry.fetch("subcommands") }.map { |sub| sub.keys.sort }

    expect(shapes.uniq).to eq([%w[flags formats name usage]])
  end

  it "reports a command's formats from its own --format only" do
    baseline = by_name.fetch("baseline")
    dump = baseline.fetch("subcommands").find { |sub| sub["name"] == "dump" }

    expect(baseline.fetch("formats")).to eq([])
    expect(dump.fetch("formats")).to eq(%w[text json])
  end

  it "lists a command's --format formats whenever it has the flag" do
    flagged = entries + entries.flat_map { |entry| entry.fetch("subcommands") }
    flagged = flagged.select { |item| item.fetch("flags").any? { |flag| flag["name"] == "--format" } }

    expect(flagged).not_to be_empty
    expect(flagged.map { |item| item.fetch("formats") }).to all(include("text"))
  end

  it "expands --[no-]x into the literal flags" do
    names = by_name.fetch("check").fetch("flags").map { |flag| flag.fetch("name") }

    expect(names).to include("--stats", "--no-stats")
    expect(names.grep(/\[no-\]/)).to be_empty
  end

  it "takes the effects usage from the command" do
    expect(by_name.fetch("effects").fetch("usage")).to eq(Rigor::CLI::EffectsCommand::USAGE)
  end

  it "lists the CI formats `rigor check` accepts" do
    expect(by_name.fetch("check").fetch("formats")).to include("text", "json", "sarif", "teamcity")
  end

  describe "rigor help" do
    it "lists every catalogued command in the text help" do
      _status, out, _err = run_cli("help")

      missing = entries.map { |entry| entry.fetch("name") }.reject do |name|
        out.lines.any? { |line| line.match?(/\A {2}#{Regexp.escape(name)}\s/) }
      end
      expect(missing).to be_empty
    end

    it "points agents at describe and the JSON surface on its last line" do
      _status, out, _err = run_cli("help")

      expect(out.lines.last).to include("rigor describe").and include("rigor help --format=json")
    end

    it "prints the catalogue as JSON" do
      status, out, _err = run_cli("help", "--format=json")
      document = JSON.parse(out)

      expect(status).to eq(0)
      expect(document).to include("schema_version" => 1, "version" => Rigor::VERSION)
      expect(document.fetch("commands").size).to eq(Rigor::CLI::HANDLERS.size + 2)
    end

    it "rejects an unknown format before printing anything" do
      status, out, err = run_cli("help", "--format=xml")

      expect([status, out]).to eq([Rigor::CLI::EXIT_USAGE, ""])
      expect(err).to include("invalid argument: --format=xml")
    end

    it "prints a command's help for `help <command>`, as `<command> --help` does" do
      _status, via_help, = run_cli("help", "type-of")
      _status, direct, = run_cli("type-of", "--help")

      expect(via_help).to eq(direct)
      expect(via_help).to start_with("Usage: rigor type-of")
    end

    it "does not parse the flags of the command it describes" do
      expect(run_cli("help", "type-of", "--workers=2")).to eq(run_cli("help", "type-of"))
    end

    it "refuses a second word instead of answering with the parent's help" do
      status, out, err = run_cli("help", "baseline", "drift")

      expect([status, out]).to eq([Rigor::CLI::EXIT_USAGE, ""])
      expect(err).to include("takes one command")
    end

    it "still lists the commands for `help -h`" do
      expect(run_cli("help", "-h")).to eq(run_cli("help"))
    end

    it "reports an unknown command as a usage error" do
      status, _out, err = run_cli("help", "nonesuch")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("Unknown command: nonesuch")
    end
  end

  # `playground` hands its argv to the optional `rigor-playground` gem, which may not be installed.
  describe "--help" do
    (Rigor::CLI::HANDLERS.keys - %w[playground]).each do |name|
      it "is answered by `rigor #{name}` with its usage and exit 0" do
        status, out, = run_cli(name, "--help")

        expect(status).to eq(0)
        expect(out).to start_with("Usage: rigor #{name}")
      end
    end

    it "is answered by `rigor describe` and `rigor skill describe` with the describe usage" do
      expect(run_cli("describe", "--help")).to eq([0, "Usage: rigor describe [--deep]\n", ""])
      expect(run_cli("skill", "describe", "--help")).to eq([0, "Usage: rigor describe [--deep]\n", ""])
    end

    it "is answered by `rigor help <command>` with the same usage as the catalogue" do
      entries.each do |entry|
        next if entry.fetch("name") == "playground"

        _status, out, = run_cli("help", entry.fetch("name"))
        expect(out).to start_with("Usage: rigor #{entry.fetch('name')}"), entry.fetch("name")
      end
    end
  end

  describe "--format validation" do
    def formatted_invocations
      entries.flat_map do |entry|
        own = entry.fetch("formats").include?("json") ? [[entry.fetch("name")]] : []
        subs = entry.fetch("subcommands").select { |sub| sub.fetch("formats").include?("json") }
        own + subs.map { |sub| [entry.fetch("name"), sub.fetch("name")] }
      end
    end

    it "covers each command and subcommand that lists json among its formats" do
      expect(formatted_invocations).to include(%w[check], %w[triage], %w[doctor], %w[plugins], %w[help], %w[annotate],
                                               %w[effects], %w[effects check], %w[baseline dump])
      expect(formatted_invocations).not_to include(%w[baseline])
    end

    it "rejects an unknown --format with exit 64 before running" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          formatted_invocations.each do |argv|
            status, out, err = run_cli(*argv, "--format=bogus")

            expect([argv, status, out]).to eq([argv, Rigor::CLI::EXIT_USAGE, ""])
            expect(err).to include("invalid argument: --format=bogus")
          end
        end
      end
    end
  end
end
