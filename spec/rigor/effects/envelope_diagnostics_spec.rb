# frozen_string_literal: true

require "rigor"
require "rigor/analysis/runner"
require "rigor/analysis/baseline"

# ADR-103 #383 — `effect.envelope-exceeded` end to end over the fixture app in
# `spec/integration/fixtures/effects/envelopes`, whose `sig/envelopes.rbs` carries one envelope per rule
# the check has to implement. The reader's own grammar is `spec/rigor/rbs_extended/envelope_reader_spec.rb`;
# the distribution and comparison rules over a synthetic table are
# `spec/rigor/effects/envelope_check_spec.rb`.
RSpec.describe "effect.envelope-exceeded over the envelopes fixture" do
  def rule
    "effect.envelope-exceeded"
  end

  def fixture
    File.expand_path("../../integration/fixtures/effects/envelopes", __dir__)
  end

  def configuration(effects: {}, **extra)
    data = { "paths" => ["lib"], "signature_paths" => ["sig"] }.merge(extra)
    data["effects"] = effects unless effects == :absent
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  def findings(configuration, cache_store: nil)
    Dir.chdir(fixture) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: cache_store)
      runner.run(["lib"]).diagnostics.select { |d| d.rule == rule }
    end
  end

  def keys(configuration, **)
    findings(configuration, **).map { |d| d.message[/Method (\S+) performs/, 1] }.sort
  end

  # The whole judgment in one assertion: exactly these six methods exceed, and every other unit in the
  # fixture — including the four annotations that must read as ⊤ — stays silent.
  it "fires on exactly the methods whose proven labels escape their bound" do
    expect(keys(configuration)).to eq(
      [
        "Envelopes::Bag#items=",
        "Envelopes::Console#shout",
        "Envelopes::Memo#value",
        "Envelopes::Quiet#conflicted",
        "Envelopes::Tools.stamp",
        "Envelopes::UserRepository#find"
      ]
    )
  end

  describe "the message" do
    def message_for(key)
      findings(configuration).find { |d| d.message.start_with?("Method #{key} ") }&.message
    end

    # The transitive case, and the shape the spec fixes: what it does, the shortest route to whatever
    # proves it, the author's own spelling, and where the bound was written.
    it "names the label, the shortest path to its origin, the spelling and the envelope's source" do
      expect(message_for("Envelopes::UserRepository#find")).to eq(
        "Method Envelopes::UserRepository#find performs io.net.http " \
        "(Net::HTTP.get via Envelopes::Gateway.fetch), but is declared %a{rigor:v1:effect io.db} " \
        "at sig/envelopes.rbs:3, so io.net.http exceeds the envelope."
      )
    end

    it "names the class a distributed envelope came from" do
      expect(message_for("Envelopes::Console#shout")).to include(
        "but is declared %a{rigor:v1:effect io.db} on Envelopes::Console at sig/envelopes.rbs:19"
      )
    end

    it "omits the `via` clause when the method proves the label itself" do
      expect(message_for("Envelopes::Memo#value")).to eq(
        "Method Envelopes::Memo#value performs mutate.self (ivar-write), but is declared %a{pure} " \
        "at sig/envelopes.rbs:15, so mutate.self exceeds the envelope."
      )
    end
  end

  describe "positioning (ADR-103 WD14: the Ruby `def`, not the `.rbs` line)" do
    it "points at the Ruby definition, not the signature" do
      diagnostic = findings(configuration).find { |d| d.message.include?("Envelopes::UserRepository#find") }

      expect(diagnostic.path).to eq("lib/envelopes.rb")
      expect(File.readlines(File.join(fixture, diagnostic.path))[diagnostic.line - 1]).to include("def find")
    end

    # A synthesised `attr_writer` has no `def` to point at; the class's own file is the closest position
    # the discovery tables can offer.
    it "falls back to the class's file for a synthesised accessor" do
      diagnostic = findings(configuration).find { |d| d.message.include?("Envelopes::Bag#items=") }

      expect([diagnostic.path, diagnostic.line]).to eq(["lib/envelopes.rb", 1])
    end
  end

  describe "what does not fire" do
    it "tolerates mutate.local under %a{pure}" do
      expect(keys(configuration)).not_to include("Envelopes::UserRepository#collect")
    end

    it "lets a per-method envelope win over the distributed class-level one" do
      expect(keys(configuration)).not_to include("Envelopes::Console#write")
    end

    it "does not distribute a module's envelope to a class nested inside it" do
      expect(keys(configuration)).not_to include("Envelopes::Tools::Inner#tick")
    end

    it "reads a malformed, empty or unknown-label tag as ⊤ rather than as its recognisable part" do
      expect(keys(configuration)).not_to include(
        "Envelopes::Quiet#malformed", "Envelopes::Quiet#empty", "Envelopes::Quiet#unknown"
      )
    end

    it "leaves an effect-free synthesised reader alone" do
      expect(keys(configuration)).not_to include("Envelopes::Bag#size")
    end
  end

  describe "the gate" do
    it "is silent without an `effects:` block, however many envelopes the RBS carries" do
      expect(findings(configuration(effects: :absent))).to be_empty
    end

    it "is silent under `effects.check: false`, while collection still runs" do
      config = configuration(effects: { "check" => false })

      Dir.chdir(fixture) do
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
        diagnostics = runner.run(["lib"]).diagnostics

        expect(diagnostics.select { |d| d.rule == rule }).to be_empty
        expect(runner.effect_table["Envelopes::Memo#value"].proven.to_a).to eq(["mutate.self"])
      end
    end

    it "defaults to on for a bare block and stays on for an explicit `check: true`" do
      expect(keys(configuration(effects: { "check" => true }))).to eq(keys(configuration))
    end
  end

  describe "the suppression pipeline" do
    around do |example|
      Dir.mktmpdir("rigor-envelope-suppression-") do |dir|
        FileUtils.cp_r(File.join(fixture, "lib"), dir)
        FileUtils.cp_r(File.join(fixture, "sig"), dir)
        Dir.chdir(dir) { example.run }
      end
    end

    def local_findings(extra = {})
      config = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          { "paths" => ["lib"], "signature_paths" => ["sig"], "effects" => {} }.merge(extra)
        )
      )
      Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
                             .run(["lib"]).diagnostics.select { |d| d.rule == rule }
    end

    it "honours a `# rigor:disable` comment on the `def` line" do
      source = File.read("lib/envelopes.rb")
      File.write("lib/envelopes.rb", source.sub("def value", "def value # rigor:disable effect.envelope-exceeded"))

      expect(local_findings.map(&:message).grep(/Envelopes::Memo#value/)).to be_empty
      expect(local_findings.map(&:message).grep(/Envelopes::UserRepository#find/)).not_to be_empty
    end

    it "honours the project `disable:` list" do
      expect(local_findings("disable" => [rule])).to be_empty
    end

    it "is absorbed by a project baseline" do
      diagnostics = local_findings
      baseline = Rigor::Analysis::Baseline.from_diagnostics(diagnostics)
      remaining, absorbed = baseline.filter(diagnostics)

      expect(remaining).to be_empty
      expect(absorbed).to eq(diagnostics.size)
    end
  end

  describe "the run cache (ADR-103 WD12: recomputed every run, never stored)" do
    # The warm path never assembles the run's diagnostics, so a finding that lived in that cached array
    # would vanish; and because the `effects:` block is absent from the diagnostics identity, one that
    # DID live there would outlive an `effects.check: false` edit. Recomputing every run is what makes
    # both impossible.
    it "still emits on a warm effects + diagnostics hit" do
      Dir.mktmpdir("rigor-envelope-cache-root-") do |root|
        store = -> { Rigor::Cache::Store.new(root: root) }
        cold = findings(configuration, cache_store: store.call)
        warm_runner = nil
        warm = Dir.chdir(fixture) do
          warm_runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: store.call)
          warm_runner.run(["lib"]).diagnostics.select { |d| d.rule == rule }
        end

        expect(warm_runner.effects_served_from_cache?).to be(true)
        expect(warm.map(&:message)).to eq(cold.map(&:message))
      end
    end
  end

  # The corpus half of the byte-identical contract every effects slice carries: a project that turns
  # collection on but declares no envelope must see no `effect.*` diagnostic at all.
  describe "a collecting project with no envelopes" do
    it "produces no effect.* diagnostics over the tracer fixture" do
      tracer = File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
      config = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [tracer], "effects" => {})
      )
      diagnostics = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
                                           .run([tracer]).diagnostics

      expect(diagnostics.select { |d| d.rule.to_s.start_with?("effect.") }).to be_empty
    end
  end
end
