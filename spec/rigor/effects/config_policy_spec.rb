# frozen_string_literal: true

require "stringio"

require "rigor"
require "rigor/analysis/runner"
require "rigor/effects/snapshot"
require "rigor/cli/effects_renderer"
require "rigor/cli/effects_report"

# ADR-103 WD5 / WD6 / WD14 (#385) — the `.rigor.yml` policy surface end to end over
# `spec/integration/fixtures/effects/policy`: envelopes by convention, the attribution table's declared
# lane, the project vocabulary, and per-origin discharge with its audit switch.
#
# The fixture app carries no Rigor syntax except one `sig/policy.rbs` annotation, whose only job is to
# prove that a written declaration outranks a configured convention.
RSpec.describe "the effects policy configuration" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/policy", __dir__)
  end

  # The canonical policy: one `match:` layer, three `namespace:` layers, an ordered pair over
  # `Ordered::`, an attribution table for two gem-shaped constants, and `telemetry` tolerated.
  def policy(**overrides)
    {
      "labels" => ["acme.cache"],
      "tolerated" => ["telemetry"],
      "attribution" => {
        "Acme::Http.get" => ["io.net.http"],
        "Acme::Cache.fetch" => ["acme.cache"]
      },
      "envelopes" => envelopes
    }.merge(overrides)
  end

  def envelopes
    [
      { "match" => "app/presenters/**/*.rb", "effect" => [] },
      { "namespace" => "Policies::*", "effect" => ["mutate.local"] },
      { "namespace" => "Gateways::*", "effect" => ["io.db"] },
      { "namespace" => "Loggers::*", "effect" => [] },
      { "namespace" => "Ordered::*", "effect" => ["io.fs.read"] },
      { "namespace" => "Ordered::**", "effect" => [] }
    ]
  end

  def configuration(effects)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["app"], "signature_paths" => ["sig"], "libraries" => ["logger"], "effects" => effects
      )
    )
  end

  def run(effects, no_tolerated: false)
    Dir.chdir(fixture) do
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration(effects), cache_store: nil, no_tolerated_effects: no_tolerated
      )
      diagnostics = runner.run(["app"]).diagnostics
      yield(diagnostics, runner)
    end
  end

  def exceeded(effects, no_tolerated: false)
    run(effects, no_tolerated: no_tolerated) do |diagnostics, _runner|
      diagnostics.select { |d| d.rule == "effect.envelope-exceeded" }
                 .map { |d| [d.message[/Method (\S+) performs/, 1], d.message[/performs (\S+) /, 1]] }
                 .sort
    end
  end

  def unknown_labels(effects)
    run(effects) do |diagnostics, _runner|
      diagnostics.select { |d| d.rule == "effect.unknown-label" }.map { |d| [d.path, d.message] }
    end
  end

  describe "envelopes by convention" do
    # The whole judgment in one assertion: exactly these three methods exceed a configured bound, and
    # every other unit in the fixture — the deeper namespace, the annotated override, the loser of the
    # ordered pair, the attributed gateway — stays silent.
    it "fires on exactly the methods whose undischarged labels escape their configured bound" do
      expect(exceeded(policy)).to eq(
        [
          ["Loggers::Audit#announce_and_read", "io.fs.read"],
          ["Policies::Edit#allow?", "io.output.stdout"],
          ["Presenters::User#render", "io.fs.read"]
        ]
      )
    end

    it "names the stanza the bound was written in, positioned at the Ruby def" do
      diagnostic = run(policy) do |diagnostics, _|
        diagnostics.find { |d| d.message.start_with?("Method Presenters::User#render ") }
      end

      expect(diagnostic.message).to eq(
        "Method Presenters::User#render performs io.fs.read (File.read), but is declared effect: [] " \
        "at .rigor.yml effects.envelopes[0], so io.fs.read exceeds the envelope."
      )
      expect([diagnostic.path, diagnostic.line]).to eq(["app/presenters/user_presenter.rb", 14])
    end

    # `namespace: "Policies::*"` is one segment deep. `Policies::Admin::Edit` does the same thing and
    # must not be bound by it.
    it "stops a `*` namespace at the segment boundary" do
      expect(exceeded(policy).map(&:first)).not_to include("Policies::Admin::Edit#allow?")
    end

    # Nearest wins: `sig/policy.rbs` puts `%a{rigor:v1:effect io.fs.read}` on `annotated`, whose body is
    # the same as `render`'s.
    it "lets a per-method annotation override the configured envelope" do
      expect(exceeded(policy).map(&:first)).not_to include("Presenters::User#annotated")
    end

    it "gives the class to the first matching entry, in list order" do
      reversed = policy("envelopes" => envelopes.values_at(0, 1, 2, 3, 5, 4))

      expect(exceeded(policy).map(&:first)).not_to include("Ordered::Thing#touch")
      expect(exceeded(reversed)).to include(["Ordered::Thing#touch", "io.fs.read"])
    end

    # A project that writes no RBS at all is the design's day-one case (§ 6.2), and the surface has to
    # work there: with no signature to scan there is no annotation stratum, and the configured envelopes
    # are the only ones there are.
    it "judges configured envelopes when the project has no signatures to scan" do
      keys = Dir.chdir(fixture) do
        data = Rigor::Configuration::DEFAULTS.merge(
          "paths" => ["app"], "signature_paths" => ["no-such-sig"], "libraries" => ["logger"],
          "effects" => policy
        )
        runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new(data), cache_store: nil)
        runner.run(["app"]).diagnostics
              .select { |d| d.rule == "effect.envelope-exceeded" }
              .map { |d| d.message[/Method (\S+) performs/, 1] }
      end

      # `annotated` joins the list precisely because the annotation that outranked the stanza is gone.
      expect(keys).to contain_exactly(
        "Loggers::Audit#announce_and_read", "Policies::Edit#allow?",
        "Presenters::User#annotated", "Presenters::User#render"
      )
    end
  end

  describe "the attribution table" do
    def row_for(effects, key)
      run(effects) do |_diagnostics, runner|
        Rigor::CLI::EffectsReport.build(runner.effect_table).rows.find { |candidate| candidate.key == key }
      end
    end

    # WD6: a configured attribution is a claim about a body Rigor never read. It lands in the declared
    # lane, the site keeps its `plugin-attribution` cause, and the proven lane stays empty.
    it "colours the caller's declared lane and keeps the taint" do
      row = row_for(policy, "Gateways::Client#fetch")

      expect(row.declared).to eq(["io.net.http"])
      expect(row.effects).to eq([])
      expect(row).not_to be_exhaustive
      expect(row.causes).to include(["plugin-attribution", "Acme::Http.get"])
    end

    # The consequence that matters: an envelope can never fire because of an attribution, whatever the
    # attributed labels are, because diagnostics read the proven lane only.
    it "never enters the proven lane, so an envelope of io.db on it stays silent" do
      expect(exceeded(policy).map(&:first)).not_to include("Gateways::Client#fetch")
    end

    # `≤` is the lane's spelling in the model, so the report writes it rather than folding a claim in
    # among the proven labels.
    it "prints the declared lane apart from the proven one, as a `≤` bound" do
      text = run(policy) do |_diagnostics, runner|
        out = StringIO.new
        Rigor::CLI::EffectsRenderer.new(out: out)
                                   .render(Rigor::CLI::EffectsReport.build(runner.effect_table), format: "text")
        out.string
      end

      expect(text).to include("Gateways::Client#fetch: [] ≤ [io.net.http] …?\n")
    end
  end

  # ADR-103 WD1: "declared labels travel call edges exactly as proven ones do, monotone to the same
  # fixpoint". `Controllers::Orders#create` → `Gateways::Service#place` → `Gateways::Client#fetch` →
  # the attributed `Acme::Http.get`, so the claim has to arrive two hops up.
  describe "the declared lane along call edges" do
    def snapshot_for(effects, reach: ["app/controllers/**/*.rb"])
      merged = effects.merge("snapshot" => { "reach" => reach })
      Dir.chdir(fixture) do
        runner = Rigor::Analysis::Runner.new(configuration: configuration(merged), cache_store: nil)
        runner.run(["app"])
        Rigor::Effects::Snapshot.build(table: runner.effect_table, configuration: configuration(merged),
                                       sources: runner.effect_sources)
      end
    end

    def report_rows(effects)
      run(effects) { |_diagnostics, runner| Rigor::CLI::EffectsReport.build(runner.effect_table).rows }
    end

    it "carries an attributed claim to a caller two hops above it" do
      row = report_rows(policy).find { |candidate| candidate.key == "Controllers::Orders#create" }

      expect(row.declared).to eq(["io.net.http"])
      expect(row.effects).to eq([])
      expect(row).not_to be_exhaustive
    end

    # `methods:` is the DIRECT summary and `reach:` the transitive one, and the declared lane follows
    # each table's own reading — otherwise a `methods:` diff would stop being attributable to the lines
    # that changed.
    it "records the direct claim under methods: and the transitive one under reach:" do
      snapshot = snapshot_for(policy)

      # The controller's own body claims nothing, so its direct summary is empty and `methods:` leaves it
      # out entirely; the method that made the attributed call is where the claim is attributable.
      expect(snapshot.methods).not_to have_key("Controllers::Orders#create")
      expect(snapshot.methods["Gateways::Client#fetch"].declared).to eq(["io.net.http"])
      expect(snapshot.reach["Controllers::Orders#create"].declared).to eq(["io.net.http"])
      expect(snapshot.reach["Controllers::Orders#create"].effects).to eq([])
    end

    # However far it travels, a claim is still a claim: an envelope on the middle hop reads the proven
    # lane and finds nothing there.
    it "never enters the proven lane on the way, so the io.db envelope on the middle hop stays silent" do
      expect(exceeded(policy).map(&:first)).not_to include("Gateways::Service#place")
    end

    # The rendering rule: attributing what the catalogue already proves adds no information, and
    # `[io.fs.read] ≤ [io.fs.read]` reads as two facts where there is one.
    it "drops a declared label the proven lane already admits" do
      redundant = policy("attribution" => policy["attribution"].merge("File.read" => ["io.fs.read"]))
      row = report_rows(redundant).find { |candidate| candidate.key == "Presenters::User#render" }

      expect(row.effects).to eq(["io.fs.read"])
      expect(row.declared).to eq([])
      expect(snapshot_for(redundant).methods["Presenters::User#render"].declared).to eq([])
    end

    it "keeps a declared label no proven label subsumes" do
      row = report_rows(policy).find { |candidate| candidate.key == "Gateways::Client#fetch" }

      expect(row.declared).to eq(["io.net.http"])
    end
  end

  describe "the project vocabulary" do
    it "makes a registered label usable in attribution without a finding" do
      expect(unknown_labels(policy)).to be_empty
      expect(row_for_cache(policy)).to eq(["acme.cache"])
    end

    def row_for_cache(effects)
      run(effects) do |_diagnostics, runner|
        runner.effect_table["Caching::Client#read"].direct.declared.to_a
      end
    end

    # Drop the vocabulary and the same table is a spelling nothing explains. `acme.cache` carries two
    # segments, so label intent is evident and the diagnostic fires (#384's gate).
    it "reports an attributed label the vocabulary does not know" do
      findings = unknown_labels(policy("labels" => []))

      expect(findings.map(&:first)).to eq([".rigor.yml"])
      expect(findings.first.last).to include("acme.cache").and include("effects.attribution.Acme::Cache.fetch")
    end

    it "reports an unrecognised label in an envelope bound, and the entry then bounds nothing" do
      typo = policy("envelopes" => [{ "namespace" => "Ordered::*", "effect" => ["io.bd"] }] + envelopes)

      expect(unknown_labels(typo).first.last)
        .to include("io.bd").and include("effects.envelopes[0].effect")
      expect(exceeded(typo).map(&:first)).not_to include("Ordered::Thing#touch")
    end
  end

  # The heart of the slice: discharge is per ORIGIN. `Logger#info` is one bundle of `io` + `telemetry`,
  # `File.read` is another of `io.fs.read`, and tolerating `telemetry` frees the first and only the first.
  describe "per-origin discharge" do
    it "discharges the whole bundle a tolerated label belongs to" do
      expect(exceeded(policy).map(&:first)).not_to include("Loggers::Audit#announce")
    end

    it "leaves a label that arrived through another origin in the same body" do
      expect(exceeded(policy)).to include(["Loggers::Audit#announce_and_read", "io.fs.read"])
    end

    it "discharges nothing when the policy tolerates nothing" do
      expect(exceeded(policy("tolerated" => []))).to include(
        ["Loggers::Audit#announce", "io"],
        ["Loggers::Audit#announce", "telemetry"],
        ["Loggers::Audit#announce_and_read", "io"]
      )
    end

    # Invariant 3: the policy has to be inspectable, so one flag re-runs the same judgment with an empty
    # tolerated set. It changes the judgment and nothing else.
    it "restores every discharged finding under --no-tolerated-effects" do
      expect(exceeded(policy, no_tolerated: true)).to eq(exceeded(policy("tolerated" => [])))
    end

    it "reads the same table either way — the switch is a judgment, not a collection" do
      run(policy) do |_diagnostics, runner|
        entry = runner.effect_table["Loggers::Audit#announce_and_read"]

        expect(entry.proven.to_a).to eq(%w[io io.fs.read telemetry])
        expect(entry.undischarged.to_a).to eq(["io.fs.read"])
      end
    end
  end
end
