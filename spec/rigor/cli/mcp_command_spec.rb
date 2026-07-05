# frozen_string_literal: true

require "spec_helper"
require "stringio"

require "rigor/cli"
require "rigor/cli/mcp_command"

RSpec.describe Rigor::CLI::McpCommand do
  # Build the command with captured streams. The happy `#run` path boots a long-running stdio server loop (ADR-33), so
  # these examples exercise only the option parsing and the early-return branches — the unit-testable logic.
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def command(argv)
    described_class.new(argv: argv, out: out, err: err)
  end

  describe "#parse_options" do
    it "defaults to the stdio transport and no config" do
      expect(command([]).send(:parse_options)).to eq(transport: "stdio", config: nil)
    end

    it "reads --transport and --config" do
      options = command(["--transport=stdio", "--config=rigor.yml"]).send(:parse_options)
      expect(options).to eq(transport: "stdio", config: "rigor.yml")
    end

    it "returns :usage_error and prints the banner on an unknown flag" do
      cmd = command(["--nope"])
      expect(cmd.send(:parse_options)).to eq(:usage_error)
      expect(err.string).to include(described_class::USAGE)
    end
  end

  describe "#run" do
    it "rejects an unsupported transport with a usage exit (without booting a server)" do
      cmd = command(["--transport=websocket"])
      expect(cmd.run).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err.string).to include("unsupported transport").and include("websocket")
    end

    it "returns a usage exit when option parsing fails" do
      expect(command(["--nope"]).run).to eq(Rigor::CLI::EXIT_USAGE)
    end
  end
end
