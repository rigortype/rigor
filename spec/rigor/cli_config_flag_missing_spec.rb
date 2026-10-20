# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

require "rigor/cli"

# #1992 — `--config=PATH` naming no file ran the command with the default configuration and said nothing. The flag
# is now checked where it is read (CLI::Options.config_path), so every command that takes it refuses a missing file
# the same way. A command added with a `--config` flag belongs in this table.
RSpec.describe Rigor::CLI do
  # Commands that take `--config`, with arguments that would otherwise run. `lsp` and `mcp` are left out: they
  # serve on stdin, and a regression there would hang the example rather than fail it. They are covered at the
  # option-parser level by `Options.config_path`, which both call.
  commands_with_config = {
    "check" => %w[check --format=json -- lib/a.rb],
    "type-of" => %w[type-of -- lib/a.rb:1:1],
    "triage" => %w[triage -- lib],
    "lens" => %w[lens -- lib/a.rb],
    "annotate" => %w[annotate -- lib/a.rb],
    "sig-gen" => %w[sig-gen --print -- lib/a.rb],
    "coverage" => %w[coverage -- lib],
    "doctor" => %w[doctor],
    "effects update" => %w[effects update],
    "effects check" => %w[effects check],
    "baseline drift" => %w[baseline drift],
    "trace" => %w[trace -- lib/a.rb],
    "unused" => %w[unused],
    "plugins" => %w[plugins],
    "type-scan" => %w[type-scan -- lib],
    "diff" => %w[diff],
    "show-bleedingedge" => %w[show-bleedingedge]
  }

  around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

  before do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "class A\n  def m(x) = 1\nend\n")
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  # The flag goes before `--` (where options end) or, failing that, at the end of the arguments.
  def with_config(args, config)
    at = args.index("--") || args.size
    args.dup.insert(at, "--config=#{config}")
  end

  commands_with_config.each do |command, args|
    it "refuses a missing --config for `rigor #{command}` with a usage error" do
      status, _out, err = run_cli(*with_config(args, "missing.yml"))

      expect(status).to eq(described_class::EXIT_USAGE)
      expect(err).to include("rigor: config file not found: missing.yml")
    end
  end

  it "says a --config naming a directory is a directory, not a missing file" do
    status, _out, err = run_cli(*with_config(%w[check --format=json -- lib/a.rb], "lib"))

    expect(status).to eq(described_class::EXIT_USAGE)
    expect(err).to include("rigor: config path is a directory: lib")
  end

  it "says an empty --config is an empty path" do
    status, _out, err = run_cli(*with_config(%w[check --format=json -- lib/a.rb], ""))

    expect(status).to eq(described_class::EXIT_USAGE)
    expect(err).to include("rigor: empty config path")
  end

  # Positive control: an existing --config is read, and the command runs.
  it "still runs `rigor check` with an existing --config" do
    File.write("rigor.yml", "paths:\n  - lib\n")

    status, _out, err = run_cli("check", "--format=json", "--no-stats", "--config=rigor.yml", "--", "lib/a.rb")

    expect(err).not_to include("config file not found")
    expect(status).not_to eq(described_class::EXIT_USAGE)
  end
end
