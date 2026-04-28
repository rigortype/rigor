# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

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

  it "lists type-of in the help text" do
    status, out, _err = run_cli("help")

    expect(status).to eq(0)
    expect(out).to include("type-of")
  end

  it "reports unknown commands as usage errors" do
    status, _out, err = run_cli("nope")

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("Unknown command: nope")
  end

  describe "type-of" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_fixture(name, contents)
      path = File.join(tmpdir, name)
      File.write(path, contents)
      path
    end

    it "prints the inferred type for an integer literal in text format" do
      path = write_fixture("a.rb", "1 + 2\n")

      status, out, err = run_cli("type-of", "#{path}:1:1")

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("node:    Prism::IntegerNode")
      expect(out).to include("type:    1")
      expect(out).to include("erased:  Integer")
    end

    it "accepts FILE LINE COL as separate arguments" do
      path = write_fixture("a.rb", "\"hi\"\n")

      status, out, err = run_cli("type-of", path, "1", "1")

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("Prism::StringNode")
      expect(out).to include("erased:  String")
    end

    it "emits a JSON payload when --format=json is supplied" do
      path = write_fixture("a.rb", ":sym\n")

      status, out, _err = run_cli("type-of", "--format=json", "#{path}:1:1")

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["node"]).to eq("Prism::SymbolNode")
      expect(payload["type"]).to eq(":sym")
      expect(payload["erased"]).to eq("Symbol")
      expect(payload["line"]).to eq(1)
      expect(payload["column"]).to eq(1)
    end

    it "records fallbacks when --trace is supplied for unsupported nodes" do
      path = write_fixture("a.rb", "foo + bar\n")

      status, out, _err = run_cli("type-of", "--trace", "#{path}:1:1")

      expect(status).to eq(0)
      expect(out).to include("erased:  untyped")
      expect(out).to match(/fallbacks \(\d+\)/)
      expect(out).to include("Prism::CallNode (prism)")
    end

    it "includes a fallbacks array in JSON output when --trace is set" do
      path = write_fixture("a.rb", "foo + bar\n")

      _status, out, _err = run_cli("type-of", "--trace", "--format=json", "#{path}:1:1")

      payload = JSON.parse(out)
      expect(payload).to have_key("fallbacks")
      expect(payload["fallbacks"]).to be_an(Array)
      expect(payload["fallbacks"]).not_to be_empty
      expect(payload["fallbacks"].first).to include("node_class" => "Prism::CallNode", "family" => "prism")
    end

    it "omits the fallbacks key without --trace" do
      path = write_fixture("a.rb", "1\n")

      _status, out, _err = run_cli("type-of", "--format=json", "#{path}:1:1")

      payload = JSON.parse(out)
      expect(payload).not_to have_key("fallbacks")
    end

    it "reports an error and exits 1 when the file is missing" do
      status, _out, err = run_cli("type-of", "missing.rb:1:1")

      expect(status).to eq(1)
      expect(err).to include("file not found")
    end

    it "reports parse errors and exits 1" do
      path = write_fixture("a.rb", "def\n")

      status, _out, err = run_cli("type-of", "#{path}:1:1")

      expect(status).to eq(1)
      expect(err).not_to be_empty
    end

    it "reports a usage error when the position has no colon form" do
      path = write_fixture("a.rb", "1\n")

      status, _out, err = run_cli("type-of", path)

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("FILE:LINE:COL")
    end

    it "reports a usage error when line/column are not integers" do
      path = write_fixture("a.rb", "1\n")

      status, _out, err = run_cli("type-of", "#{path}:abc:1")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("must be integers")
    end

    it "reports a usage error when the position is out of range" do
      path = write_fixture("a.rb", "1\n")

      status, _out, err = run_cli("type-of", "#{path}:99:1")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("past the end")
    end
  end
end
