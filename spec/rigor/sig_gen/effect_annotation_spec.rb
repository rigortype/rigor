# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor"
require "rigor/analysis/runner"

# ADR-103 WD9 / ADR-14's reserved annotation-emission slot (#391) — `rigor sig-gen` writing `%a{pure}`
# and `%a{rigor:v1:effect …}` back from effect summaries.
#
# The fixture in `spec/integration/fixtures/sig_gen/effect_annotations` carries one class per decision
# the emitter has to make, and the summaries below are the REAL ones an analysis produces over it, not a
# synthetic table: the FP surface of this feature is precisely "what does the engine actually prove about
# an ordinary method", and a hand-built table cannot answer that.
RSpec.describe Rigor::SigGen::EffectAnnotation do
  def fixture
    File.expand_path("../../integration/fixtures/sig_gen/effect_annotations", __dir__)
  end

  # `tolerated: [telemetry]` is what makes `Annotated::Chatty#note` the fourth-invariant case: its whole
  # proven footprint (`io`, `telemetry`) arrives through one `Logger#info` origin the policy discharges,
  # so the JUDGMENT reads as clean as `Annotated::Pure#label` does and the RECORD does not.
  # The `match:`-selected stanza the envelope index deliberately drops. `lib/presented.rb` is the only
  # file it names, so it bounds exactly one class and every other expectation in this file is untouched.
  def match_envelope
    { "match" => "lib/presented.rb", "effect" => ["io.db"] }
  end

  def default_effects
    { "tolerated" => ["telemetry"], "envelopes" => [match_envelope] }
  end

  def configuration(effects: :default, inline: false)
    effects = default_effects if effects == :default
    data = { "paths" => ["lib"], "signature_paths" => ["sig"] }
    data["effects"] = effects unless effects == :absent
    # `Configuration.new` never auto-wires `rigor-rbs-inline` (only `Configuration.load` does), so the
    # spec that exercises the inline `# @rbs %a{…}` spelling lists it the way autowiring would.
    if inline
      data["plugins"] = [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline",
                           "config" => { "require_magic_comment" => false } }]
    end
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  def analysis(root, configuration)
    Dir.chdir(root) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil,
                                           collect_stats: false, workers: 0)
      guarded_run(runner, ["lib"])
      [runner.effect_table, runner.effect_envelopes]
    end
  end

  def candidates(root, envelopes: false, effects: :default, inline: false)
    effects = default_effects if effects == :default
    config = configuration(effects: effects, inline: inline)
    annotator =
      if effects == :absent
        nil
      else
        table, index = analysis(root, config)
        described_class::Annotator.new(
          table: table, envelopes: envelopes, envelope_index: index,
          config_envelopes: Rigor::Effects::ConfigEnvelopes.build(
            entries: config.effects_envelopes, registry: Rigor::Effects::Registry.for_configuration(config)
          )
        )
      end
    Dir.chdir(root) do
      Rigor::SigGen::Generator.new(configuration: config, paths: ["lib"], effect_annotator: annotator).run
    end
  end

  def by_key(rows)
    rows.to_h { |c| ["#{c.class_name}##{c.method_name}", c] }
  end

  describe "which methods earn an annotation" do
    let(:rows) { by_key(candidates(fixture)) }

    it "emits %a{pure} for the exhaustive, undischarged, frame-local method" do
      expect(rows.fetch("Annotated::Pure#label").annotations).to eq(["%a{pure}"])
      expect(rows.fetch("Annotated::Pure#label").effect_reason).to eq(:emitted)
    end

    # Steins' fourth invariant, and `docs/type-specification/effect-labels.md` § Discharge by policy: the
    # judgment over `#note` is empty, so reading the discharged lane would have written `%a{pure}` onto a
    # method that logs. Emission reads the RECORD.
    it "withholds from a method whose whole footprint is policy-tolerated" do
      row = rows.fetch("Annotated::Chatty#note")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_tolerated)
    end

    it "withholds from a method whose summary is non-exhaustive" do
      row = rows.fetch("Annotated::Opaque#dispatch")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_non_exhaustive)
    end

    # The blocker a proven-lane-only reading misses. `Remote.fetch` states its bound, so the label lands
    # in the DECLARED lane with no taint and no proven label: `Zoo#via_envelope` reads `[] <= [io.net.http]`
    # and a `proven.subsumed_by?(TRIVIAL_BOUND)` test calls it pure. `Entry#trivial?` is the test that
    # does not, and it is the one the report already uses for "nothing to say about this method".
    it "withholds from a method whose callee's envelope survives in the declared lane" do
      row = rows.fetch("Annotated::Zoo#via_envelope")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_declared)
    end

    # And the other half: `Vendor.get` resolves to a declaration nothing describes, so the edge lands on
    # no project method and is dropped. Every call RESOLVED, so the summary is exhaustive — "exhaustive"
    # answers a different question from "every callee's footprint is known", and only the second licenses
    # a written bound.
    it "withholds from a method calling a resolved callee nothing describes" do
      row = rows.fetch("Annotated::Zoo#via_gem")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_unclaimed_callee)
    end

    it "withholds one hop above that call too" do
      row = rows.fetch("Annotated::Caller#go")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_unclaimed_callee)
    end

    # The closed-world override join (ADR-103 WD4) makes an edge resolve NON-empty whenever any project
    # subclass overrides the selector — `Sub2#run` here — while `B.run` still dispatches
    # `Supplier::Client#run`, which nothing describes. So the emitter asks whether the RECEIVER'S OWN
    # ancestry answered, not whether the edge reached anything.
    it "withholds when only a subclass override made the edge resolve" do
      row = rows.fetch("Annotated::Use3#u")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_unclaimed_callee)
    end

    # A bound on the method ITSELF goes to the envelope check and never enters any summary's `≤` lane,
    # so the table cannot see it; the emitter asks the run's envelope index. Writing `%a{pure}` here
    # would replace the author's contract with an inference over the body they wrote it about.
    it "withholds from a method whose own sig/ declaration already states a bound" do
      row = rows.fetch("Annotated::Declared#store")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_declared)
    end

    # `EnvelopeIndex#[]` refuses a ⊤ envelope, and rightly: a bound that bounds nothing must not be
    # IMPORTED at a call site. Emission asks the other question. The author wrote about this method and
    # got the label wrong; `%a{pure}` written over it would delete the very annotation
    # `effect.unknown-label` exists to point at.
    it "withholds from a method whose authored bound names an unknown label" do
      row = rows.fetch("Annotated::Declared#typoed")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_declared)
    end

    # A `match:` stanza never reaches the envelope index — a path glob is a fact about where a class is
    # defined, which a per-file collection window cannot see. A sig-gen candidate carries its defining
    # file, so emission can answer what import cannot.
    it "withholds from a method bounded by a match:-selected effects.envelopes: entry" do
      row = rows.fetch("Annotated::Presented#title")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_declared)
    end

    # The plugin class needs registering by hand, once per process. The suite pervasively calls
    # `Rigor::Plugin.unregister!` while `require` is a once-per-process no-op, so a shard that runs this
    # example after one of those — and never alongside `generator_spec`, which registers it for its own
    # ADR-93 example — reaches the loader with an emptied registry, ingests no inline annotation, and
    # would then assert the wrong thing quietly. `generator_spec` and `cli_spec`'s `:rbs_inline_autowire`
    # context do the same dance for the same reason.
    it "withholds from the rbs-inline spelling of the same bound" do
      require "rigor-rbs-inline"
      Rigor::Plugin.register(Rigor::Plugin::RbsInline) unless Rigor::Plugin.registered_for("rbs-inline")

      row = by_key(candidates(fixture, inline: true)).fetch("Annotated::Declared#persist")

      # The precondition, asserted rather than assumed: ADR-93 synthesises `def persist: () -> untyped`
      # from the annotation-only comment, so a `declared_return_rbs` of `untyped` is proof the inline
      # lane actually ran. Without it a plugin that failed to load looks exactly like a passing test.
      expect(row.declared_return_rbs).to eq("untyped")
      expect(row.annotations).to be_empty
      expect(row.effect_reason).to eq(:withheld_declared)
    end

    # The labelled spelling is Rigor's own, so an effectful method stays bare until the flag asks for it.
    it "says nothing about an effectful method without --effect-envelopes" do
      row = rows.fetch("Annotated::Loud#shout")

      expect(row.annotations).to be_empty
      expect(row.effect_reason).to be_nil
    end

    it "emits the labelled envelope for an effectful method under --effect-envelopes" do
      row = by_key(candidates(fixture, envelopes: true)).fetch("Annotated::Loud#shout")

      expect(row.annotations).to eq(["%a{rigor:v1:effect io.output.stdout}"])
      expect(row.effect_reason).to eq(:emitted)
    end

    # `--effect-envelopes` never widens WHICH methods are annotated, only what an already-eligible one
    # says: the two withholding gates run before the flag is consulted.
    it "still withholds from every withheld method under --effect-envelopes" do
      rows = by_key(candidates(fixture, envelopes: true))

      expect(rows.values_at("Annotated::Chatty#note", "Annotated::Opaque#dispatch",
                            "Annotated::Zoo#via_envelope", "Annotated::Zoo#via_gem",
                            "Annotated::Caller#go", "Annotated::Use3#u",
                            "Annotated::Declared#store", "Annotated::Declared#typoed",
                            "Annotated::Presented#title").map(&:annotations)).to all(be_empty)
    end
  end

  # The control the acceptance criteria asks for: with no `effects:` block there is no annotator, and
  # every byte sig-gen produces is the byte it produced before this feature existed.
  describe "with the effects opt-in off" do
    it "renders exactly the output a run without the annotator renders" do
      off = render_print(candidates(fixture, effects: :absent))
      on = render_print(candidates(fixture))

      expect(off).not_to include("%a{")
      expect(on).to include("%a{pure}")
      expect(off).to eq(on.gsub(/^ *%a\{pure\}\n/, ""))
    end

    it "carries no effect fields in the JSON payload" do
      row = by_key(candidates(fixture, effects: :absent)).fetch("Annotated::Pure#label")

      expect(row.to_h).not_to have_key(:effect_annotations)
      expect(row.to_h).not_to have_key(:effect_reason)
    end
  end

  def render_print(rows)
    out = StringIO.new
    Rigor::SigGen::Renderer.new(out: out).render(candidates: rows, mode: :print, format: "text", selection: [])
    out.string
  end

  # A `match:` glob is written against the tree the author sees; an invocation may name the same file
  # through a symlink. `sig-gen alias/presented.rb` where `alias` links to `lib` used to emit `%a{pure}`
  # over a stanza that bounds the file, while `sig-gen lib/presented.rb` and a bare `sig-gen` withheld —
  # the same method, three spellings, two answers.
  describe "a match: entry reached through a symlink" do
    let(:root) do
      Dir.mktmpdir.tap do |dir|
        FileUtils.cp_r(File.join(fixture, "."), dir)
        FileUtils.ln_s("lib", File.join(dir, "alias"))
      end
    end

    after { FileUtils.remove_entry(root) }

    def title_row(path)
      config = configuration
      table, index = analysis(root, config)
      annotator = described_class::Annotator.new(
        table: table, envelope_index: index,
        config_envelopes: Rigor::Effects::ConfigEnvelopes.build(
          entries: config.effects_envelopes, registry: Rigor::Effects::Registry.for_configuration(config)
        )
      )
      rows = Dir.chdir(root) do
        Rigor::SigGen::Generator.new(configuration: config, paths: [path], effect_annotator: annotator).run
      end
      rows.find { |c| c.method_name == :title }
    end

    it "withholds whichever spelling of the file the invocation used" do
      expect(title_row("lib/presented.rb").effect_reason).to eq(:withheld_declared)
      expect(title_row("alias/presented.rb").effect_reason).to eq(:withheld_declared)
    end

    it "withholds for an absolute path too" do
      expect(title_row(File.join(root, "lib/presented.rb")).effect_reason).to eq(:withheld_declared)
    end
  end

  describe "the writer" do
    let(:root) do
      Dir.mktmpdir.tap { |dir| FileUtils.cp_r(File.join(fixture, "."), dir) }
    end

    after { FileUtils.remove_entry(root) }

    def writer(overwrite: false)
      config = configuration
      mapper = Rigor::SigGen::PathMapper.new(configuration: config, project_root: root)
      Rigor::SigGen::Writer.new(path_mapper: mapper, overwrite: overwrite)
    end

    def write_all(**)
      rows = candidates(root, **)
      Dir.chdir(root) { writer.write_all(rows) }
    end

    it "writes the annotation on the line above the declaration it binds" do
      write_all
      written = File.read(File.join(root, "sig/annotated.rbs"))

      expect(written).to match(/%a\{pure\}\n\s*def label:/)
      expect(written).not_to include("%a{rigor:v1:effect")
    end

    it "produces a file rbs itself parses" do
      write_all(envelopes: true)
      written = File.read(File.join(root, "sig/annotated.rbs"))

      expect(Rigor::SigGen::RbsValidity.source_error(written)).to be_nil
      expect(written).to include("%a{rigor:v1:effect io.output.stdout}")
    end

    def effect_findings(config)
      Dir.chdir(root) do
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil,
                                             collect_stats: false, workers: 0)
        guarded_run(runner, ["lib"]).diagnostics.select { |d| d.rule == "effect.envelope-exceeded" }
      end
    end

    # `effect.envelope-exceeded` specifically, not every `effect.*`: the fixture deliberately carries one
    # `%a{rigor:v1:effect bogus.nonsense}`, so an `effect.unknown-label` is an expected constant of this
    # tree rather than something a write could introduce. Pinned as such below so the narrowing cannot
    # quietly absorb a second finding.
    it "reports exactly the one effect finding the fixture is built to carry" do
      write_all(envelopes: true)
      all = Dir.chdir(root) do
        runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil,
                                             collect_stats: false, workers: 0)
        guarded_run(runner, ["lib"]).diagnostics.select { |d| d.rule.start_with?("effect.") }
      end

      expect(all.map(&:rule)).to eq(["effect.unknown-label"])
    end

    # The round trip the acceptance criteria turns on: what sig-gen wrote is read back as an ENFORCED
    # envelope, so a wrong annotation shows up here as `effect.envelope-exceeded` on correct code.
    it "re-checks clean under the effects opt-in" do
      write_all(envelopes: true)

      expect(effect_findings(configuration)).to be_empty
    end

    # And the assertion that actually discriminates the fourth invariant. The envelope check applies
    # `effects.tolerated:` at judgment time, so a `%a{pure}` wrongly written onto `Chatty#note` re-checks
    # clean in THIS project and blows up for everyone else — the downstream consumer reading the shipped
    # `sig/`, and this project's own `--no-tolerated-effects` audit. Re-checking under an empty tolerated
    # list is that audit: with the emitter reading the undischarged lane it is silent, and a one-line
    # change to read the discharged lane instead puts two findings on `Chatty#note`.
    it "re-checks clean with nothing tolerated, which is where a discharged emission would show" do
      write_all(envelopes: true)

      expect(effect_findings(configuration(effects: {}))).to be_empty
    end

    describe "an existing annotation" do
      def declared(body)
        target = File.join(root, "sig/annotated.rbs")
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, body)
        target
      end

      # `RBS::Parser` puts a member's annotations outside its `location`, and the byte-range writer
      # replaces the `def` line only — so an annotation the writer has no grammar for survives an
      # `--overwrite` unchanged, and the candidate is reported rather than silently dropped.
      it "is left byte-untouched, and reported as sig.effect.left-unreadable" do
        original = <<~RBS
          module Annotated
            class Pure
              %a{totally-unknown-to-rigor}
              def label: () -> untyped
            end
          end
        RBS
        target = declared(original)
        rows = candidates(root).select { |c| c.class_name == "Annotated::Pure" }
        result = Dir.chdir(root) { writer(overwrite: true).write_all(rows) }.first

        written = File.read(target)
        expect(written).to include("%a{totally-unknown-to-rigor}")
        expect(written).not_to include("%a{pure}")
        expect(result.left_unreadable.map(&:method_name)).to eq([:label])
        expect(result.to_h.fetch(:effect_left_unreadable).first[:effect_reason])
          .to eq("sig.effect.left-unreadable")
      end

      it "keeps every other annotation on the declaration when the line is replaced" do
        original = <<~RBS
          module Annotated
            class Pure
              %a{implicitly-returns-nil}
              def label: () -> untyped
            end
          end
        RBS
        target = declared(original)
        rows = candidates(root).select { |c| c.class_name == "Annotated::Pure" }
        Dir.chdir(root) { writer(overwrite: true).write_all(rows) }

        expect(File.read(target)).to include("%a{implicitly-returns-nil}\n    def label: () -> Integer")
      end

      it "is added to a declaration that carries none" do
        original = <<~RBS
          module Annotated
            class Pure
              def label: () -> untyped
            end
          end
        RBS
        target = declared(original)
        rows = candidates(root).select { |c| c.class_name == "Annotated::Pure" }
        result = Dir.chdir(root) { writer(overwrite: true).write_all(rows) }.first

        expect(File.read(target)).to include("    %a{pure}\n    def label: () -> Integer")
        expect(result.left_unreadable).to be_empty
      end
    end
  end
end
