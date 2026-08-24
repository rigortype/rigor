# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/effects_command"

# ADR-103 #379 — `rigor effects`, the bare report. The table it prints is pinned in
# `spec/rigor/effects/tracer_collection_spec.rb`; this file pins the command surface: the two formats,
# the omission rule, the exit codes, and the ad-hoc opt-in that lets the command run against a project
# whose configuration carries no `effects:` block.
RSpec.describe Rigor::CLI::EffectsCommand do
  def fixture
    File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
  end

  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  # `Configuration.load(nil)` discovers the repository's own `.rigor.yml`, which has no `effects:` block;
  # running from an empty directory proves the command's implicit `effects: {}` is what turns collection
  # on rather than any project setting.
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  it "prints one line per method, sorted by key, with the proven labels" do
    status, out, = run([fixture])

    expect(status).to eq(0)
    expect(out).to include("Tracer::Reporter#report: [io.output.stdout, nondet.time]\n")
    expect(out.lines.grep(/^Tracer/).map { |line| line.split(":").first }).to eq(out.lines.grep(/^Tracer/)
      .map { |line| line.split(":").first }.sort)
  end

  # #434 — the reason block was 86.5 % of the bytes of a 31,191-line Redmine run, so the default keeps
  # the count on the row that made a reader curious and `--why` expands it. These two rows carry no label
  # in either lane, which is the other thing the default drops, so they need `--full` to be printed at all.
  it "collapses a non-exhaustive method's causes to a count, and expands them under --why" do
    _, collapsed, = run(["--full", fixture])
    _, expanded, = run(["--full", "--why", fixture])

    expect(collapsed).to include("Tracer::Gateway#dispatch: [] …? (1 reason, --why)\n")
    expect(collapsed).not_to include("    dynamic-send")
    expect(expanded).to include("Tracer::Gateway#dispatch: [] …?\n    dynamic-send\n")
    expect(expanded).to include("Tracer::Gateway#probe: [] …?\n    dynamic-receiver (inferred_return_untyped)\n")
  end

  # #439 — a path argument used to narrow the ANALYSIS, and an effect summary is transitive over
  # whatever was analysed, so the narrowed run answered `[] …?` for methods the whole-project run
  # answered labels for. Nothing distinguished that from a method which genuinely does nothing, and a
  # path argument was the only tractability lever the report had, so it was the first thing an adopter
  # reached for.
  describe "a path argument (#439)" do
    # A configuration whose `paths:` is the fixture, so the argument under test is a *narrowing* of an
    # already-analysed set — which is what a path argument is inside a real project.
    def config_file
      path = File.join(Dir.pwd, ".rigor.yml")
      File.write(path, "paths:\n  - #{fixture}\n")
      path
    end

    # `app.rb` is the discriminating selection: `Tracer::Dispatcher#run` reaches `Tracer::Loud#emit`,
    # which lives in `loud.rb` precisely so that a per-file view cannot see it. Under the old behaviour
    # this run analysed `app.rb` alone and answered a weaker row for it.
    it "selects which units are printed and leaves every label the whole-project one" do
      _, whole, = run(["--config", config_file])
      _, narrowed, = run(["--config", config_file, File.join(fixture, "app.rb")])

      selected = narrowed.lines.grep(/: \[/)
      expect(selected).not_to be_empty
      expect(selected).to all(satisfy { |line| whole.include?(line) })
      expect(selected.length).to be < whole.lines.grep(/: \[/).length
    end

    it "says how much it selected, and that the analysis was not narrowed" do
      _, _, err = run(["--config", config_file, File.join(fixture, "app.rb")])

      expect(err).to match(/showing \d+ of \d+ units, selected by/)
      expect(err).to include("a path narrows the printing and not the analysis")
    end

    it "says so when a path names no unit, rather than printing an empty report" do
      status, out, err = run(["--config", config_file, File.join(fixture, "nothing_here")])

      expect(status).to eq(0)
      expect(out.lines.grep(/: \[/)).to be_empty
      expect(err).to include("no effect unit is defined in")
      expect(err).to include("a path selects what is printed, not what is analysed")
    end

    it "prints the whole report and no note when no path is given" do
      _, out, err = run(["--config", config_file])

      expect(out.lines.grep(/: \[/)).not_to be_empty
      expect(err).to be_empty
    end
  end

  # Omission rule: exhaustive AND proving nothing beyond `mutate.local`, which every envelope tolerates.
  it "omits a pure method by default and lists it under --full" do
    _, default, = run([fixture])
    _, full, = run(["--full", fixture])

    expect(default).not_to include("Tracer::Reporter#collect")
    expect(default).not_to include("Tracer::Reporter#label")
    expect(full).to include("Tracer::Reporter#collect: [mutate.local]\n")
    expect(full).to include("Tracer::Reporter#label: []\n")
  end

  # #457 — every question in the user-story note was answered with `grep` and a throwaway script, and
  # the sharpest instance was that the report's own on-ramp — "find the methods you can safely declare
  # pure" — is exactly the set the default omits.
  describe "the query surface (#457)" do
    it "selects by label, matching a label and everything under it, in either lane" do
      _, out, = run(["--label", "io.output.stdout", fixture])

      rows = out.lines.grep(/: \[/)
      expect(rows).not_to be_empty
      expect(rows).to all(include("io.output"))
      expect(out).to include("Tracer::Reporter#report:")
    end

    it "selects a root and matches its leaves" do
      _, leaf, = run(["--label", "io.output.stdout", fixture])
      _, root, = run(["--label", "io", fixture])

      expect(root.lines.grep(/: \[/).length).to be >= leaf.lines.grep(/: \[/).length
      expect(root).to include("Tracer::Reporter#report:")
    end

    it "prints the pure set, which the default report omits by construction" do
      _, default, = run([fixture])
      _, pure, = run(["--pure", fixture])

      expect(default).not_to include("Tracer::Reporter#collect")
      expect(pure).to include("Tracer::Reporter#collect: [mutate.local]\n")
      expect(pure).to include("Tracer::Reporter#label: []\n")
      expect(pure.lines.grep(/: \[/)).to all(satisfy { |line| !line.include?("…?") && !line.include?("≤") })
    end

    # `--full` answers the omission rule and nothing else, so a filtered run must not offer it as the
    # way to see what the filter dropped.
    it "says rows were not selected rather than offering --full for them" do
      _, filtered, = run(["--label", "io.output.stdout", fixture])
      _, unfiltered, = run([fixture])

      expect(filtered).to include("not selected")
      expect(filtered).not_to include("--full")
      expect(unfiltered).to include("omitted (--full)")
    end

    it "caps the printed rows with --limit and says how many it cut" do
      _, out, = run(["--limit", "1", fixture])

      expect(out.lines.grep(/: \[/).length).to eq(1)
      expect(out).to include("cut by --limit")
    end
  end

  # #429 — four configuration keys and two annotation forms all require typing an effect label, and
  # nothing in an installed Rigor could say what the labels are: the manual's pointers resolve into
  # `docs/type-specification/`, which the gemspec does not package.
  describe "--list-labels (#429)" do
    it "prints the whole vocabulary, grouped by root, with each root's meaning" do
      status, out, = run(["--list-labels", fixture])

      expect(status).to eq(0)
      expect(out).to match(/\AEffect vocabulary — \d+ labels \(vocabulary \d+\)/)
      expect(out).to include("io — talks to something outside the process")
      expect(out).to include("io.db.read")
      expect(out).to include("nondet — reads something that differs between two otherwise identical runs")
      expect(out).to include("mutate.local")
    end

    it "explains the subsumption rule the four config keys depend on" do
      _, out, = run(["--list-labels", fixture])

      expect(out).to include("`io` covers `io.db.read`, `io.db.read` does not cover `io`")
    end

    it "analyses nothing" do
      _, listed, = run(["--list-labels", fixture])

      expect(listed).not_to include("Tracer::Reporter#report")
    end
  end

  # #434 — the report had no summary line at all, and the two lanes are counted apart because they have
  # different powers: a declared label can never fail a build (ADR-103 § WD17).
  it "closes with a footer counting the two lanes apart" do
    _, out, = run([fixture])

    expect(out).to match(/^\d+ of \d+ units printed/)
    expect(out).to match(/^\d+ carry a proven label · \d+ carry a declared \(≤\) one · \d+ are exhaustive$/)
  end

  it "emits the methods table under --format json" do
    status, out, = run(["--format", "json", fixture])
    payload = JSON.parse(out)

    expect(status).to eq(0)
    expect(payload.dig("methods", "Tracer::Reporter#report")).to eq(
      "effects" => %w[io.output.stdout nondet.time],
      "declared" => [],
      "exhaustive" => true,
      "causes" => [],
      "direct" => { "catalogue:Kernel#puts" => ["io.output.stdout"], "catalogue:Time.now" => ["nondet.time"] },
      "attribution" => {}
    )
  end

  # The footer's counts, for the reader that is a script (#434).
  it "carries the totals in the JSON payload" do
    _, out, = run(["--format", "json", fixture])
    totals = JSON.parse(out).fetch("totals")

    expect(totals.keys).to contain_exactly("units", "printed", "omitted", "unselected", "proven",
                                           "declared", "exhaustive", "truncated")
    expect(totals.fetch("printed")).to be_positive
    expect(totals.fetch("units")).to be >= totals.fetch("printed")
  end

  it "reports the taint causes as [cause, detail] pairs in JSON" do
    _, out, = run(["--full", "--format", "json", fixture])

    expect(JSON.parse(out).dig("methods", "Tracer::Gateway#probe", "causes"))
      .to eq([%w[dynamic-receiver inferred_return_untyped]])
  end

  it "rejects an unsupported format with the documented usage status" do
    status, _out, err = run(["--format=xml", fixture])

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("unsupported format: xml")
  end

  it "is registered as a CLI subcommand" do
    expect(Rigor::CLI::HANDLERS).to include("effects" => :run_effects)
    expect(Rigor::CLI.new([], out: StringIO.new, err: StringIO.new).send(:help)).to include("effects")
  end
end
