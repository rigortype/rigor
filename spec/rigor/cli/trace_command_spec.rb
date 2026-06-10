# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/trace_command"

RSpec.describe Rigor::CLI::TraceCommand do
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI.start(argv, out: out, err: err)

    [status, out.string, err.string]
  end

  def with_demo_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "demo.rb")
      File.write(path, "a = 1\nb = a + (rand == 0 ? 1 : 2)\nc = b - a\n")
      yield path
    end
  end

  it "replays bind/union/dispatch frames sequentially on a non-TTY" do
    with_demo_file do |path|
      status, out, err = run_cli("trace", path)

      expect(status).to eq(0)
      expect(err).to eq("")
      expect(out).to include("bind     a ← 1")
      expect(out).to include("dispatch 1 #+(1 | 2)  →  2 | 3")
      expect(out).to include("union")
      expect(out).to include("┬─ scope ")
      expect(out).to include("· bind ")
    end
  end

  it "dumps the filtered event stream as JSON" do
    with_demo_file do |path|
      status, out, = run_cli("trace", "--format", "json", path)

      expect(status).to eq(0)
      events = JSON.parse(out)
      kinds = events.map { |e| e.fetch("kind") }.uniq
      expect(kinds).to contain_exactly("bind", "union", "dispatch")
      bind = events.find { |e| e["kind"] == "bind" }
      expect(bind["data"]).to eq("name" => "a", "type" => "1")
    end
  end

  it "includes enter/result frames under --verbose" do
    with_demo_file do |path|
      status, out, = run_cli("trace", "--format", "json", "--verbose", path)

      expect(status).to eq(0)
      kinds = JSON.parse(out).map { |e| e.fetch("kind") }.uniq
      expect(kinds).to include("enter", "result")
    end
  end

  it "filters frames to one line with --line" do
    with_demo_file do |path|
      status, out, = run_cli("trace", "--format", "json", "--line", "3", path)

      expect(status).to eq(0)
      lines = JSON.parse(out).map { |e| e.dig("location", "start_line") }.uniq
      expect(lines).to eq([3])
    end
  end

  it "fails with a message when the file does not exist" do
    status, _out, err = run_cli("trace", "no_such_file.rb")

    expect(status).to eq(1)
    expect(err).to include("trace: file not found")
  end

  it "prints usage without a FILE argument" do
    status, _out, err = run_cli("trace")

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("Usage: rigor trace")
  end
end
