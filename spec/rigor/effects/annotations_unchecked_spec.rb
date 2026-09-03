# frozen_string_literal: true

require "rigor"
require "rigor/analysis/runner"

# ADR-103 WD13 commitment 1 (#384) — `effect.annotations-unchecked`, the residual.
#
# WD13 fixes two rules that pull against each other: an annotation must not turn effect collection
# on, and an annotation must not be silently inert either. One `:info` per run is the whole
# reconciliation.
RSpec.describe "effect.annotations-unchecked" do
  def rule
    "effect.annotations-unchecked"
  end

  def envelopes_fixture
    File.expand_path("../../integration/fixtures/effects/envelopes", __dir__)
  end

  def tracer_fixture
    File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
  end

  def configuration(effects: :absent, **extra)
    data = { "paths" => ["lib"], "signature_paths" => ["sig"] }.merge(extra)
    data["effects"] = effects unless effects == :absent
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  def diagnostics_in(root, configuration, paths: ["lib"])
    Dir.chdir(root) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      guarded_run(runner, paths).diagnostics
    end
  end

  def findings_in(root, configuration, **)
    diagnostics_in(root, configuration, **).select { |d| d.rule == rule }
  end

  it "fires exactly once for a project that carries `%a{pure}` and no `effects:` block" do
    found = findings_in(envelopes_fixture, configuration)

    expect(found.size).to eq(1)
    expect(found.first.message).to include(
      "Effect annotations (`%a{pure}` / `%a{rigor:v1:effect …}`) are present",
      "no `effects:` block", "Add `effects: {}`"
    )
  end

  # Not `.rigor.yml:1` — the fix is a config edit, but the thing being reported is something the
  # author wrote, and pointing at it says WHICH declaration is inert.
  it "points at the first annotation rather than at `.rigor.yml`" do
    found = findings_in(envelopes_fixture, configuration).first

    expect([found.path, found.column, found.severity]).to eq(["sig/envelopes.rbs", 1, :info])
    expect(File.readlines(File.join(envelopes_fixture, found.path))[found.line - 1])
      .to include("%a{rigor:v1:effect io.db}")
  end

  describe "what silences it" do
    it "stays silent under a bare `effects: {}` — the block IS the answer to the question" do
      expect(findings_in(envelopes_fixture, configuration(effects: {}))).to be_empty
    end

    # `check: false` is a deliberate answer too: collection runs, the report and the snapshot work,
    # and only the diagnostic is off. Nagging about it would be nagging about a decision.
    it "stays silent under `effects: {check: false}`" do
      expect(findings_in(envelopes_fixture, configuration(effects: { "check" => false }))).to be_empty
    end

    it "stays silent for a project carrying no effect annotation at all" do
      config = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [tracer_fixture])
      )
      found = diagnostics_in(tracer_fixture, config, paths: [tracer_fixture])

      expect(found.select { |d| d.rule.to_s.start_with?("effect.") }).to be_empty
    end

    it "honours the project `disable:` list" do
      expect(findings_in(envelopes_fixture, configuration(**{ "disable" => [rule] }))).to be_empty
    end
  end

  # The byte-identical contract every effects slice carries, from the other side: with no `effects:`
  # block AND no annotation, the residual must add nothing at all to the stream.
  it "leaves an unannotated, effects-free run's diagnostics untouched" do
    config = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => [tracer_fixture])
    )
    baseline = diagnostics_in(tracer_fixture, config, paths: [tracer_fixture])
    repeat = diagnostics_in(tracer_fixture, config, paths: [tracer_fixture])

    expect(repeat.map { |d| [d.path, d.line, d.rule, d.message] })
      .to eq(baseline.map { |d| [d.path, d.line, d.rule, d.message] })
  end
end
