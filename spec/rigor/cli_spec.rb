# frozen_string_literal: true

require "stringio"

RSpec.describe Rigor::CLI do
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.start(argv, out: out, err: err)

    [status, out.string, err.string]
  end

  it "prints the version" do
    status, out, err = run_cli("version")

    expect(status).to eq(0)
    expect(out).to eq("rigor #{Rigor::VERSION}\n")
    expect(err).to eq("")
  end

  it "reports unknown commands as usage errors" do
    status, _out, err = run_cli("nope")

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("Unknown command: nope")
  end
end
