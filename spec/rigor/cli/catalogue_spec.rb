# frozen_string_literal: true

require "fileutils"
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

  it "marks an optional argument instead of keeping its brackets" do
    flag = by_name.fetch("check").fetch("flags").find { |item| item["name"] == "--bleeding-edge" }

    expect(flag).to include("arg" => "LIST", "optional" => true)
    expect(by_name.fetch("check").fetch("flags").find { |item| item["name"] == "--config" })
      .to include("arg" => "PATH", "optional" => false)
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

    it "still lists the commands for `help -h`, wherever the flag is" do
      expect(run_cli("help", "-h")).to eq(run_cli("help"))
      expect(run_cli("help", "--format=json", "-h")).to eq(run_cli("help"))
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

    it "is answered by `rigor describe` and `rigor skill describe` with the usage of the spelling used" do
      expect(run_cli("describe", "--help")).to eq([0, "Usage: rigor describe [--deep]\n", ""])
      expect(run_cli("skill", "describe", "--help")).to eq([0, "Usage: rigor skill describe [--deep]\n", ""])
      expect(run_cli("skill", "--describe", "--help")).to eq([0, "Usage: rigor skill describe [--deep]\n", ""])
    end

    it "is answered by `rigor version` with its usage instead of the version" do
      expect(run_cli("version", "--help")).to eq([0, "Usage: rigor version\n", ""])
      expect(run_cli("version")).to eq([0, "rigor #{Rigor::VERSION}\n", ""])
    end

    it "is answered by every catalogued subcommand with that subcommand's usage and exit 0" do
      pairs = entries.flat_map { |entry| entry.fetch("subcommands").map { |sub| [entry.fetch("name"), sub] } }

      expect(pairs.map { |name, sub| [name, sub.fetch("name")] }).to include(%w[baseline drift], %w[effects check],
                                                                             %w[skill describe])
      pairs.each do |name, sub|
        status, out, err = run_cli(name, sub.fetch("name"), "--help")

        expect([name, sub["name"], status, err]).to eq([name, sub["name"], 0, ""])
        expect(out.lines.first.chomp).to eq(sub.fetch("usage")), "#{name} #{sub['name']}"
      end
    end

    it "is answered by the deprecated `rigor plugin` verbs without running them" do
      %w[list path print root].each do |verb|
        status, out, err = run_cli("plugin", verb, "--help")

        expect([verb, status, err]).to eq([verb, 0, ""])
        expect(out).to start_with("Usage: rigor plugin")
      end
    end

    it "is answered by `rigor help <command>` with the same usage as the catalogue" do
      entries.each do |entry|
        next if entry.fetch("name") == "playground"

        _status, out, = run_cli("help", entry.fetch("name"))
        expect(out.lines.first.chomp).to eq(entry.fetch("usage")), entry.fetch("name")
      end
    end
  end

  describe "the plugin and skill grammars" do
    it "reads the flags of `plugin` and `skill` from their parsers" do
      expect(by_name.fetch("plugin").fetch("flags").map { |flag| flag["name"] }).to eq(%w[--path --list --root])
      expect(by_name.fetch("plugin").fetch("subcommands")).to eq([])
      expect(by_name.fetch("skill").fetch("flags").map { |flag| flag["name"] })
        .to eq(%w[--full --path --list --describe])
    end

    it "lists `skill describe --deep`" do
      describe_sub = by_name.fetch("skill").fetch("subcommands").find { |sub| sub["name"] == "describe" }

      expect(describe_sub.fetch("flags").map { |flag| flag["name"] }).to eq(["--deep"])
    end
  end

  describe "an unknown command" do
    it "suggests the nearest command" do
      status, out, err = run_cli("chek")

      expect([status, out]).to eq([Rigor::CLI::EXIT_USAGE, ""])
      expect(err).to include("Unknown command: chek").and include("Did you mean `rigor check`?")
    end

    it "suggests nothing when no command is near, and still prints the help" do
      _status, _out, err = run_cli("zzzzzzzz")

      expect(err).to include("Unknown command: zzzzzzzz").and include("Commands:")
      expect(err).not_to include("Did you mean")
    end

    it "suggests the nearest baseline verb" do
      status, _out, err = run_cli("baseline", "drfit")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("Unknown baseline subcommand: \"drfit\"")
      expect(err).to include("Did you mean `rigor baseline drift`?")
    end

    it "suggests the nearest effects verb, and leaves a real path alone" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          status, out, err = run_cli("effects", "updat")

          expect([status, out]).to eq([Rigor::CLI::EXIT_USAGE, ""])
          expect(err).to include("unknown effects subcommand: updat")
          expect(err).to include("Did you mean `rigor effects update`?")

          %w[check.rb checks/ ./updat].each do |word|
            _status, _out, err = run_cli("effects", word)
            expect(err).not_to include("Did you mean"), word
          end

          FileUtils.mkdir_p("updat")
          _status, _out, err = run_cli("effects", "updat")
          expect(err).not_to include("Did you mean")
        end
      end
    end
  end

  # ADR-126 WD3 / #2511 — the MCP server turns each `inputSchema` property into a flag, a positional, or something it
  # handles itself. The server's own argv builder is probed with a distinct value per property, so the flag a property
  # becomes is read from the server rather than restated here; each one must be a flag its catalogued command accepts.
  # A property that becomes no flag must be listed below, so a new positional or self-handled property is a conscious
  # addition, and a stale entry fails too.
  describe "the MCP tools' inputSchema against the catalogue flags" do
    let(:non_flag_properties) do
      {
        "rigor_check" => %w[paths],
        "rigor_type_of" => %w[file line col],
        "rigor_triage" => %w[paths],
        "rigor_lens" => %w[files],
        "rigor_annotate" => %w[file],
        "rigor_sig_gen" => %w[paths],
        "rigor_explain" => %w[rule],
        "rigor_coverage" => %w[paths]
      }
    end

    # One distinct, recognisable value per property: a string or array names its property, an integer is numbered.
    def probe_arguments(tool)
      tool.dig(:inputSchema, :properties).each_with_index.to_h do |(name, schema), index|
        value = case schema.fetch(:type)
                when "integer" then 90_000 + index
                when "array" then ["sentinel-#{name}"]
                else "sentinel-#{name}"
                end
        [name.to_s, value]
      end
    end

    def probe_text(value)
      value.is_a?(Array) ? value.first.to_s : value.to_s
    end

    # The argv tokens after the command word and before the `--` that ends the options: the flags the server passed,
    # not the positionals.
    def option_tokens(argv)
      argv.drop(1).take_while { |token| token != "--" }
    end

    def flag_name(token)
      token.split("=", 2).first
    end

    it "names a catalogued flag for every property that becomes one, and lists the rest" do
      server = Rigor::MCP::Server.new

      Rigor::MCP::Server::TOOLS.each do |tool|
        name = tool.fetch(:name)
        command = entries.find { |entry| entry.fetch("mcp_tool") == name }
        catalogued = command.fetch("flags").map { |flag| flag.fetch("name") }
        probes = probe_arguments(tool)
        options = option_tokens(server.send(:build_argv, name, probes))

        flag_of = probes.to_h do |property, value|
          token = options.find { |option| option.include?(probe_text(value)) }
          [property, token && flag_name(token)]
        end

        expect(flag_of.compact.reject { |_, flag| catalogued.include?(flag) })
          .to eq({}), "#{name}: properties become flags the command #{command.fetch('name')} does not accept"
        expect(flag_of.select { |_, flag| flag.nil? }.keys)
          .to match_array(non_flag_properties.fetch(name)), "#{name}: properties that become no flag"
      end
    end

    it "checks every flag the server passes, not only those a property sets" do
      server = Rigor::MCP::Server.new

      Rigor::MCP::Server::TOOLS.each do |tool|
        name = tool.fetch(:name)
        command = entries.find { |entry| entry.fetch("mcp_tool") == name }
        catalogued = command.fetch("flags").map { |flag| flag.fetch("name") }
        options = option_tokens(server.send(:build_argv, name, probe_arguments(tool)))

        expect(options.map { |token| flag_name(token) } - catalogued)
          .to eq([]), "#{name}: flags the server passes that #{command.fetch('name')} does not accept"
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
