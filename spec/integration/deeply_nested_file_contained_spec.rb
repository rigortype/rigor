# frozen_string_literal: true

# Issue #2455 — a file nested deeply enough to run the recursive walkers out of stack (Prism parses it) used to abort
# the whole run with `SystemStackError`, exit 70 and no report for any file. It is now that file's one
# `internal analyzer error` row, and every other file is reported as usual, sequentially and under `--workers`.
require "spec_helper"
require "json"
require "open3"
require "rbconfig"
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

  def crash_messages(*flags)
    out = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--no-cache", "--format", "json", *flags]
    Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: StringIO.new).run
    messages = JSON.parse(out.string).fetch("diagnostics").map { |d| d.fetch("message") }
    messages.select { |m| m.start_with?("internal analyzer error") }.sort
  end

  it "says the file is nested too deeply, with no overflow frame, the same in every mode" do
    write_project(1400)
    sequential = crash_messages
    expect(sequential.size).to eq(3)
    expect(sequential).to all(include("nested too deeply to analyse").and(satisfy { |m| !m.include?("(lib/") }))
    expect(crash_messages("--workers=2")).to eq(sequential)
  end

  it "uses the defect wording for an overflow in a file that is not deeply nested" do
    message = Rigor::Analysis::CrashSignature.check_rule_message(SystemStackError.new("stack level too deep"))
    expect(message).to include("defect in Rigor").and(satisfy { |m| !m.include?("nested too deeply") })
  end

  # A file that overflows contributes nothing to discovery, whichever way the run discovers, so a sibling's findings do
  # not depend on the mode (#2455). The deep file declares `A` before the overflow.
  it "gives a sibling the same findings in a full run, cold and warm --incremental, and --verify-incremental" do
    File.write(".rigor.yml", "paths:\n  - .\n")
    File.write("deep_decl.rb", "class A\n  def a_method = 1\nend\nx = #{'[' * 1400}1#{']' * 1400}\n")
    File.write("b_user.rb", "A.new.a_method\nA.new.nope_zz\n")
    full = check
    expect(check("--incremental")).to eq(full)
    expect(check("--incremental")).to eq(full)
    out = StringIO.new
    argv = ["check", "--verify-incremental", "--no-stats", "--no-ci-detect", "--no-baseline", "."]
    status = Rigor::CLI.new(argv, out: out, err: StringIO.new).run
    expect(status).to eq(0)
    expect(out.string).to include("--verify-incremental OK")
  end

  it "folds a file that overflows into no discovery table, in the full and the incremental pass alike" do
    File.write("deep_decl.rb", "class A\n  def a_method = 1\nend\nx = #{'[' * 1400}1#{']' * 1400}\n")
    File.write("ordinary.rb", "class Fine\n  def ok = 1\nend\n")
    paths = %w[deep_decl.rb ordinary.rb]
    full = Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths(paths)
    incremental = Rigor::Inference::ScopeIndexer.discovered_project_index_incremental(paths, seed_bundles: {})
    [full, incremental].each do |index|
      expect(index.fetch(:classes).keys).to eq(["Fine"])
      expect(index.fetch(:def_index).fetch(:def_nodes).keys).to eq(["Fine"])
    end
  end

  it "contains a depth-3000 file in the discovery loops and in --incremental" do
    File.write(".rigor.yml", "paths:\n  - .\n")
    File.write("ordinary.rb", "class Fine\n  def ok = 1\nend\n")
    File.write("deep.rb", "x = #{'[' * 3000}1#{']' * 3000}\n")
    paths = %w[ordinary.rb deep.rb]
    expect(Rigor::Inference::ScopeIndexer.discovered_classes_for_paths(paths).keys).to eq(["Fine"])
    expect(Rigor::Inference::ScopeIndexer.discovered_def_index_for_paths(paths).fetch(:def_nodes).keys).to eq(["Fine"])
    expect(check("--incremental").first).to eq(1)
  end

  # Prism's own parse of a source nested near its cap overflows in C: no backtrace, and no stack to recover on. That
  # keeps the run-level abort (exit 70), since a second C overflow in the same process kills it with a signal.
  it "keeps the exit-70 abort for an overflow raised from C" do
    # The `.rigor.yml` makes discovery parse (and rescue) the file first; without it an earlier unrescued parse aborts
    # and the examples passes with every re-raise stripped.
    File.write(".rigor.yml", "paths:\n  - .\n")
    File.write("deep.rb", "x = #{'[' * 10_000}1#{']' * 10_000}\n")
    # Whether this depth overflows inside Prism (C, no backtrace) depends on the platform's machine stack, so ask a
    # subprocess launched the same way and skip where it does not.
    probe = 'require "prism"; begin; Prism.parse(File.read("deep.rb")); exit 3; ' \
            "rescue SystemStackError => e; exit(e.backtrace.nil? ? 0 : 2); end"
    _, _, probed = Open3.capture3(RbConfig.ruby, "-e", probe, stdin_data: "")
    skip "Prism.parse at depth 10000 does not overflow in C here (probe exit #{probed.exitstatus})" unless
      probed.exitstatus.zero?

    _, err, status = Open3.capture3(RbConfig.ruby, File.expand_path("../../exe/rigor", __dir__), "check", "--no-cache",
                                    "--no-ci-detect", "deep.rb", stdin_data: "")
    expect(status.exitstatus).to eq(70)
    expect(err).to include("could not finish this run")
  end

  it "analyses a file just below the threshold normally (control)" do
    write_project(300)
    _, rows = check
    expect(rows.map(&:last)).not_to include(:crash)
    expect(rows).to include(["ordinary.rb", "call.undefined-method"])
  end
end
