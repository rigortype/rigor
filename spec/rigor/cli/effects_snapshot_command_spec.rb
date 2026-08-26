# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/effects_command"

# ADR-103 #381 — the snapshot verbs end to end, over a copy of the tracer fixture that examples are free
# to edit. The document's own properties are `spec/rigor/effects/snapshot_spec.rb` and the event
# vocabulary is `spec/rigor/effects/snapshot_diff_spec.rb`; this file pins the wiring: what each verb
# writes, reads and exits with, and the pull-request workflow the whole feature is for.
RSpec.describe Rigor::CLI::EffectsSnapshotCommand do
  def fixture
    File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
  end

  # A reach glob over the project's top-level files, so `reach:` carries the callers of the leaf an
  # example changes. `*` does not cross a directory boundary under `File::FNM_PATHNAME`, which is the
  # `unused --entry-point` semantics this shares.
  def write_config(reach: ['"*.rb"'], extra: "")
    File.write(".rigor.yml", <<~YAML)
      paths:
        - "."
      effects:
      #{extra}  snapshot:
          reach: [#{reach.join(', ')}]
    YAML
  end

  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI::EffectsCommand.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  def snapshot_text
    File.read(".rigor-effects.yml")
  end

  # The leaf change a pull request would make: `Tracer::Loud#emit` starts reading the filesystem. It is
  # defined in `loud.rb`, and `Tracer::Dispatcher#run` (in `overrides.rb`) reaches it through the
  # closed-world override join — so the change shows up as one `methods:` line and two `reach:` ones.
  def add_filesystem_read_to_the_leaf
    File.write("loud.rb", File.read("loud.rb").sub('puts("loud")', 'puts(File.read("loud.txt"))'))
  end

  # An implicit-self call the project defines nowhere, kept ALONGSIDE the write the leaf already proves:
  # the summary stops being exhaustive while the row keeps a label. The label is what keeps the row in
  # the file at all — a row left carrying nothing but its taint is omitted (#411).
  def add_unresolved_call_to_the_leaf
    File.write("loud.rb", File.read("loud.rb").sub('puts("loud")', 'no_such_helper && puts("loud")'))
  end

  # The same unresolved call REPLACING the write: the row ends up with no label in either lane.
  def strip_the_leaf_to_taint_only
    File.write("loud.rb", File.read("loud.rb").sub('puts("loud")', "no_such_helper"))
  end

  around do |example|
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir.glob(File.join(fixture, "*.rb")), dir)
      Dir.chdir(dir) do
        write_config
        example.run
      end
    end
  end

  describe "update" do
    it "writes the snapshot and reports what it recorded" do
      status, _out, err = run("update")

      expect(status).to eq(0)
      expect(err).to include("wrote .rigor-effects.yml")
      expect(snapshot_text).to include('"Tracer::Reporter#report":', 'effects: ["io.output.stdout", "nondet.time"]')
    end

    # `db/schema.rb`'s property: the file is a function of the code, so regenerating it twice is a no-op
    # and a diff in a pull request is always a real change.
    it "is byte-identical run twice" do
      run("update")
      first = snapshot_text
      run("update")

      expect(snapshot_text).to eq(first)
    end

    # The record is UNDISCHARGED: policy applies at judgment time, never while writing. A flag that
    # changed the record would make a policy change indistinguishable from a code change.
    it "writes the same bytes with --no-tolerated-effects" do
      write_config(extra: "  tolerated: [\"nondet.time\"]\n")
      run("update")
      plain = snapshot_text
      run("update", "--no-tolerated-effects")

      expect(snapshot_text).to eq(plain)
    end

    # #436 — an empty `reach:` is reported with the names that would close it. The list is the loaded
    # plugin set's, so a project with no preset-registering plugin is told how a preset comes to exist
    # instead of being handed names it cannot use.
    describe "the empty-reach: note" do
      around do |example|
        Rigor::Effects::EntryPoints.reset!
        example.run
        Rigor::Effects::EntryPoints.reset!
      end

      it "names the presets available to this project" do
        Rigor::Effects::EntryPoints.register("rails-controllers", ["app/controllers/**/*.rb"])
        write_config(reach: [])
        status, _out, err = run("update")

        expect(status).to eq(0)
        expect(err).to include("`effects.snapshot.reach:` is empty",
                               "presets registered in this project: rails-controllers")
      end

      it "says how a preset comes to exist when the project has none" do
        write_config(reach: [])
        _status, _out, err = run("update")

        expect(err).to include("no plugin in this project registers an entry-point preset")
      end
    end

    it "lists the omitted trivial methods under --full" do
      run("update")
      default = snapshot_text
      run("update", "--full")

      expect(default).not_to include('"Tracer::Reporter#collect"')
      expect(snapshot_text).to include('"Tracer::Reporter#collect":')
    end
  end

  describe "check" do
    it "is fresh right after an update" do
      run("update")
      status, out, = run("check")

      expect(status).to eq(0)
      expect(out).to include("No effect drift against .rigor-effects.yml")
    end

    # The workflow, end to end: the change alters a summary, CI fails with explained lines, the developer
    # regenerates and commits, the reviewer reads the diff.
    it "fails with the added label on the leaf and the reach lines behind it" do
      run("update")
      add_filesystem_read_to_the_leaf
      status, out, = run("check")

      expect(status).to eq(1)
      # #435 — every drift row names the file the unit is defined in, project-relative.
      expect(out).to include("methods:\n  Tracer::Loud#emit  + io.fs.read  (loud.rb)\n")
      expect(out).to include("reach:\n  Tracer::Dispatcher#run  + io.fs.read  (overrides.rb)\n")
      expect(out).to end_with("Run `rigor effects explain` to see what caused this, and " \
                              "`rigor effects update` to accept it.\n")
    end

    it "goes fresh again once the developer regenerates" do
      run("update")
      add_filesystem_read_to_the_leaf
      run("update")

      expect(run("check").first).to eq(0)
    end

    # A removal is news too — a job that stopped enqueueing is a bug, not an improvement — unless the
    # project asked for the ratchet.
    it "fails on a removal under the default symmetric gate" do
      add_filesystem_read_to_the_leaf
      run("update")
      File.write("loud.rb", File.read("loud.rb").sub('puts(File.read("loud.txt"))', 'puts("loud")'))
      status, out, = run("check")

      expect(status).to eq(1)
      expect(out).to include("Tracer::Loud#emit  - io.fs.read")
    end

    it "passes the same removal under gate: additions" do
      File.write(".rigor.yml", <<~YAML)
        paths:
          - "."
        effects:
          snapshot:
            gate: additions
            reach: ["*.rb"]
      YAML
      add_filesystem_read_to_the_leaf
      run("update")
      File.write("loud.rb", File.read("loud.rb").sub('puts(File.read("loud.txt"))', 'puts("loud")'))
      status, out, = run("check")

      expect(status).to eq(0)
      expect(out).to include("Tracer::Loud#emit  - io.fs.read")
    end

    it "reports an exhaustiveness transition as its own event" do
      run("update")
      add_unresolved_call_to_the_leaf
      status, out, = run("check")

      expect(status).to eq(1)
      expect(out).to include("Tracer::Loud#emit  exhaustive → not")
    end

    # #434 — a regeneration event says the two records were computed under different rules, so the
    # per-symbol comparison between them is meaningless rather than merely noisy. On redmine one moved
    # `config_digest:` printed 482 `-symbol` lines after the regeneration line; now it prints the line,
    # the scale of what it withheld, and the counts.
    describe "a regeneration event (#434)" do
      # A `tolerated:` entry moves the `effects:` digest without touching a single analysed byte, which
      # is exactly the shape the issue measured.
      def move_the_config_digest
        write_config(extra: "  tolerated: [\"nondet.time\"]\n")
      end

      # The redmine shape: the digest moved AND the analysed rows differ, which is what produced 482
      # `-symbol` lines under one regeneration line.
      it "prints the regeneration line and the counts, and withholds the per-symbol diff" do
        run("update")
        move_the_config_digest
        add_filesystem_read_to_the_leaf
        status, out, = run("check")

        expect(status).to eq(1)
        expect(out).to include("regeneration:\n  config_digest:")
        expect(out).to match(/\d+ per-method differences are not shown/)
        # The withheld half really was withheld.
        expect(out).not_to include("io.fs.read")
        expect(out).not_to include("methods:\n")
      end

      # The other branch: the header moved and the tables agree, so there is nothing to withhold and the
      # line says so rather than reporting a count of zero.
      it "says so plainly when the records agree on every method" do
        run("update")
        move_the_config_digest
        _status, out, = run("check")

        expect(out).to include("The two records are not comparable, so no per-method difference is shown.")
      end

      # `explain` answers "what caused this label to appear"; on a regeneration the answer is "a
      # different set of rules", which it cannot expand and the report already said.
      it "routes to update alone, not to explain" do
        run("update")
        move_the_config_digest
        _status, out, = run("check")

        expect(out).to end_with("Run `rigor effects update` to regenerate the record under the " \
                                "current rules.\n")
      end

      # Non-vacuity for the pair above: the same fixture with the digest UNMOVED still prints the
      # per-symbol diff, so "no -symbol lines" is a property of the regeneration and not of the fixture.
      it "still prints the per-symbol diff when the records are comparable" do
        run("update")
        add_filesystem_read_to_the_leaf
        _status, out, = run("check")

        expect(out).to include("methods:\n")
        expect(out).not_to include("per-method differences are not shown")
      end

      it "carries the withheld count and the regeneration flag under --format json" do
        run("update")
        move_the_config_digest
        add_filesystem_read_to_the_leaf
        _status, out, = run("check", "--format", "json")
        payload = JSON.parse(out)

        expect(payload.fetch("regeneration")).to be(true)
        expect(payload.fetch("footer").fetch("suppressed")).to be_positive
        expect(payload.fetch("events").map { |e| e.fetch("category") }).to eq(["regeneration"])
      end
    end

    # #411 option (b) — a taint-only row carries no label in either lane, so the snapshot stops listing
    # it: what it says ("not exhaustive, and here is why") is what the report and `explain` answer. The
    # change still gates, as a removed symbol rather than an exhaustiveness event, and `--full` keeps the
    # row for anyone who wants the whole table.
    it "omits a row left carrying only its taint, and keeps it under --full" do
      run("update")
      strip_the_leaf_to_taint_only
      status, out, = run("check")

      expect(status).to eq(1)
      expect(out).to include("Tracer::Loud#emit  -symbol [io.output.stdout]")
      expect(snapshot_text).to include("Tracer::Loud#emit")

      run("update")
      expect(snapshot_text).not_to include("Tracer::Loud#emit")

      run("update", "--full")
      expect(snapshot_text).to include("Tracer::Loud#emit")
    end

    # A record written under a different Rigor, vocabulary or `effects:` block is not comparable; the
    # regeneration event says so instead of reporting the incomparability as effect churn.
    it "reports a header mismatch as a regeneration event" do
      run("update")
      File.write(".rigor-effects.yml", snapshot_text.sub("vocabulary: 1", "vocabulary: 99"))
      status, out, = run("check")

      expect(status).to eq(1)
      expect(out).to include("regeneration:\n  vocabulary: 99 → 1")
    end

    it "treats a missing snapshot as routed drift" do
      status, out, = run("check")

      expect(status).to eq(1)
      expect(out).to include("no snapshot; run `rigor effects update`")
    end

    it "compares against --baseline instead of the configured path" do
      run("update")
      FileUtils.mv(".rigor-effects.yml", "committed.yml")

      expect(run("check", "--baseline", "committed.yml").first).to eq(0)
      expect(run("check").first).to eq(1)
    end

    describe "tolerated at judgment time" do
      before do
        write_config(extra: "  tolerated: [\"io.fs\"]\n")
        run("update")
        add_filesystem_read_to_the_leaf
      end

      it "reports the change under its own heading and does not fail the gate" do
        status, out, = run("check")

        expect(status).to eq(0)
        expect(out).to include("tolerated:\n  Tracer::Loud#emit  + io.fs.read  (loud.rb, methods)")
      end

      it "fails on it under --strict-tolerated" do
        expect(run("check", "--strict-tolerated").first).to eq(1)
      end

      it "judges as if the set were empty under --no-tolerated-effects" do
        status, out, = run("check", "--no-tolerated-effects")

        expect(status).to eq(1)
        expect(out).to include("methods:\n  Tracer::Loud#emit  + io.fs.read")
      end
    end

    it "carries the events, the footer and both headers under --format json" do
      run("update")
      add_filesystem_read_to_the_leaf
      status, out, = run("check", "--format", "json")
      payload = JSON.parse(out)

      expect(status).to eq(1)
      expect(payload.fetch("fresh")).to be(false)
      expect(payload.fetch("events")).to include(
        "category" => "label-added", "symbol" => "Tracer::Loud#emit", "table" => "methods",
        "tolerated" => false, "label" => "io.fs.read"
      )
      expect(payload.fetch("footer")).to eq("added_symbols" => 0, "removed_symbols" => 0, "suppressed" => 0)
      expect(payload.dig("header", "current", "rigor")).to eq(Rigor::VERSION)
    end
  end

  # Same comparison, never gating — `--baseline <(git show origin/main:.rigor-effects.yml)` in a bot.
  describe "diff" do
    it "prints the drift and still exits 0" do
      run("update")
      add_filesystem_read_to_the_leaf
      status, out, = run("diff")

      expect(status).to eq(0)
      expect(out).to include("Tracer::Loud#emit  + io.fs.read")
    end
  end

  describe "explain" do
    it "prints the shortest edge path behind a reach change and the origin behind a methods one" do
      run("update")
      add_filesystem_read_to_the_leaf
      status, out, = run("explain")

      expect(status).to eq(0)
      expect(out).to include("Tracer::Dispatcher#run → Tracer::Loud#emit → File.read [io.fs.read]")
      expect(out).to include("Tracer::Loud#emit [io.fs.read] ← catalogue:File.read")
    end

    it "explains one unit on demand, changed or not" do
      run("update")
      _status, out, = run("explain", "--symbol", "Tracer::Dispatcher#run")

      expect(out).to include("Tracer::Dispatcher#run → Tracer::Loud#emit → Kernel#puts [io.output.stdout]")
    end

    # #435 — a misspelled `--symbol` printed `Nothing to explain.` and exited 0, which is exactly what a
    # method with no effects prints. A typo and a real answer were indistinguishable, and a script could
    # not tell them apart at all.
    it "rejects an unknown --symbol with a usage status and the nearest key" do
      run("update")
      status, _out, err = run("explain", "--symbol", "Tracer::Dispatcher#ru")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("no effect unit named Tracer::Dispatcher#ru")
      expect(err).to include("did you mean Tracer::Dispatcher#run?")
    end

    # #435 — `exhaustive → not` is the drift row a reader is least equipped to interpret, and it was the
    # one row `explain` could not expand: it carries no label, so the event produced no explanation at
    # all. What explains it is the taint causes, which is the detail the record stopped keeping per row
    # (#434) — the two halves meet here.
    it "expands an exhaustive → not transition, naming the call that lost it" do
      run("update")
      add_unresolved_call_to_the_leaf
      status, out, = run("explain")

      expect(status).to eq(0)
      expect(out).to include("Tracer::Loud#emit stopped being exhaustive ← ")
      expect(out).to include("no_such_helper")
    end

    # Non-vacuity: with the leaf still exhaustive the same invocation says nothing about exhaustiveness,
    # so the line above is the transition and not a fixture constant.
    it "says nothing about exhaustiveness when the leaf is still exhaustive" do
      run("update")
      add_filesystem_read_to_the_leaf
      _status, out, = run("explain")

      expect(out).not_to include("stopped being exhaustive")
    end

    it "carries the paths under --format json" do
      run("update")
      add_filesystem_read_to_the_leaf
      _status, out, = run("explain", "--format", "json")

      expect(JSON.parse(out).fetch("paths")).to include(
        "table" => "reach", "symbol" => "Tracer::Dispatcher#run", "label" => "io.fs.read",
        "path" => ["Tracer::Dispatcher#run", "Tracer::Loud#emit", "File.read"], "origin" => "File.read",
        "causes" => []
      )
    end
  end

  describe "usage" do
    it "rejects paths, because a snapshot records the whole project" do
      status, _out, err = run("update", "loud.rb")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("takes no paths")
    end

    it "rejects an unsupported format and an unknown flag" do
      expect(run("check", "--format=xml").first).to eq(Rigor::CLI::EXIT_USAGE)
      expect(run("check", "--nope").first).to eq(Rigor::CLI::EXIT_USAGE)
    end

    it "rejects a snapshot file that does not parse" do
      File.write(".rigor-effects.yml", "- not a snapshot\n")
      status, _out, err = run("check")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("effect snapshot load failed")
    end

    it "lists the subcommands under help, and leaves the bare command as the report" do
      status, out, = run("help")

      expect(status).to eq(0)
      expect(out).to include("update", "check", "diff", "explain")
    end
  end
end
