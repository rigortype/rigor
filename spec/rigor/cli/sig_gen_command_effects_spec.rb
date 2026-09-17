# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# ADR-103 WD9 (#391) — the CLI half of sig-gen's annotation emission: the opt-in gate, the
# `--effect-envelopes` flag, the JSON field, and the stderr line that says what was withheld.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:fixture) { File.expand_path("../../integration/fixtures/sig_gen/effect_annotations", __dir__) }

  let(:root) do
    Dir.mktmpdir.tap { |dir| FileUtils.cp_r(File.join(fixture, "."), dir) }
  end

  around { |example| Dir.chdir(root) { example.run } }

  after { FileUtils.remove_entry(root) }

  def config_file(effects:)
    body = +"paths:\n  - lib\nsignature_paths:\n  - sig\n"
    body << "effects:\n  tolerated:\n    - telemetry\n" if effects
    path = File.join(root, ".rigor.yml")
    File.write(path, body)
    path
  end

  def run(*argv, effects: true)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv + ["--config=#{config_file(effects: effects)}"],
                                 out: out, err: err).run
    [status, out.string, err.string]
  end

  it "prints %a{pure} above the declaration it binds when the effects opt-in is on" do
    _status, out, = run("--print")

    expect(out).to match(/%a\{pure\}\n\s*def label:/)
    expect(out).not_to include("%a{rigor:v1:effect")
  end

  it "adds the labelled envelope only under --effect-envelopes" do
    _status, out, = run("--print", "--effect-envelopes")

    expect(out).to include("%a{rigor:v1:effect io.output.stdout}")
  end

  it "carries the emission in named JSON fields" do
    _status, out, = run("--print", "--format=json")
    rows = JSON.parse(out).fetch("candidates").to_h { |row| [row["method"], row] }

    expect(rows.fetch("label").fetch("effect_annotations")).to eq(["%a{pure}"])
    expect(rows.fetch("label").fetch("effect_reason")).to eq("sig.effect.emitted")
    expect(rows.fetch("note").fetch("effect_reason")).to eq("sig.effect.withheld-tolerated")
    expect(rows.fetch("dispatch").fetch("effect_reason")).to eq("sig.effect.withheld-non-exhaustive")
  end

  it "names the withheld reasons once on stderr in text mode" do
    _status, _out, err = run("--print")

    expect(err).to include("sig.effect.withheld-tolerated: 1")
    expect(err).to include("sig.effect.withheld-non-exhaustive: 1")
  end

  # The acceptance criteria's control: a project with no `effects:` block pays nothing and sees nothing.
  describe "with the effects opt-in off" do
    it "prints exactly what it printed before the annotation slot was filled" do
      _status, off, = run("--print", effects: false)
      _status, on, = run("--print")

      expect(off).not_to include("%a{")
      expect(off).to eq(on.gsub(/^ *%a\{pure\}\n/, ""))
    end

    it "carries no effect fields in the JSON payload" do
      _status, out, = run("--print", "--format=json", effects: false)

      expect(out).not_to include("effect_annotations")
      expect(out).not_to include("effect_reason")
    end

    # A flag that silently does nothing is worse than one that is refused; this one is neither.
    it "says so when --effect-envelopes is passed anyway" do
      _status, out, err = run("--print", "--effect-envelopes", effects: false)

      expect(err).to include("--effect-envelopes needs the `effects:` opt-in")
      expect(out).not_to include("%a{")
    end
  end
end
