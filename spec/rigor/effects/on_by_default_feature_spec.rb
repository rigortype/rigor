# frozen_string_literal: true

require "rigor"

# ADR-103 WD15 — the "effects-on-by-default" bleeding-edge preview of the v0.4.0 default, exercised end to
# end over the same tracer fixture `spec/rigor/effects/tracer_collection_spec.rb` uses. This pins two
# things the config-level spec (`spec/rigor/configuration_spec.rb`) cannot: that adopting the feature with
# no `effects:` key really does make `rigor effects`' report non-empty, and that — because collection is
# observational (ADR-103 WD13) — `rigor check`'s own diagnostics stay byte-identical to a run with the
# feature off altogether.
RSpec.describe "the effects-on-by-default bleeding-edge feature over the tracer fixture" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
  end

  # `data` is a raw, non-`DEFAULTS`-merged hash throughout — the same shape `Configuration.new` sees from a
  # loaded `.rigor.yml` with no `effects:` key at all, which is exactly the case this feature exists for.
  def configuration(bleeding_edge: nil)
    data = { "paths" => [fixture] }
    data["bleeding_edge"] = bleeding_edge if bleeding_edge
    Rigor::Configuration.new(data)
  end

  def analyze(configuration)
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    diagnostics = guarded_run(runner, [fixture]).diagnostics
    [runner, diagnostics]
  end

  it "leaves effects off, and the table empty, with the feature not adopted" do
    config = configuration
    runner, = analyze(config)

    expect(config.effects_enabled?).to be(false)
    expect(runner.effect_table).to be_empty
  end

  it "turns effects on and yields a non-empty report with no effects: block written" do
    config = configuration(bleeding_edge: ["effects-on-by-default"])
    runner, = analyze(config)

    expect(config.effects_enabled?).to be(true)
    expect(runner.effect_table).not_to be_empty
    expect(runner.effect_table["Tracer::Reporter#report"].proven.to_a).to eq(%w[io.output.stdout nondet.time])
  end

  # The coexistence gate (ADR-103 WD13): collection is observational, so adopting the feature — and thereby
  # turning collection on — cannot move a `rigor check` diagnostic.
  it "produces byte-identical check diagnostics whether the feature is adopted or not" do
    off = analyze(configuration).last
    on = analyze(configuration(bleeding_edge: ["effects-on-by-default"])).last

    expect(on.map(&:to_s)).to eq(off.map(&:to_s))
  end

  it "is also reached by adopting the whole overlay" do
    config = configuration(bleeding_edge: true)
    runner, = analyze(config)

    expect(config.effects_enabled?).to be(true)
    expect(runner.effect_table).not_to be_empty
  end
end
