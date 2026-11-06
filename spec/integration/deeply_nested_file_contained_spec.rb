# frozen_string_literal: true

# Issue #2455 — a file nested deeply enough to run the recursive walkers out of stack (Prism parses it) used to abort
# the whole run with `SystemStackError`, exit 70 and no report for any file. It is now that file's one
# `internal analyzer error` row, and every other file is reported as usual, sequentially and under `--workers`.
require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

RSpec.describe "a file nested too deeply to analyse is contained to that file (#2455)", type: :runner do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def write_project(depth)
    File.write(".rigor.yml", "paths:\n  - .\n")
    File.write("ordinary.rb", "x = 1\nx.no_such_method_zz\n")
    File.write("deep_array.rb", "x = #{'[' * depth}1#{']' * depth}\n")
    File.write("deep_if.rb", "#{"if a\n" * depth}1\n#{"end\n" * depth}")
    File.write("deep_chain.rb", "x = 1#{'.succ' * depth}\n")
  end

  def check(*flags)
    out = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--no-cache", "--format", "json", *flags]
    status = Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: StringIO.new).run
    rows = JSON.parse(out.string).fetch("diagnostics").map do |d|
      [File.basename(d.fetch("path")), d.fetch("message").start_with?("internal analyzer error") ? :crash : d["rule"]]
    end
    [status, rows.sort_by(&:to_s)]
  end

  let(:contained) do
    [["deep_array.rb", :crash], ["deep_chain.rb", :crash], ["deep_if.rb", :crash],
     ["ordinary.rb", "call.undefined-method"]]
  end

  it "reports one row for each deep file and the ordinary file's finding, with exit 1 not 70" do
    write_project(1400)
    status, rows = check
    expect(rows).to eq(contained)
    expect(status).to eq(1)
  end

  it "does the same under --workers=2" do
    write_project(1400)
    status, rows = check("--workers=2")
    expect(rows).to eq(contained)
    expect(status).to eq(1)
  end

  it "says the file is nested too deeply" do
    write_project(1400)
    out = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--no-cache", "--format", "json", "deep_array.rb"]
    Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: StringIO.new).run
    message = JSON.parse(out.string).fetch("diagnostics").fetch(0).fetch("message")
    expect(message).to include("nested too deeply to analyse")
  end

  it "analyses a file just below the threshold normally (control)" do
    write_project(300)
    _, rows = check
    expect(rows.map(&:last)).not_to include(:crash)
    expect(rows).to include(["ordinary.rb", "call.undefined-method"])
  end
end
