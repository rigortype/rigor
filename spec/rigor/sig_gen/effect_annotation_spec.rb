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
  def configuration(effects: { "tolerated" => ["telemetry"] })
    data = { "paths" => ["lib"], "signature_paths" => ["sig"] }
    data["effects"] = effects unless effects == :absent
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  def effect_table(root, configuration)
    Dir.chdir(root) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil,
                                           collect_stats: false, workers: 0)
      guarded_run(runner, ["lib"])
      runner.effect_table
    end
  end

  def candidates(root, envelopes: false, effects: { "tolerated" => ["telemetry"] })
    config = configuration(effects: effects)
    annotator =
      if effects == :absent
        nil
      else
        described_class::Annotator.new(table: effect_table(root, config), envelopes: envelopes)
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
    it "still withholds from the tolerated and non-exhaustive methods under --effect-envelopes" do
      rows = by_key(candidates(fixture, envelopes: true))

      expect(rows.fetch("Annotated::Chatty#note").annotations).to be_empty
      expect(rows.fetch("Annotated::Opaque#dispatch").annotations).to be_empty
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
        guarded_run(runner, ["lib"]).diagnostics.select { |d| d.rule.start_with?("effect.") }
      end
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
          .to eq("sig.effect.emitted")
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
