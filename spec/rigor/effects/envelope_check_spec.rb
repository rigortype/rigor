# frozen_string_literal: true

require "rigor"
require "rigor/effects/envelope_check"

# ADR-103 #383 — the judgment, over a hand-built table so each rule is isolated from what the collector
# happens to prove. The end-to-end reading is `spec/rigor/effects/envelope_diagnostics_spec.rb`.
RSpec.describe Rigor::Effects::EnvelopeCheck do
  def label_set(names)
    Rigor::Effects::LabelSet.new(names)
  end

  def summary(*labels)
    return Rigor::Effects::Summary.empty if labels.empty?

    Rigor::Effects::Summary.new(
      bundles: { Rigor::Effects::Origin.catalogue("Fixture.call") => label_set(labels) }
    )
  end

  def entry(key, proven: [], direct: nil, exhaustive: true, edges: [])
    Rigor::Effects::EffectTable::Entry.new(
      key: key, direct: direct || summary(*proven), proven: label_set(proven),
      exhaustive: exhaustive, causes: [], edges: edges
    )
  end

  def table(*entries)
    Rigor::Effects::EffectTable.new(entries.to_h { |e| [e.key, e] })
  end

  def envelope(key, *labels, source: :effect_annotation)
    build_envelope(key, bound: label_set(labels), source: source,
                        spelling: "%a{rigor:v1:effect #{labels.join(', ')}}")
  end

  def build_envelope(key, bound:, spelling:, source: :effect_annotation, unknown_labels: [])
    Rigor::Effects::Envelope.build(
      owner_key: key, bound: bound, source: source, location: "sig/demo.rbs:1",
      spelling: spelling, unknown_labels: unknown_labels
    )
  end

  def run(table, methods: {}, classes: {}, **tables)
    described_class.run(
      table: table, method_envelopes: methods, class_envelopes: classes,
      positions: described_class::Positions.build(**tables)
    )
  end

  describe "the comparison" do
    it "fires once per exceeding label, and not for a label the bound subsumes" do
      graph = table(entry("Repo#find", proven: %w[io.db.read io.net.http nondet.time]))
      findings = run(graph, methods: { "Repo#find" => envelope("Repo#find", "io.db") })

      expect(findings.map(&:label)).to eq(%w[io.net.http nondet.time])
    end

    it "tolerates mutate.local under the empty bound" do
      graph = table(entry("Repo#slug", proven: ["mutate.local"]))
      findings = run(graph, methods: { "Repo#slug" => envelope("Repo#slug") })

      expect(findings).to be_empty
    end

    # "As strict as proven": a tainted summary reads "these effects, and possibly more". The possibly is
    # never a finding, but what WAS proven still is.
    it "reads the proven lane regardless of the exhaustiveness bit" do
      graph = table(entry("Repo#find", proven: ["io.net.http"], exhaustive: false))
      findings = run(graph, methods: { "Repo#find" => envelope("Repo#find", "io.db") })

      expect(findings.map(&:label)).to eq(["io.net.http"])
    end

    it "never fires for a ⊤ envelope" do
      graph = table(entry("Repo#find", proven: ["io.net.http"]))
      top = build_envelope("Repo#find", bound: Rigor::Effects::LabelSet::TOP,
                                        spelling: "%a{rigor:v1:effect io.bd}", unknown_labels: ["io.bd"])

      expect(run(graph, methods: { "Repo#find" => top })).to be_empty
    end

    it "ignores an envelope for a method the run collected nothing about" do
      graph = table(entry("Repo#find", proven: []))

      expect(run(graph, methods: { "Repo#missing" => envelope("Repo#missing") })).to be_empty
    end

    # `effects.tolerated:` is a JUDGMENT-time policy for the snapshot's diff (ADR-103 WD7); wiring it
    # into the envelope check is #385's, so a tolerated label is nothing to this pass.
    it "consults no policy list — only the bound and the mutate.local carve-out" do
      graph = table(entry("Repo#find", proven: ["nondet.time"]))
      findings = run(graph, methods: { "Repo#find" => envelope("Repo#find", "io.db") })

      expect(findings.map(&:label)).to eq(["nondet.time"])
    end
  end

  describe "the explanation" do
    it "carries the shortest project path to the origin that proves the label" do
      graph = table(
        entry("Repo#find", proven: ["io.net.http"], direct: summary, edges: ["Repo#fetch"]),
        entry("Repo#fetch", proven: ["io.net.http"], direct: summary("io.net.http"))
      )
      finding = run(graph, methods: { "Repo#find" => envelope("Repo#find", "io.db") }).first

      expect([finding.chain, finding.origin]).to eq([["Repo#find", "Repo#fetch"], "Fixture.call"])
    end
  end

  describe "class-level distribution (ADR-103 WD14)" do
    let(:graph) do
      table(
        entry("Repo#find", proven: ["io.net.http"]),
        entry("Repo.build", proven: ["io.net.http"]),
        entry("Repo#slug", proven: ["io.net.http"]),
        entry("SubRepo#find", proven: ["io.net.http"]),
        entry("Repo::Inner#tick", proven: ["io.net.http"]),
        entry("Other#ping", proven: ["io.net.http"])
      )
    end

    it "reaches every method of that class, instance and singleton alike" do
      findings = run(graph, classes: { "Repo" => envelope("Repo", "io.db", source: :class_annotation) })

      expect(findings.map(&:key)).to eq(["Repo#find", "Repo#slug", "Repo.build"])
    end

    it "does not reach a subclass, a nested class, or an unrelated one" do
      findings = run(graph, classes: { "Repo" => envelope("Repo", "io.db", source: :class_annotation) })

      expect(findings.map(&:key)).not_to include("SubRepo#find", "Repo::Inner#tick", "Other#ping")
    end

    it "lets a per-method envelope win over the distributed one" do
      findings = run(
        graph,
        methods: { "Repo#find" => envelope("Repo#find", "io") },
        classes: { "Repo" => envelope("Repo", "io.db", source: :class_annotation) }
      )

      expect(findings.map(&:key)).to eq(["Repo#slug", "Repo.build"])
    end

    it "rebinds the distributed envelope onto each method it reaches" do
      finding = run(graph, classes: { "Repo" => envelope("Repo", "io.db", source: :class_annotation) }).first

      expect([finding.envelope.owner_key, finding.envelope.source]).to eq(["Repo#find", :class_annotation])
    end
  end

  describe "positioning" do
    let(:graph) { table(entry("Repo#find", proven: ["io.net.http"]), entry("Repo.build", proven: ["io.net.http"])) }
    let(:envelopes) { { "Repo#find" => envelope("Repo#find"), "Repo.build" => envelope("Repo.build") } }

    it "reads the instance and singleton discovery tables by key shape" do
      findings = run(
        graph, methods: envelopes,
               def_sources: { "Repo" => { find: "lib/repo.rb:12" } },
               singleton_def_sources: { "Repo" => { build: "lib/repo.rb:30" } }
      )

      expect(findings.map { |f| [f.path, f.line] }).to eq([["lib/repo.rb", 12], ["lib/repo.rb", 30]])
    end

    it "falls back to the class's own file when the method has no Ruby `def`" do
      findings = run(graph, methods: envelopes, class_sources: { "Repo" => Set["lib/repo.rb"] })

      expect(findings.map { |f| [f.path, f.line] }).to eq([["lib/repo.rb", 1], ["lib/repo.rb", 1]])
    end
  end

  # The tables behind a position are a whole-project discovery parse on the pass side, so both
  # judgments read them through {EnvelopeCheck::DeferredPositions} and must reach `.for` exactly as
  # often as a finding exists — a judged-clean envelope, the common CI case, forces nothing.
  describe "deferred positions" do
    def deferred(&)
      described_class::DeferredPositions.new(&)
    end

    it "never builds the tables when nothing exceeds" do
      forced = false
      graph = table(entry("Repo#find", proven: %w[io.db.read]))

      findings = described_class.run(
        table: graph, method_envelopes: { "Repo#find" => envelope("Repo#find", "io.db") },
        class_envelopes: {},
        positions: deferred do
          forced = true
          described_class::Positions.empty
        end
      )

      expect(findings).to be_empty
      expect(forced).to be(false)
    end

    it "builds them exactly once, on the first finding, and positions every later one from the memo" do
      count = 0
      graph = table(entry("Repo#find", proven: %w[io.net]), entry("Repo#also", proven: %w[io.net]))
      positions = deferred do
        count += 1
        described_class::Positions.build(def_sources: { "Repo" => { find: "lib/repo.rb:3", also: "lib/repo.rb:9" } })
      end

      findings = described_class.run(
        table: graph,
        method_envelopes: { "Repo#find" => envelope("Repo#find", "io.db"),
                            "Repo#also" => envelope("Repo#also", "io.db") },
        class_envelopes: {}, positions: positions
      )

      expect(findings.map { |f| [f.path, f.line] }).to contain_exactly(["lib/repo.rb", 3], ["lib/repo.rb", 9])
      expect(count).to eq(1)
    end

    it "stays unforced through a Liskov judgment whose overrides all honour their inherited bounds" do
      forced = false
      graph = table(entry("Base#find", proven: %w[io.db.read]), entry("Repo#find", proven: %w[io.db.read]))

      findings = Rigor::Effects::LiskovCheck.run(
        table: graph, superclasses: { "Repo" => "Base" },
        method_envelopes: { "Base#find" => envelope("Base#find", "io.db") },
        class_envelopes: {},
        positions: deferred do
          forced = true
          described_class::Positions.empty
        end
      )

      expect(findings).to be_empty
      expect(forced).to be(false)
    end

    it "forces for a Liskov widening — the positive control for the example above" do
      forced = false
      graph = table(entry("Base#find", proven: %w[io.db.read]), entry("Repo#find", proven: %w[io.net]))

      findings = Rigor::Effects::LiskovCheck.run(
        table: graph, superclasses: { "Repo" => "Base" },
        method_envelopes: { "Base#find" => envelope("Base#find", "io.db") },
        class_envelopes: {},
        positions: deferred do
          forced = true
          described_class::Positions.build(def_sources: { "Repo" => { find: "lib/repo.rb:7" } })
        end
      )

      expect(findings.map { |f| [f.path, f.line] }).to eq([["lib/repo.rb", 7]])
      expect(forced).to be(true)
    end
  end
end
