# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #1991 — a path that does not exist was read as empty, so `rigor sig-gen missing.rb` printed "No candidates" and
# exited 0. It now reports the path the way `rigor check` does: the same message, the same severity, the same exit.
RSpec.describe Rigor::CLI::SigGenCommand do
  around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

  before do
    File.write(".rigor.yml", "paths:\n  - lib\n")
    FileUtils.mkdir_p("lib")
    File.write("lib/greeter.rb", "class Greeter\n  def greet(name) = name\nend\n")
  end

  def run_sig_gen(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  it "says a missing path on stderr in the form rigor check uses, and exits 1" do
    status, _out, err = run_sig_gen("--", "missing.rb")

    expect(err).to include("missing.rb:1:1: error: no such file or directory")
    expect(status).to eq(1)
  end

  it "carries the missing path in the JSON payload, as a diagnostic check would give it" do
    status, out, err = run_sig_gen("--print", "--format=json", "--", "missing.rb")

    expect(JSON.parse(out).fetch("diagnostics")).to eq(
      [{ "path" => "missing.rb", "line" => 1, "column" => 1, "severity" => "error", "rule" => nil,
         "source_family" => "builtin", "message" => "no such file or directory" }]
    )
    expect(err).to be_empty
    expect(status).to eq(1)
  end

  it "warns, and still generates, when a missing path sits beside a readable one" do
    status, out, = run_sig_gen("--print", "--format=json", "--", "missing.rb", "lib")

    expect(JSON.parse(out).fetch("diagnostics")).to contain_exactly(
      include("path" => "missing.rb", "severity" => "warning", "message" => "no such file or directory (skipped)")
    )
    expect(status).to eq(0)
  end

  it "reports a missing path on stderr under --check, where the JSON carries no payload for it" do
    status, _out, err = run_sig_gen("--check", "--format=json", "--", "missing.rb")

    expect(err).to include("missing.rb:1:1: error: no such file or directory")
    expect(status).to eq(1)
  end

  # Positive control: an existing path reports nothing and exits 0.
  it "reports nothing for an existing path" do
    status, out, err = run_sig_gen("--print", "--format=json", "--", "lib/greeter.rb")

    expect(err).not_to include("no such file")
    expect(JSON.parse(out)).not_to have_key("diagnostics")
    expect(status).to eq(0)
  end
end
