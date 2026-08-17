# frozen_string_literal: true

require "rigor"
require "rigor/effects/plugin_facts"

# ADR-103 WD2 / WD6 / WD10 / WD14 (#387) — the four manifest fields and the authority rules that decide
# what a plugin's declaration actually buys it.
#
# The rules only bite for a plugin the engine does NOT bundle, so every example here works with a
# manifest carrying a made-up id. `Rigor::Plugin::FirstParty` answers from the filesystem
# (`plugins/rigor-<id>/lib/rigor-<id>.rb`), so an id nobody ships is third-party by construction and no
# stubbing is needed.
RSpec.describe "the plugin effect contract" do
  def manifest(id:, **rest)
    Rigor::Plugin::Manifest.new(id: id, version: "0.1.0", **rest)
  end

  def contribution(manifest, **overrides)
    Rigor::Plugin::Registry::Contribution.new(
      id: manifest.id, owner: manifest.effect_owner, requested_root: manifest.effect_root,
      discharge_allowed: manifest.effect_discharge_allowed?, labels: manifest.effect_labels,
      attributions: manifest.effect_attributions, edges: manifest.effect_edges,
      entry_points: manifest.effect_entry_points, **overrides
    )
  end

  def facts_for(*manifests, superclasses: {})
    Rigor::Effects::PluginFacts.new(
      contributions: manifests.map { |m| contribution(m) }, superclasses: superclasses
    )
  end

  describe "effect_root: and root ownership" do
    it "lets a bundled plugin open the framework root it models" do
      expect(manifest(id: "activerecord", effect_root: "rails").effect_owner).to eq("rails")
    end

    it "keeps a third-party plugin on the root named after itself" do
      expect(manifest(id: "acme-widgets", effect_root: "rails").effect_owner).to eq("acme-widgets")
    end

    it "says so rather than renaming silently" do
      facts = facts_for(manifest(id: "acme-widgets", effect_root: "rails", effect_labels: ["acme-widgets.x"]))

      expect(facts.warnings.join).to include('may not open the effect-label root "rails"')
    end

    # The registry is the one place ownership is enforced, and it refuses the labels rather than the run:
    # one plugin overreaching must not un-name another's vocabulary.
    it "refuses a third-party plugin's labels under a root it does not own" do
      facts = facts_for(manifest(id: "acme-widgets", effect_labels: ["rails.acme"]))
      registry = facts.extend_registry(Rigor::Effects::Registry.default)

      expect(registry.known?("rails.acme")).to be(false)
      expect(facts.warnings.join).to include("were not registered")
    end

    it "registers a bundled plugin's framework labels" do
      facts = facts_for(manifest(id: "activerecord", effect_root: "rails",
                                 effect_labels: ["rails.schema.write"]))
      registry = facts.extend_registry(Rigor::Effects::Registry.default)

      expect(registry.known?("rails.schema.write")).to be(true)
    end
  end

  describe "discharge:" do
    def attribution(discharge:)
      Rigor::Plugin::EffectAttribution.new(
        receiver: "Acme::Client", method: :get, labels: ["io.net"], discharge: discharge,
        why: "spec fixture"
      )
    end

    it "honours a bundled plugin's discharge" do
      facts = facts_for(manifest(id: "activerecord", effect_attributions: [attribution(discharge: true)]))

      expect(facts.class_row("Acme::Client", false, "get")).to be_discharge
      expect(facts.warnings).to be_empty
    end

    it "ignores a third-party plugin's discharge, with a warning" do
      facts = facts_for(manifest(id: "acme-widgets", effect_attributions: [attribution(discharge: true)]))

      expect(facts.class_row("Acme::Client", false, "get")).not_to be_discharge
      expect(facts.warnings.join).to include("does not discharge the call site's taint")
    end

    it "leaves a non-discharging row alone whoever declared it" do
      facts = facts_for(manifest(id: "activerecord", effect_attributions: [attribution(discharge: false)]))

      expect(facts.class_row("Acme::Client", false, "get")).not_to be_discharge
      expect(facts.warnings).to be_empty
    end
  end

  describe "receiver matching" do
    def row(receiver, **rest)
      Rigor::Plugin::EffectAttribution.new(receiver: receiver, method: :call, labels: ["io"],
                                           why: "spec fixture", **rest)
    end

    # The whole reason a plugin row is not a catalogue row: `User.call` must find `Base#call`.
    it "reaches a subclass through the project's superclass table" do
      facts = facts_for(manifest(id: "acme", effect_attributions: [row("Base")]),
                        superclasses: { "Middle" => "Base", "User" => "Middle" })

      expect(facts.class_row("User", false, "call")).not_to be_nil
    end

    it "stops where the project's own class declarations stop" do
      facts = facts_for(manifest(id: "acme", effect_attributions: [row("Base")]))

      expect(facts.class_row("User", false, "call")).to be_nil
    end

    it "survives a cyclic as-written superclass table" do
      facts = facts_for(manifest(id: "acme", effect_attributions: [row("Base")]),
                        superclasses: { "A" => "B", "B" => "A" })

      expect(facts.class_row("A", false, "call")).to be_nil
    end

    it "matches a receiver path exactly" do
      facts = facts_for(manifest(id: "acme", effect_attributions: [row("Rails.cache")]))

      expect(facts.path_row("Rails.cache", "call")).not_to be_nil
      expect(facts.path_row("Rails.other", "call")).to be_nil
    end

    it "scopes a self path to the declared enclosing class" do
      facts = facts_for(manifest(id: "acme", effect_attributions: [row("self.session", within: "Base")]),
                        superclasses: { "User" => "Base" })

      expect(facts.self_path_row("self.session", "call", "User")).not_to be_nil
      expect(facts.self_path_row("self.session", "call", "Unrelated")).to be_nil
    end

    it "rejects a self path with no within: class" do
      expect { row("self.session") }.to raise_error(ArgumentError, /must name a `within:` class/)
    end

    it "matches on_result: through the producing class's ancestry" do
      facts = facts_for(manifest(id: "acme", effect_attributions: [row("Base", on_result: true)]),
                        superclasses: { "User" => "Base" })

      expect(facts.result_row("User", "call")).not_to be_nil
      expect(facts.class_row("User", false, "call")).to be_nil
    end
  end

  describe "value-object validation" do
    it "requires a why: on every attribution" do
      expect { Rigor::Plugin::EffectAttribution.new(receiver: "A", method: :b, labels: ["io"], why: "") }
        .to raise_error(ArgumentError, /needs a `why:` justification/)
    end

    it "requires at least one label" do
      expect { Rigor::Plugin::EffectAttribution.new(receiver: "A", method: :b, labels: [], why: "x") }
        .to raise_error(ArgumentError, /at least one label/)
    end

    it "closes the taint enum a plugin may name" do
      expect do
        Rigor::Plugin::EffectAttribution.new(receiver: "A", method: :b, labels: ["io"], why: "x",
                                             taint: "budget")
      end.to raise_error(ArgumentError, /may only taint with/)
    end

    # The enum IS the enforcement of "no `perform_later` edge" (ADR-103 WD4).
    it "closes the edge-strategy enum" do
      expect { Rigor::Plugin::EffectEdge.new(receiver: "A", target: :perform_later, why: "x") }
        .to raise_error(ArgumentError, /target must be one of/)
      expect(Rigor::Plugin::EffectEdge::TARGETS).not_to include(:perform_later)
    end

    it "rejects a preset with no globs" do
      expect { Rigor::Plugin::EffectEntryPoints.new(name: "x", globs: []) }
        .to raise_error(ArgumentError, /declares no globs/)
    end
  end

  describe "the identity digest" do
    def digest_for(*manifests)
      facts_for(*manifests).digest
    end

    it "is stable for an unchanged plugin table" do
      row = Rigor::Plugin::EffectAttribution.new(receiver: "A", method: :b, labels: ["io"], why: "x")
      expect(digest_for(manifest(id: "acme", effect_attributions: [row])))
        .to eq(digest_for(manifest(id: "acme", effect_attributions: [row])))
    end

    # A plugin upgrade that re-colours a row must invalidate the effects cache slot the same way a
    # re-audited `data/effects/core.yml` row does.
    it "moves when a row's labels move" do
      before = Rigor::Plugin::EffectAttribution.new(receiver: "A", method: :b, labels: ["io"], why: "x")
      after = Rigor::Plugin::EffectAttribution.new(receiver: "A", method: :b, labels: ["io.db.write"],
                                                   why: "x")

      expect(digest_for(manifest(id: "acme", effect_attributions: [before])))
        .not_to eq(digest_for(manifest(id: "acme", effect_attributions: [after])))
    end

    it "moves when a plugin opens a new label" do
      expect(digest_for(manifest(id: "acme", effect_labels: ["acme.a"])))
        .not_to eq(digest_for(manifest(id: "acme", effect_labels: ["acme.b"])))
    end

    it "reaches the effects cache identity" do
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("effects" => {}))
      facts = facts_for(manifest(id: "acme", effect_labels: ["acme.a"]))

      expect(Rigor::Effects::Identity.digest(configuration: configuration, plugin_facts: facts))
        .not_to eq(Rigor::Effects::Identity.digest(configuration: configuration))
    end
  end

  describe "the off path" do
    it "contributes nothing from a manifest that declares nothing" do
      expect(manifest(id: "acme")).not_to be_effects
      expect(Rigor::Effects::PluginFacts.build(nil)).to be_empty
    end
  end
end
