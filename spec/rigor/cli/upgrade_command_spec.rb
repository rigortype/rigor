# frozen_string_literal: true

require "stringio"

require "rigor/cli"
require "rigor/cli/upgrade_command"

RSpec.describe Rigor::CLI::UpgradeCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv.dup, out: out, err: err).run
    [status, out.string, err.string]
  end

  it "is a Command subclass" do
    expect(described_class.superclass).to eq(Rigor::CLI::Command)
  end

  it "prints the queued message and version, exiting 0" do
    status, out, err = run([])
    expect(status).to eq(0)
    expect(out).to include("No migration target available yet")
    expect(out).to include("ADR-50 WD7")
    expect(out).to include("Current version: #{Rigor::VERSION}")
    expect(err).to be_empty
  end

  it "is reachable through the CLI dispatcher" do
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI.start(["upgrade"], out: out, err: err)
    expect(status).to eq(0)
    expect(out.string).to include("No migration target available yet")
  end
end
