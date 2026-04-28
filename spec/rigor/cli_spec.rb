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

    it "auto-loads sig/ from the project root for constant resolution" do
      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p("sig")
        File.write("sig/cli_demo.rbs", <<~RBS)
          class CliRbsDemoFixture
            def name: () -> ::String
          end
        RBS
        File.write("source.rb", "CliRbsDemoFixture\n")

        status, out, err = run_cli("type-of", "source.rb:1:1")

        expect(err).to eq("")
        expect(status).to eq(0)
        expect(out).to include("type:    CliRbsDemoFixture")
      end
    end
  end

  describe "type-scan" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_fixture(name, contents)
      path = File.join(tmpdir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    it "reports a coverage summary in text format" do
      path = write_fixture("a.rb", "[1, 2]\nfoo()\n")

      status, out, err = run_cli("type-scan", path)

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("Type-of scan: 1 file")
      expect(out).to include("AST nodes visited:")
      expect(out).to match(%r{Prism::CallNode\s+\d+/\d+})
      expect(out).to include("Unrecognized examples")
    end

    it "emits JSON when --format=json is supplied" do
      path = write_fixture("a.rb", "foo()\n")

      status, out, _err = run_cli("type-scan", "--format=json", path)

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["summary"]).to include("visited", "unrecognized", "unrecognized_ratio")
      expect(payload["by_class"]).to include("Prism::CallNode")
      expect(payload["events"]).to be_an(Array)
      expect(payload["events"].first).to include("file" => path, "node_class" => "Prism::CallNode")
    end

    it "exits 1 when the unrecognized ratio exceeds --threshold" do
      path = write_fixture("a.rb", "foo()\n")

      status, _out, _err = run_cli("type-scan", "--threshold=0.1", path)

      expect(status).to eq(1)
    end

    it "exits 0 when the unrecognized ratio is at or below --threshold" do
      path = write_fixture("a.rb", "foo()\n")

      status, _out, _err = run_cli("type-scan", "--threshold=0.99", path)

      expect(status).to eq(0)
    end

    it "recurses into directories and aggregates files" do
      write_fixture("nested/one.rb", "1\n")
      write_fixture("nested/two.rb", "foo()\n")

      status, out, _err = run_cli("type-scan", File.join(tmpdir, "nested"))

      expect(status).to eq(0)
      expect(out).to include("Type-of scan: 2 files")
    end

    it "hides 0% classes by default and shows them with --show-recognized" do
      path = write_fixture("a.rb", "1\n")

      _status, out_default, _err = run_cli("type-scan", path)
      _status, out_full, _err = run_cli("type-scan", "--show-recognized", path)

      expect(out_default).not_to include("Prism::IntegerNode")
      expect(out_full).to include("Prism::IntegerNode")
    end

    it "reports parse errors and exits 1" do
      path = write_fixture("a.rb", "def\n")

      status, out, _err = run_cli("type-scan", path)

      expect(status).to eq(1)
      expect(out).to include("Parse errors:")
    end

    it "rejects missing paths with a usage error" do
      status, _out, err = run_cli("type-scan", "/no/such/path.rb")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("not a file or directory")
    end

    it "requires at least one path" do
      status, _out, err = run_cli("type-scan")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("at least one path is required")
    end

    it "lists type-scan in the help text" do
      _status, out, _err = run_cli("help")

      expect(out).to include("type-scan")
    end

    it "auto-loads sig/ from the project root when scanning" do
      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p("sig")
        File.write("sig/scan_demo.rbs", <<~RBS)
          class ScanRbsDemoFixture
          end
        RBS
        File.write("source.rb", "ScanRbsDemoFixture\n")

        status, out, _err = run_cli("type-scan", "source.rb")

        expect(status).to eq(0)
        # ScanRbsDemoFixture would be unrecognized without the project
        # signature loader; with sig/ in scope it resolves cleanly.
        expect(out).not_to match(%r{Prism::ConstantReadNode\s+\d+/\d+})
      end
    end
  end
end
