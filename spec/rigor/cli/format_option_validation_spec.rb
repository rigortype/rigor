# frozen_string_literal: true

require "stringio"
require "tmpdir"

require "rigor/cli"

# #2502 — an unsupported `--format` is a usage error caught while the options are parsed, before any analysis.
# `check`, `coverage`, `type-of` and `type-scan` used to run the whole analysis and only then reject the value in their
# renderer ("unsupported format: …"); `trace` and `unused` never rejected it and printed text. The OptionParser message
# (`invalid argument: --format=…`) and an empty stdout are what prove the rejection happened before the run.
RSpec.describe "--format validation at parse time" do
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI.start(argv, out: out, err: err)

    [status, out.string, err.string]
  end

  def with_demo_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "demo.rb")
      File.write(path, "class Demo\n  def call = 1 + 1\nend\n")
      Dir.chdir(dir) { yield path }
    end
  end

  {
    "check" => ->(path) { ["check", "--no-cache", "--no-stats", "--no-ci-detect", path] },
    "coverage" => ->(path) { ["coverage", path] },
    "type-of" => ->(path) { ["type-of", "#{path}:2"] },
    "type-scan" => ->(path) { ["type-scan", path] },
    "trace" => ->(path) { ["trace", path] },
    "unused" => ->(path) { ["unused", path] }
  }.each do |command, argv_for|
    it "rejects an unsupported --format for `rigor #{command}` before analysing" do
      with_demo_file do |path|
        status, out, err = run_cli(*argv_for.call(path).insert(1, "--format=bogus"))

        expect(status).to eq(Rigor::CLI::EXIT_USAGE)
        expect(out).to eq("")
        expect(err).to include("invalid argument: --format=bogus")
      end
    end
  end

  it "still accepts every CI format `rigor check` documents" do
    with_demo_file do |path|
      Rigor::CLI::DiagnosticFormats::FORMATS.each do |format|
        status, = run_cli("check", "--no-cache", "--no-stats", "--no-ci-detect", "--format=#{format}", path)

        expect(status).not_to eq(Rigor::CLI::EXIT_USAGE), "--format=#{format} was rejected"
      end
    end
  end
end
