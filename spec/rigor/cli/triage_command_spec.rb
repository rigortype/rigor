# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/triage_command"

# ADR-23 — end-to-end wiring of `rigor triage`: the command runs
# the real analysis pipeline, then renders the triage report.
RSpec.describe Rigor::CLI::TriageCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "code.rb"), %("hello".no_such_method\n))
      Dir.chdir(dir) { example.run }
    end
  end

  it "renders the text report and exits 0" do
    status, out, = run(["code.rb"])
    expect(status).to eq(0)
    expect(out).to include("Diagnostic distribution", "Hotspot files", "Hints")
  end

  it "emits a JSON report under --format json" do
    status, out, = run(["code.rb", "--format", "json"])
    expect(status).to eq(0)
    parsed = JSON.parse(out)
    expect(parsed.keys).to contain_exactly("summary", "distribution", "selectors", "hotspots", "hints")
    expect(parsed["summary"]["total"]).to be >= 1
  end

  it "exposes the class/method selector built from structured fields (no message parsing)" do
    _, out, = run(["code.rb", "--format", "json"])
    selector = JSON.parse(out)["selectors"].find { |s| s["method"] == "no_such_method" }
    expect(selector).to include("receiver" => "String", "method" => "no_such_method")
    expect(selector["rules"]).to include("call.undefined-method")
  end

  it "prints only the selectors section under --selectors-only" do
    _, out, = run(["code.rb", "--selectors-only"])
    expect(out).to include("Selectors — by class / method")
    expect(out).not_to include("Diagnostic distribution")
  end

  it "prints only the hints section under --hints-only" do
    _, out, = run(["code.rb", "--hints-only"])
    expect(out).to include("Hints")
    expect(out).not_to include("Diagnostic distribution")
  end

  it "rejects an unsupported --format" do
    expect { run(["code.rb", "--format", "xml"]) }.to raise_error(OptionParser::InvalidArgument)
  end
end
