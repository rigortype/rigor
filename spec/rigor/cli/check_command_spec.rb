# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/check_command"
require "rigor/analysis/plugin_fact_fingerprint"

# Focused unit coverage for the extracted `rigor check` command object. The full behavioural surface (CI formats,
# baselines, incremental modes, editor mode, cache stats) is exercised end-to-end through the dispatcher in
# `spec/rigor/cli_spec.rb`; this spec is the safety net for the move itself — that `CheckCommand` parses options, runs
# the analysis, and returns the right exit code when driven directly as a command object.
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

  # ADR-39 slice 5 / #911 — `plugins_isolation:` reaches the invocation layer through a real `rigor
  # check`. The discriminator is the backend a plugin's call would actually take, observed the way a
  # plugin observes it: `Isolation.call` on `Process.pid` answers with THIS process's pid under `none`
  # and with the forked worker's under `process`, so the two arms cannot pass each other's assertion.
  describe "plugins_isolation:" do
    around do |example|
      original_env = ENV.fetch("RIGOR_PLUGIN_ISOLATION", nil)
      original_configured = Rigor::Plugin::Isolation.configured_strategy
      ENV.delete("RIGOR_PLUGIN_ISOLATION")
      Rigor::Plugin::Isolation::Process.instance_variable_set(:@worker, nil)
      example.run
    ensure
      original_env.nil? ? ENV.delete("RIGOR_PLUGIN_ISOLATION") : (ENV["RIGOR_PLUGIN_ISOLATION"] = original_env)
      Rigor::Plugin::Isolation.configured_strategy = original_configured
      Rigor::Plugin::Isolation::Process.instance_variable_set(:@worker, nil)
    end

    def invoked_pid
      Rigor::Plugin::Isolation.call(feature: "English", receiver: "Process", method: :pid, args: [])
    end

    it "takes the in-process path for `none`" do
      File.write(".rigor.yml", "paths:\n  - clean.rb\nplugins_isolation: none\n")
      File.write("clean.rb", "x = 1\n")

      status, = run(["--no-cache", "--no-ci-detect", "--no-stats", "clean.rb"])

      expect(status).to eq(0)
      expect(Rigor::Plugin::Isolation.strategy_name).to eq("none")
      expect(Rigor::Plugin::Isolation.backend).to eq(Rigor::Plugin::Isolation::Direct)
      expect(invoked_pid).to eq(Process.pid)
    end

    it "takes the forked-worker path for `process`", if: Process.respond_to?(:fork) do
      File.write(".rigor.yml", "paths:\n  - clean.rb\nplugins_isolation: process\n")
      File.write("clean.rb", "x = 1\n")

      status, = run(["--no-cache", "--no-ci-detect", "--no-stats", "clean.rb"])

      expect(status).to eq(0)
      expect(Rigor::Plugin::Isolation.strategy_name).to eq("process")
      expect(Rigor::Plugin::Isolation.backend).to eq(Rigor::Plugin::Isolation::Process)
      expect(invoked_pid).not_to eq(Process.pid)
    end

    it "rejects the environment-only `ruby_box` with a message naming the variable" do
      File.write(".rigor.yml", "paths:\n  - clean.rb\nplugins_isolation: ruby_box\n")
      File.write("clean.rb", "x = 1\n")

      expect { run(["--no-cache", "--no-ci-detect", "--no-stats", "clean.rb"]) }
        .to raise_error(Rigor::ConfigurationError, /RIGOR_PLUGIN_ISOLATION=ruby_box/)

      # ...and the dispatcher, which owns the `ConfigurationError` rescue, renders it as the one-line
      # `rigor:` message a user actually sees rather than a backtrace (#433).
      require "rigor/cli"
      err = StringIO.new
      status = Rigor::CLI.new(
        ["check", "--no-cache", "--no-ci-detect", "--no-stats", "clean.rb"], out: StringIO.new, err: err
      ).run

      expect(status).not_to eq(0)
      expect(err.string).to include("RIGOR_PLUGIN_ISOLATION=ruby_box")
    end
  end

  # ADR-67 WD6c lift — `parameter_inference:` composes with `--incremental`: the session diffs the
  # freshly collected param table against the snapshot's copy and re-checks any callee whose seeds moved,
  # so the earlier mutual-exclusion refusal (exit 64) is gone. The cross-run soundness property itself is
  # asserted in `incremental_session_spec.rb`; this is the CLI wiring.
  it "composes parameter_inference: with --incremental (WD6c lifted)" do
    File.write(".rigor.yml", "paths:\n  - clean.rb\nparameter_inference: true\n")
    File.write("clean.rb", "x = 1\n")

    cold_status, cold_out, cold_err = run(["--no-ci-detect", "--no-stats", "--incremental", "clean.rb"])
    warm_status, warm_out, warm_err = run(["--no-ci-detect", "--no-stats", "--incremental", "clean.rb"])

    expect(cold_status).to eq(0)
    expect(warm_status).to eq(0)
    expect(cold_err).to include("--incremental cold")
    expect(warm_err).to include("--incremental warm")
    expect(cold_out).to include("No diagnostics")
    expect(warm_out).to include("No diagnostics")
  end

  # #1526 — the warm banner reports the recheck's own sets, not the size of the whole analysed set. The session
  # path is pinned with the run-result slot stubbed to decline, so the recheck is what prints the banner; the slot
  # path has its own example below. `lib/b.rb` calls `Widget#price`, so an edit to `lib/a.rb` that changes its
  # return type re-analyzes the dependent too: the banner shows 2 re-analysed for 1 changed.
  describe "--incremental banner reports the recheck" do
    before { require "rigor/analysis/incremental_run_slot" }

    def write_banner_project
      FileUtils.mkdir_p("lib")
      File.write(File.join("lib", "a.rb"), "class Widget\n  def price\n    10\n  end\nend\n")
      File.write(File.join("lib", "b.rb"), "class Shop\n  def total\n    Widget.new.price\n  end\nend\n")
      File.write(File.join("lib", "c.rb"), "class Other\n  def go = 1\nend\n")
    end

    def banner_run(*extra)
      run(["--no-ci-detect", "--no-stats", "--no-baseline", "--incremental", *extra, "lib"])
    end

    def decline_slot
      allow(Rigor::Analysis::IncrementalRunSlot).to receive(:serve).and_return(nil)
    end

    it "prints the unchanged cold banner on a first run" do
      write_banner_project

      status, _out, err = banner_run

      expect(status).to eq(0)
      expect(err).to include("rigor: --incremental cold — full analysis (3 files)")
      expect(err).not_to include("reused cached diagnostics")
    end

    it "says it re-analysed 0 files on a no-change warm run, from the session" do
      write_banner_project
      banner_run
      decline_slot

      _status, _out, err = banner_run

      expect(err).to include("rigor: --incremental warm — re-analysed 0 of 3 files, reused all")
    end

    it "says it re-analysed 0 files on a no-change warm run served from the slot" do
      write_banner_project
      banner_run

      _status, _out, err = banner_run

      expect(err).to include("rigor: --incremental warm — re-analysed 0 of 3 files, reused all")
    end

    it "counts the dependent as re-analysed when one edit reaches a file that uses it" do
      write_banner_project
      banner_run
      File.write(File.join("lib", "a.rb"), "class Widget\n  def price\n    :ten\n  end\nend\n")
      decline_slot

      _status, _out, err = banner_run

      expect(err).to include(
        "rigor: --incremental warm — re-analysed 2 of 3 files (1 changed), reused the rest"
      )
    end

    it "names a removed file, and says nothing was re-analysed when the rest is unchanged" do
      write_banner_project
      banner_run
      FileUtils.rm_f(File.join("lib", "c.rb"))
      decline_slot

      _status, _out, err = banner_run

      expect(err).to include("rigor: --incremental warm — re-analysed 0 of 2 files (1 removed), reused all")
      expect(err).not_to include("0 changed")
    end

    it "uses singular nouns for a one-file project" do
      FileUtils.mkdir_p("lib")
      File.write(File.join("lib", "a.rb"), "class Solo\n  def go = 1\nend\n")
      banner_run
      decline_slot

      _status, _out, err = banner_run

      expect(err).to include("rigor: --incremental warm — re-analysed 0 of 1 file, reused all")
    end

    # A view template is a plugin-declared unit outside the `.rb` analysed set. The recheck re-runs every template on
    # every warm run, so the banner appends them as their own count and leaves the file counts alone.
    describe "with a plugin view template" do
      before do
        $LOAD_PATH.unshift(File.expand_path("../../fixtures/template_units", __dir__))
        require "view_demo_plugin"
        Rigor::Plugin.register(RigorViewDemoPlugin)
      end

      after { Rigor::Plugin.unregister! }

      def write_template_project
        write_banner_project
        FileUtils.mkdir_p(File.join("app", "views", "users"))
        File.write(File.join("app", "views", "users", "show.rbx"), "1\n")
        File.write(".rigor.yml", "paths:\n  - lib\nplugins:\n  - gem: view_demo_plugin\n    id: view-demo\n")
      end

      it "appends the re-run templates to a warm banner for a template edit, and for a Ruby edit" do
        write_template_project
        banner_run
        decline_slot

        File.write(File.join("app", "views", "users", "show.rbx"), "2\n")
        _status, _out, template_err = banner_run
        expect(template_err).to include(
          "rigor: --incremental warm — re-analysed 0 of 3 files, reused all, plus 1 view template"
        )

        File.write(File.join("lib", "a.rb"), "class Widget\n  def price\n    :ten\n  end\nend\n")
        _status, _out, ruby_err = banner_run
        expect(ruby_err).to include(
          "rigor: --incremental warm — re-analysed 2 of 3 files (1 changed), reused the rest, plus 1 view template"
        )
      end
    end

    it "names an added file in the parenthesis, and leaves zero counts out" do
      write_banner_project
      banner_run
      File.write(File.join("lib", "d.rb"), "class Fresh\n  def go = 2\nend\n")
      decline_slot

      _status, _out, err = banner_run

      expect(err).to include("rigor: --incremental warm — re-analysed 1 of 4 files (1 added), reused the rest")
      expect(err).not_to include("0 changed")
      expect(err).not_to include("removed")
    end
  end

  # #1529 — `--no-stats` must build no RunStats: the summary is never printed, and on macOS the RSS probe forks
  # `ps`. The ordinary path already threads `collect_stats: false` through CheckRunnerFactory, and the first
  # examples pin that. The `--incremental` examples pin the lazy read: the session's internal runners still
  # collect (their chain snapshots, see IncrementalSession#start_chain), but nothing prints their summary, so
  # the RSS reader is never called. The `--coverage` example pins the read's position: it runs before the scan.
  describe "--no-stats" do
    before { require "rigor/analysis/run_stats" }

    it "builds no RunStats on an ordinary run and prints no summary" do
      File.write("clean.rb", "x = 1\n")
      allow(Rigor::Analysis::RunStats).to receive(:peak_rss_bytes).and_call_original

      status, _out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "clean.rb"])

      expect(status).to eq(0)
      expect(Rigor::Analysis::RunStats).not_to have_received(:peak_rss_bytes)
      expect(err).not_to include("RBS classes available")
    end

    it "still builds RunStats and prints the summary by default" do
      File.write("clean.rb", "x = 1\n")
      allow(Rigor::Analysis::RunStats).to receive(:peak_rss_bytes).and_call_original

      _status, _out, err = run(["--no-cache", "--no-ci-detect", "clean.rb"])

      expect(Rigor::Analysis::RunStats).to have_received(:peak_rss_bytes).at_least(:once)
      expect(err).to include("RBS classes available")
      expect(err).to include("Memory peak:")
    end

    # Issue #1529 — the peak is read straight after the analysis, so a `--coverage` scan (a second pass over the
    # same files) cannot inflate the figure the summary reports.
    it "reads the peak RSS before the --coverage scan runs" do
      File.write("clean.rb", "x = 1\n")
      require "rigor/cli/coverage_scan"
      events = []
      allow(Rigor::Analysis::RunStats).to receive(:peak_rss_bytes).and_wrap_original do |original|
        events << :rss
        original.call
      end
      allow(Rigor::CLI::CoverageScan).to receive(:precision_report).and_wrap_original do |original, **kwargs|
        events << :coverage
        original.call(**kwargs)
      end

      run(["--no-cache", "--no-ci-detect", "--coverage", "clean.rb"])

      expect(events).to include(:rss, :coverage)
      expect(events.index(:rss)).to be < events.index(:coverage)
    end

    # Issue #1529 — the RSS reader is lazy, so a run that prints no summary never reads it. The incremental
    # session's internal runners build a RunStats they never print, and the chain snapshots they need are
    # collected regardless of the flag, so the reader must stay uncalled on cold and warm runs alike.
    it "never reads the RSS on an --incremental run, cold or warm, with or without --no-stats" do
      File.write("clean.rb", "x = 1\n")
      File.write("clean_quiet.rb", "x = 1\n")
      %i[peak_rss_bytes read_rss_via_ps read_vmhwm_from_proc].each do |reader|
        allow(Rigor::Analysis::RunStats).to receive(reader).and_call_original
      end

      # Each variant gets its own root, so its snapshot starts cold and its second run is the warm one.
      variants = [["--no-ci-detect", "--incremental", "clean.rb"],
                  ["--no-ci-detect", "--no-stats", "--incremental", "clean_quiet.rb"]]
      variants.each do |variant|
        cold_status, _out, cold_err = run(variant.dup)
        warm_status, _out, warm_err = run(variant.dup)

        expect(cold_status).to eq(0)
        expect(warm_status).to eq(0)
        expect(cold_err).to include("--incremental cold")
        expect(warm_err).to include("--incremental warm")
      end

      expect(Rigor::Analysis::RunStats).not_to have_received(:peak_rss_bytes)
      expect(Rigor::Analysis::RunStats).not_to have_received(:read_rss_via_ps)
      expect(Rigor::Analysis::RunStats).not_to have_received(:read_vmhwm_from_proc)
    end

    it "does not crash on any output format and emits no stats key in --format json" do
      File.write("bad.rb", "x = \"hello\"\nx.no_such_method_here\n")

      %w[text json sarif github gitlab checkstyle junit teamcity].each do |format|
        status, out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=#{format}", "bad.rb"])

        expect(status).to eq(1), "format=#{format} exited #{status}; stderr: #{err}"
        expect(err).not_to include("RBS classes available")
        expect(JSON.parse(out)).not_to have_key("stats") if format == "json"
      end
    end

    it "serves a repeat ordinary run from the run cache without a crash" do
      File.write("clean.rb", "x = 1\n")

      first_status, = run(["--no-ci-detect", "--no-stats", "--format=json", "clean.rb"])
      second_status, second_out, = run(["--no-ci-detect", "--no-stats", "--format=json", "clean.rb"])

      expect(first_status).to eq(0)
      expect(second_status).to eq(0)
      expect(JSON.parse(second_out)).to include("success" => true)
    end
  end

  # #146 — editor mode option B. `--incremental` plus a buffer used to ignore the buffer entirely and analyse
  # the file on disk: a wrong answer, not a missing feature. It now analyses the whole project with the buffer
  # substituted, and declines to single-file scope when there is no snapshot to reuse.
  describe "editor mode with --incremental (option B)" do
    def write_editor_project
      FileUtils.mkdir_p("lib")
      File.write(File.join("lib", "widget.rb"), "class Widget\n  def name\n    \"w\"\n  end\nend\n")
      File.write(File.join("lib", "other.rb"), "class Other\n  def go\n    Widget.new.name.upcase\n  end\nend\n")
      File.write("buffer_widget.rb", "class Widget\n  def name\n    1\n  end\nend\n")
    end

    def editor_argv
      ["--no-ci-detect", "--no-stats", "--incremental",
       "--tmp-file=buffer_widget.rb", "--instead-of=lib/widget.rb", "lib"]
    end

    it "falls back to single-file scope, with a note, when no snapshot exists yet" do
      write_editor_project

      status, out, err = run(editor_argv)

      expect(err).to include("no reusable snapshot")
      expect(err).to include("rigor check --incremental")
      # Option A's answer: the buffer alone, so the dependent's diagnostic is absent.
      expect(out).not_to include("lib/other.rb")
      expect(status).to eq(0)
    end

    it "reports the unsaved buffer's effect on a dependent once a snapshot exists" do
      write_editor_project
      run(["--no-ci-detect", "--no-stats", "--incremental", "lib"]) # warm the snapshot from disk

      status, out, err = run(editor_argv)

      expect(err).to include("--incremental editor mode")
      expect(out).to include("lib/other.rb")
      expect(out).to include("undefined method `upcase'")
      expect(status).to eq(1)
    end

    it "leaves the snapshot untouched, so the next on-disk run is unaffected" do
      write_editor_project
      run(["--no-ci-detect", "--no-stats", "--incremental", "lib"])
      snapshot = File.join(".rigor", "cache", "incremental", "snapshot.bin")
      before = File.binread(snapshot)

      run(editor_argv)

      expect(File.binread(snapshot)).to eq(before)
      status, out, = run(["--no-ci-detect", "--no-stats", "--incremental", "lib"])
      expect(out).to include("No diagnostics")
      expect(status).to eq(0)
    end

    it "says --no-cache skipped the snapshot, not that no snapshot exists, when a primed snapshot is ignored" do
      write_editor_project
      run(["--no-ci-detect", "--no-stats", "--incremental", "lib"]) # a snapshot exists on disk

      status, _out, err = run(editor_argv + ["--no-cache"])

      expect(err).to include("--no-cache skips the incremental snapshot")
      expect(err).not_to include("no reusable snapshot")
      expect(err).not_to include("rigor check --incremental")
      expect(status).to eq(0)
    end

    it "refuses --verify-incremental against a buffer instead of comparing against the wrong oracle" do
      write_editor_project

      status, _out, err = run(["--no-ci-detect", "--no-stats", "--verify-incremental",
                               "--tmp-file=buffer_widget.rb", "--instead-of=lib/widget.rb", "lib"])

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("--verify-incremental cannot run against an editor buffer")
    end
  end

  # ADR-45 WD2 (#1507) — a null `--incremental` run served from the session's run-result slot prints exactly what
  # the full path prints for the same warm run: the banner, the baseline filter, the output format and the exit
  # code. The full path's answer is taken with the probe stubbed to decline, which leaves the slot in place; the
  # served answer is asserted to come from no session at all.
  describe "--incremental served from the run-result slot" do
    before { require "rigor/analysis/incremental_run_slot" }

    def write_slot_project
      FileUtils.mkdir_p("lib")
      File.write(File.join("lib", "a.rb"), "class Widget\n  def price\n    10\n  end\nend\n")
      File.write(File.join("lib", "b.rb"), "class Shop\n  def total\n    Widget.new.price.upcase\n  end\nend\n")
      File.write(File.join("lib", "c.rb"), "class Other\n  def go\n    :sym.upcase\n    1.nope\n  end\nend\n")
    end

    [
      [], ["--format=json"], ["--format=sarif"], ["--format=github"], ["--fail-on=info"],
      ["--baseline=baseline.yml"], ["--no-baseline"]
    ].each do |extra|
      it "prints what the full path prints#{" (#{extra.join(' ')})" unless extra.empty?}" do
        write_slot_project
        argv = ["--no-ci-detect", "--no-stats", "--incremental", *extra, "lib"]
        if extra.include?("--baseline=baseline.yml")
          Rigor::CLI.new(["baseline", "generate", "--output=baseline.yml", "lib"], out: StringIO.new,
                                                                                   err: StringIO.new).run
          File.write(File.join("lib", "d.rb"), "class Fresh\n  def go\n    2.nope\n  end\nend\n")
        end
        run(argv.dup) # the option parser consumes its argv

        allow(Rigor::Analysis::IncrementalRunSlot).to receive(:serve).and_return(nil)
        full = run(argv.dup)
        allow(Rigor::Analysis::IncrementalRunSlot).to receive(:serve).and_call_original
        allow(Rigor::Analysis::IncrementalSession).to receive(:new).and_call_original
        served = run(argv.dup)

        expect(Rigor::Analysis::IncrementalSession).not_to have_received(:new)
        expect(served).to eq(full)
        expect(served[2]).to include("--incremental warm")
        expect(served[2]).to include("silenced by baseline") if extra.include?("--baseline=baseline.yml")
      end
    end

    # `extra` is missing, so both runs analyse the same files; only the first reports the missing root, which
    # under `--fail-on=warning` is also the difference between exit 1 and exit 0.
    it "answers `lib` and `lib extra` each from its own slot, in either order" do
      write_slot_project
      File.write(File.join("lib", "b.rb"), "class Shop\n  def total\n    Widget.new.price\n  end\nend\n")
      File.write(File.join("lib", "c.rb"), "class Other\nend\n")
      argv = ->(*roots) { ["--no-ci-detect", "--no-stats", "--incremental", "--fail-on=warning", *roots] }

      2.times do
        with_extra = run(argv.call("lib", "extra"))
        without = run(argv.call("lib"))
        expect(with_extra[0]).to eq(1)
        expect(with_extra[1]).to include("extra")
        expect(without[0]).to eq(0)
        expect(without[1]).not_to include("extra")
      end
    end
  end

  it "allows parameter_inference: on a full (non-incremental) check" do
    File.write(".rigor.yml", "paths:\n  - clean.rb\nparameter_inference: true\n")
    File.write("clean.rb", "x = 1\n")

    status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "clean.rb"])

    expect(status).to eq(0)
    expect(out).to include("No diagnostics")
  end

  it "renders a JSON document under --format=json" do
    File.write("bad.rb", "x = \"hello\"\nx.no_such_method_here\n")

    status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "bad.rb"])

    expect(status).to eq(1)
    payload = JSON.parse(out)
    expect(payload.fetch("diagnostics").map { |d| d["rule"] }).to include("call.undefined-method")
  end

  it "enriches each built-in diagnostic with evidence_tier and documentation_url (--format=json)" do
    File.write("bad.rb", "x = \"hello\"\nx.no_such_method_here\n")

    _status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "bad.rb"])

    diag = JSON.parse(out).fetch("diagnostics").find { |d| d["rule"] == "call.undefined-method" }
    expect(diag.fetch("evidence_tier")).to eq("high")
    expect(diag.fetch("documentation_url")).to end_with("04-diagnostics/#rule-call-undefined-method")
  end

  it "adds a coverage block under --coverage --format=json" do
    File.write("sample.rb", "x = 1\ny = x + 2\n")

    _status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--coverage", "--format=json", "sample.rb"])

    coverage = JSON.parse(out).fetch("coverage")
    expect(coverage).to include("scan_files" => 1)
    expect(coverage.fetch("expressions_typed")).to be > 0
    expect(coverage).to have_key("precise_ratio")
  end

  it "omits the coverage block when --coverage is not passed" do
    File.write("sample.rb", "x = 1\n")

    _status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "sample.rb"])

    expect(JSON.parse(out)).not_to have_key("coverage")
  end

  it "warns on STDERR when a configured signature_paths entry resolves to nothing" do
    File.write("a.rb", "x = 1\n")
    File.write(".rigor.yml", "signature_paths:\n  - ./no_such_sig\n")

    _status, _out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--config", ".rigor.yml", "a.rb"])

    expect(err).to include("signature_paths:")
    expect(err).to include("does not exist (no signatures loaded from it)")
  end

  it "surfaces the signature_paths warning in --format=json config_warnings for CI consumers" do
    File.write("a.rb", "x = 1\n")
    File.write(".rigor.yml", "signature_paths:\n  - ./no_such_sig\n")

    _status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "--config", ".rigor.yml",
                         "a.rb"])

    warnings = JSON.parse(out).fetch("config_warnings")
    sig = warnings.find { |w| w["kind"] == "signature_path" }
    expect(sig).to include("status" => "missing")
    expect(sig.fetch("path")).to end_with("no_such_sig")
  end

  # Issue #697 — the interim fix is the warning and nothing else. The `call.undefined-method`
  # row it explains STILL fires: teaching the check rules to recognise this route would be a
  # fourth way for a class to be open-receiver protected, which is #660's question. This
  # example pins both halves together so a later change cannot quietly turn the warning into
  # a cure and leave the message telling users to edit a config that already works.
  it "warns when signature_paths: reaches a bundled plugin's sig/ that plugins: does not name, " \
     "and still reports the false positive it explains" do
    sig = Rigor::SignaturePathAudit.bundled_plugin_sig_dirs.fetch("rigor-activerecord")
    Dir.mkdir("sig")
    File.write("sig/app.rbs", "class Post\n  def rel: () -> ActiveRecord::Relation\nend\n")
    File.write("code.rb", "Post.new.rel.published_since_last_week\n")
    File.write(".rigor.yml", "signature_paths:\n  - #{sig}\n  - ./sig\n")

    status, out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--workers=0", "--format=json",
                            "--config", ".rigor.yml", "code.rb"])

    expect(err).to include("Add \"rigor-activerecord\" to `plugins:`")
    route = JSON.parse(out).fetch("config_warnings").find { |w| w["kind"] == "bundled_plugin_signature_path" }
    expect(route).to include("gem" => "rigor-activerecord")
    expect(status).to eq(1)
    expect(JSON.parse(out).fetch("diagnostics").map { |d| d["rule"] }).to include("call.undefined-method")
  end

  it "stays silent about the bundled plugin's sig/ when plugins: names it" do
    sig = Rigor::SignaturePathAudit.bundled_plugin_sig_dirs.fetch("rigor-activerecord")
    File.write("code.rb", "x = 1\n")
    File.write(".rigor.yml", "plugins:\n  - rigor-activerecord\nsignature_paths:\n  - #{sig}\n")

    _status, out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--workers=0", "--format=json",
                             "--config", ".rigor.yml", "code.rb"])

    expect(err).not_to include("to `plugins:`")
    warnings = JSON.parse(out)["config_warnings"] || []
    expect(warnings.map { |w| w["kind"] }).not_to include("bundled_plugin_signature_path")
  end

  it "warns when a configured libraries: entry is not an available RBS library" do
    File.write("a.rb", "x = 1\n")
    File.write(".rigor.yml", "libraries:\n  - this_library_does_not_exist_xyz\n")

    _status, out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "--config", ".rigor.yml",
                             "a.rb"])

    expect(err).to include("is not an available RBS library")
    lib = JSON.parse(out).fetch("config_warnings").find { |w| w["kind"] == "library" }
    expect(lib.fetch("name")).to eq("this_library_does_not_exist_xyz")
  end

  it "warns when a disable: token under a built-in family names no rule" do
    File.write("a.rb", "x = 1\n")
    File.write(".rigor.yml", "disable:\n  - call.undefined-methdo\n")

    _status, out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "--config", ".rigor.yml",
                             "a.rb"])

    expect(err).to include("the suppression has no effect")
    rule = JSON.parse(out).fetch("config_warnings").find { |w| w["kind"] == "disabled_rule" }
    expect(rule.fetch("token")).to eq("call.undefined-methdo")
  end

  it "does NOT warn on a disable: token under a non-built-in (plugin) family" do
    File.write("a.rb", "x = 1\n")
    File.write(".rigor.yml", "disable:\n  - rspec.let-binding\n")

    _status, out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "--config", ".rigor.yml",
                             "a.rb"])

    expect(err).not_to include("the suppression has no effect")
    expect(JSON.parse(out)).not_to have_key("config_warnings")
  end

  it "stays silent (and omits config_warnings) when nothing is misconfigured" do
    File.write("a.rb", "x = 1\n")

    _status, out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "a.rb"])

    expect(err).not_to include("rigor: ")
    expect(JSON.parse(out)).not_to have_key("config_warnings")
  end

  it "prints a one-line coverage summary under --coverage in text mode" do
    File.write("sample.rb", "x = 1\n")

    _status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--coverage", "sample.rb"])

    expect(out).to include("Type coverage:")
    expect(out).to include("% precise")
  end

  it "seeds parallel-assignment ivar writes so a cross-method read is not always-falsey (N1)" do
    # `old, @cb = @cb, block` records the `@cb` target into the class-ivar union; before N1 the collector dropped it and
    # `@cb` seeded pure `Constant[nil]`, folding `if @cb` always-falsey.
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

  # Issue #812 — `rigor check`'s exit code is `:error`-only by default, so a `:warning` (or `:info`)
  # diagnostic passes both this process's exit code and a Makefile gate built on it (`def.return-type-mismatch`,
  # #810, sat on `master` this way across #800-#809). `--fail-on` raises the bar for callers — like the `check`
  # / `check-plugins` self-check targets — that want the stricter reading without changing what an ordinary
  # `rigor check` invocation reports.
  describe "--fail-on" do
    # `call.undefined-method` fires reliably on a well-typed receiver with no library configuration; overriding
    # its severity via `severity_overrides:` gives a deterministic single `:warning` (or `:info`) without
    # depending on any rule's authored default.
    def write_severity_override_project(severity)
      File.write(".rigor.yml", "severity_overrides:\n  call: #{severity}\n")
      File.write("warn.rb", "1.this_method_does_not_exist\n")
    end

    it "exits 0 on a lone :warning without the flag" do
      write_severity_override_project("warning")

      status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "warn.rb"])

      expect(status).to eq(0)
      expect(out).to include("warning:")
    end

    it "exits non-zero on the same :warning with --fail-on=warning" do
      write_severity_override_project("warning")

      status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--fail-on=warning", "warn.rb"])

      expect(status).to eq(1)
      expect(out).to include("warning:")
    end

    it "exits non-zero on a lone :info with --fail-on=info" do
      write_severity_override_project("info")

      status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--fail-on=info", "warn.rb"])

      expect(status).to eq(1)
      expect(out).to include("info:")
    end

    it "leaves a lone :info passing under --fail-on=warning" do
      write_severity_override_project("info")

      status, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--fail-on=warning", "warn.rb"])

      expect(status).to eq(0)
    end

    it "exits with a usage error for an unrecognised --fail-on value" do
      File.write("clean.rb", "x = 1\n")

      status, _out, err = run(["--no-cache", "--no-ci-detect", "--no-stats", "--fail-on=bogus", "clean.rb"])

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("invalid --fail-on value: bogus")
    end

    it "carries the effective threshold in the --format json payload" do
      File.write("clean.rb", "x = 1\n")

      _status, out, = run(["--no-cache", "--no-ci-detect", "--no-stats", "--format=json", "--fail-on=warning",
                           "clean.rb"])

      expect(JSON.parse(out).fetch("fail_on")).to eq("warning")
    end
  end

  describe "#parse_check_options" do
    subject(:command) { described_class.new(argv: argv, out: StringIO.new, err: StringIO.new) }

    let(:argv) { [] }

    it "defaults to the text format with stats and CI detection on" do
      options = command.send(:parse_check_options)

      expect(options).to include(
        format: "text", stats: true, ci_detect: true, no_cache: false,
        baseline: :unset, baseline_strict: false, incremental: false, fail_on: :error
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

    it "parses --fail-on=warning into the :warning symbol" do
      command = described_class.new(argv: ["--fail-on=warning"], out: StringIO.new, err: StringIO.new)

      options = command.send(:parse_check_options)

      expect(options).to include(fail_on: :warning)
    end
  end

  describe "CheckRunnerFactory.resolve_workers (ADR-15 Phase 4c precedence)" do
    let(:configuration) { instance_double(Rigor::Configuration, parallel_workers: 0) }

    it "prefers an explicit --workers value, clamping negatives to 0" do
      expect(Rigor::CLI::CheckRunnerFactory.resolve_workers({ workers: "-1" }, configuration)).to eq(0)
      expect(Rigor::CLI::CheckRunnerFactory.resolve_workers({ workers: "4" }, configuration)).to eq(4)
    end

    it "falls back to the configuration default when no CLI / env override is set" do
      allow(configuration).to receive(:parallel_workers).and_return(5)
      saved = ENV.fetch("RIGOR_RACTOR_WORKERS", :absent)
      ENV.delete("RIGOR_RACTOR_WORKERS")

      expect(Rigor::CLI::CheckRunnerFactory.resolve_workers({ workers: nil }, configuration)).to eq(5)
    ensure
      saved == :absent ? ENV.delete("RIGOR_RACTOR_WORKERS") : (ENV["RIGOR_RACTOR_WORKERS"] = saved)
    end
  end

  # ADR-50 § WD2 — the `--bleeding-edge[=ids]` / `--no-bleeding-edge` CLI mirror of the `bleeding_edge:` config key.
  describe "the --bleeding-edge flag" do
    def options_for(argv)
      command = described_class.new(argv: argv, out: StringIO.new, err: StringIO.new)
      [command, command.send(:parse_check_options)]
    end

    it "defaults to :unset so an absent flag leaves the configured selection in place" do
      _, options = options_for([])
      expect(options[:bleeding_edge]).to eq(:unset)
    end

    it "treats a bare --bleeding-edge as the whole overlay without swallowing a path" do
      command, options = options_for(["--bleeding-edge", "lib"])
      expect(options[:bleeding_edge]).to be(true)
      expect(command.instance_variable_get(:@argv)).to eq(["lib"])
    end

    it "parses --bleeding-edge=a,b into a feature-id list, trimming blanks" do
      command, options = options_for(["--bleeding-edge=a, b ,", "lib"])
      expect(options[:bleeding_edge]).to eq(%w[a b])
      expect(command.instance_variable_get(:@argv)).to eq(["lib"])
    end

    it "maps --no-bleeding-edge to false" do
      _, options = options_for(["--no-bleeding-edge", "lib"])
      expect(options[:bleeding_edge]).to be(false)
    end

    describe "#apply_bleeding_edge_override (CLI-over-config precedence)" do
      subject(:command) { described_class.new(argv: [], out: StringIO.new, err: StringIO.new) }

      let(:configuration) { Rigor::Configuration.new("bleeding_edge" => true) }

      it "returns the loaded configuration unchanged when the flag is unset" do
        result = command.send(:apply_bleeding_edge_override, configuration, { bleeding_edge: :unset })
        expect(result).to equal(configuration)
      end

      it "overrides the configured selection when the flag is given" do
        result = command.send(:apply_bleeding_edge_override, configuration, { bleeding_edge: false })
        expect(result.bleeding_edge).to eq("mode" => "none")
        expect(configuration.bleeding_edge).to eq("mode" => "all")
      end

      # ADR-50 § WD2 — a behaviour feature is read through `Configuration#bleeding_edge_active?`, so the flag
      # has to reach that predicate too, not only the severity map.
      it "carries the override through to the behaviour predicate" do
        stub_const(
          "Rigor::BleedingEdge::FEATURES",
          [Rigor::BleedingEdge::Feature.new(id: "feat-b", summary: "s", kind: :behaviour)].freeze
        )
        config = Rigor::Configuration.new("bleeding_edge" => false)

        expect(command.send(:apply_bleeding_edge_override, config, { bleeding_edge: true })
                      .bleeding_edge_active?("feat-b")).to be(true)
        expect(command.send(:apply_bleeding_edge_override, config, { bleeding_edge: %w[feat-b] })
                      .bleeding_edge_active?("feat-b")).to be(true)
        expect(command.send(:apply_bleeding_edge_override, config, { bleeding_edge: false })
                      .bleeding_edge_active?("feat-b")).to be(false)
      end
    end
  end

  # Issue #1579 — the `--incremental` opaque-plugin notes say WHY a plugin is opaque. A plugin with no surface
  # must declare one; an undigestible value or a raising hook must be fixed where it lives, so the note names it.
  describe "the --incremental opaque-plugin notes" do
    let(:reason) { Rigor::Analysis::PluginFactFingerprint::OpaqueReason }
    let(:no_surface) { reason.new(kind: :no_surface, input: nil, class_name: nil) }
    let(:proc_producer) { reason.new(kind: :undigestible, input: "producer worker_index", class_name: "Proc") }
    let(:fingerprint_tail) { "; the snapshot cannot be reused (full analysis every run).\n" }

    def session_double(reasons, invalidated: false, store: false)
      instance_double(
        Rigor::Analysis::IncrementalSession,
        opaque_reasons: reasons, fact_surface_invalidated?: invalidated, fact_store_unreadable?: store,
        opaque_fact_surface?: !reasons.empty? || store
      )
    end

    def note_for(session)
      err = StringIO.new
      described_class.new(argv: [], out: StringIO.new, err: err).send(:emit_incremental_fact_surface_notes, session)
      err.string
    end

    it "words a single plugin with no fingerprint surface, in the singular" do
      expect(note_for(session_double({ "fp-opaque" => no_surface }))).to eq(
        "rigor: --incremental plugin fp-opaque contributes call-site types with no incremental " \
        "fingerprint surface#{fingerprint_tail}"
      )
    end

    it "groups several surfaceless plugins into one line, in the plural" do
      err = note_for(session_double({ "fp-a" => no_surface, "fp-b" => no_surface }))

      expect(err).to eq(
        "rigor: --incremental plugins fp-a, fp-b contribute call-site types with no incremental " \
        "fingerprint surface#{fingerprint_tail}"
      )
    end

    it "names the undigestible producer value and its class" do
      expect(note_for(session_double({ "sidekiq" => proc_producer }))).to eq(
        "rigor: --incremental plugin sidekiq's producer worker_index has a value the incremental fingerprint " \
        "cannot digest (a Proc)#{fingerprint_tail}"
      )
    end

    it "chooses the article from the class name, and says an anonymous class plainly" do
      io = reason.new(kind: :undigestible, input: "fact callback", class_name: "IO")
      anon = reason.new(kind: :undigestible, input: "fact callback", class_name: "anonymous Class")

      expect(note_for(session_double({ "a" => io }))).to include("(an IO)")
      expect(note_for(session_double({ "a" => anon }))).to include("(an anonymous Class)")
    end

    it "words a raising hook as raising the exception class, not as an undigestible value" do
      hook = reason.new(kind: :raised, input: "hook incremental_state_fingerprint", class_name: "ArgumentError")

      expect(note_for(session_double({ "a" => hook }))).to eq(
        "rigor: --incremental plugin a's hook incremental_state_fingerprint raised ArgumentError#{fingerprint_tail}"
      )
    end

    it "emits one line for an unreadable fact store, naming no plugin" do
      err = note_for(session_double({}, store: true))

      expect(err).to eq(
        "rigor: --incremental the plugin fact store could not be read; the snapshot cannot be reused " \
        "(full analysis every run).\n"
      )
    end

    it "prints nothing for a run with no opaque plugin and an unchanged fact surface" do
      expect(note_for(session_double({}))).to eq("")
    end

    it "reports a changed fact surface only when nothing is opaque" do
      expect(note_for(session_double({}, invalidated: true))).to eq(
        "rigor: --incremental plugin fact surface changed since the snapshot; ran a full analysis.\n"
      )
      expect(note_for(session_double({ "fp-opaque" => no_surface }, invalidated: true))).not_to include("changed")
    end

    it "gives --cache-stats the same reason per opaque plugin, and the store when it is unreadable" do
      session = session_double({ "fp-opaque" => no_surface, "sidekiq" => proc_producer }, store: true)
      command = described_class.new(argv: [], out: StringIO.new, err: StringIO.new)
      allow(command).to receive(:write_cache_stats)

      command.send(:write_incremental_cache_stats, session, "root", nil, "text")

      expect(command.instance_variable_get(:@out).string).to eq(
        "  plugin fact surface: opaque (fp-opaque: no incremental fingerprint surface; sidekiq: producer " \
        "worker_index has a value the incremental fingerprint cannot digest (a Proc); fact store: could not be read)\n"
      )
    end
  end
end
