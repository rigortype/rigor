# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/check_command"

# Focused unit coverage for the extracted `rigor check` command object.
# The full behavioural surface (CI formats, baselines, incremental modes,
# editor mode, cache stats) is exercised end-to-end through the dispatcher
# in `spec/rigor/cli_spec.rb`; this spec is the safety net for the move
# itself — that `CheckCommand` parses options, runs the analysis, and
# returns the right exit code when driven directly as a command object.
RSpec.describe Rigor::CLI::CheckCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  it "is a Command subclass so it inherits the argv/out/err contract" do
    expect(described_class.superclass).to eq(Rigor::CLI::Command)
  end

  it "exits 0 and reports no diagnostics for a clean file" do
    File.write("clean.rb", "x = 1\n")

    status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "clean.rb"])

    expect(status).to eq(0)
    expect(out).to include("No diagnostics")
  end

  it "exits 1 and reports the error count for a file with a diagnostic" do
    File.write("bad.rb", "x = \"hello\"\nx.no_such_method_here\n")

    status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "bad.rb"])

    expect(status).to eq(1)
    expect(out).to include("error(s) in")
  end

  it "renders a JSON document under --format=json" do
    File.write("bad.rb", "x = \"hello\"\nx.no_such_method_here\n")

    status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "bad.rb"])

    expect(status).to eq(1)
    payload = JSON.parse(out)
    expect(payload.fetch("diagnostics").map { |d| d["rule"] }).to include("call.undefined-method")
  end

  it "seeds parallel-assignment ivar writes so a cross-method read is not always-falsey (N1)" do
    # `old, @cb = @cb, block` records the `@cb` target into the
    # class-ivar union; before N1 the collector dropped it and `@cb`
    # seeded pure `Constant[nil]`, folding `if @cb` always-falsey.
    File.write("channel.rb", <<~RUBY)
      class Channel
        def initialize
          @cb = nil
        end

        def on_data(&block)
          old, @cb = @cb, block
          old
        end

        def fire
          @cb.call if @cb
        end
      end
    RUBY

    status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "channel.rb"])

    payload = JSON.parse(out)
    messages = payload.fetch("diagnostics").map { |d| d["message"] }
    expect(messages).not_to include(a_string_including("always falsey"))
    expect(status).to eq(0)
  end

  it "raises an InvalidArgument for an unsupported --format" do
    File.write("clean.rb", "x = 1\n")

    expect do
      run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=xml", "clean.rb"])
    end.to raise_error(OptionParser::InvalidArgument, /unsupported format: xml/)
  end

  it "rejects --tmp-file without --instead-of with a usage exit" do
    status, _out, err = run(["--tmp-file=/nonexistent", "lib"])

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("--tmp-file and --instead-of must appear together")
  end

  describe "#parse_check_options" do
    subject(:command) { described_class.new(argv: argv, out: StringIO.new, err: StringIO.new) }

    let(:argv) { [] }

    it "defaults to the text format with stats and CI detection on" do
      options = command.send(:parse_check_options)

      expect(options).to include(
        format: "text", stats: true, ci_detect: true, no_cache: false,
        baseline: :unset, baseline_strict: false, incremental: false
      )
    end

    it "parses the flag surface and leaves positional paths in argv" do
      command = described_class.new(
        argv: ["--no-cache", "--format=json", "--no-stats", "--no-ci-detect", "lib", "spec"],
        out: StringIO.new, err: StringIO.new
      )

      options = command.send(:parse_check_options)

      expect(options).to include(format: "json", stats: false, ci_detect: false, no_cache: true)
      expect(command.instance_variable_get(:@argv)).to eq(%w[lib spec])
    end
  end

  describe "#resolve_workers (ADR-15 Phase 4c precedence)" do
    subject(:command) { described_class.new(argv: [], out: StringIO.new, err: StringIO.new) }

    let(:configuration) { instance_double(Rigor::Configuration, parallel_workers: 0) }

    it "prefers an explicit --workers value, clamping negatives to 0" do
      expect(command.send(:resolve_workers, { workers: "-1" }, configuration)).to eq(0)
      expect(command.send(:resolve_workers, { workers: "4" }, configuration)).to eq(4)
    end

    it "falls back to the configuration default when no CLI / env override is set" do
      allow(configuration).to receive(:parallel_workers).and_return(5)
      saved = ENV.fetch("RIGOR_RACTOR_WORKERS", :absent)
      ENV.delete("RIGOR_RACTOR_WORKERS")

      expect(command.send(:resolve_workers, { workers: nil }, configuration)).to eq(5)
    ensure
      saved == :absent ? ENV.delete("RIGOR_RACTOR_WORKERS") : (ENV["RIGOR_RACTOR_WORKERS"] = saved)
    end
  end
end
