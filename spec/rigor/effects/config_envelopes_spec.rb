# frozen_string_literal: true

require "rigor"
require "rigor/effects/config_envelopes"

# ADR-103 WD5 (2) / #385 — the selection and precedence rules of `effects.envelopes:`, isolated from a
# run. The end-to-end reading over a fixture app is `spec/rigor/effects/config_policy_spec.rb`.
RSpec.describe Rigor::Effects::ConfigEnvelopes do
  def registry
    Rigor::Effects::Registry.default
  end

  def entries(*raw)
    described_class.build(entries: raw, registry: registry)
  end

  def entry(effect: [], **selector)
    { "match" => selector[:match], "namespace" => selector[:namespace], "effect" => effect }
  end

  describe "the namespace glob" do
    def matches?(glob, name)
      described_class.namespace_match?(glob, name)
    end

    it "matches an exact constant path and nothing else" do
      expect(matches?("Presenters::User", "Presenters::User")).to be(true)
      expect(matches?("Presenters::User", "Presenters::Users")).to be(false)
      expect(matches?("Presenters::User", "Presenters")).to be(false)
    end

    # The documented depth rule, and the one a reader is most likely to get wrong.
    it "makes `*` match exactly one segment" do
      expect(matches?("Presenters::*", "Presenters::User")).to be(true)
      expect(matches?("Presenters::*", "Presenters::Admin::User")).to be(false)
      expect(matches?("Presenters::*", "Presenters")).to be(false)
    end

    it "makes `**` match one or more segments" do
      expect(matches?("Presenters::**", "Presenters::User")).to be(true)
      expect(matches?("Presenters::**", "Presenters::Admin::User")).to be(true)
      expect(matches?("Presenters::**", "Presenters")).to be(false)
    end

    it "matches within a segment too" do
      expect(matches?("Api::V*", "Api::V2")).to be(true)
      expect(matches?("Api::V*", "Api::Legacy")).to be(false)
    end

    it "does not let `*` cross a namespace boundary" do
      expect(matches?("*", "Presenters::User")).to be(false)
      expect(matches?("*", "Presenters")).to be(true)
    end
  end

  describe "the path glob" do
    it "uses FNM_PATHNAME, so `**` is the only way across a directory boundary" do
      expect(described_class.path_match?("app/presenters/**/*.rb", "app/presenters/admin/user.rb")).to be(true)
      expect(described_class.path_match?("app/presenters/*.rb", "app/presenters/admin/user.rb")).to be(false)
    end
  end

  describe "resolution to classes" do
    def resolve(raw, sources)
      described_class.for_classes(
        entries: entries(*raw), class_names: sources.keys.map { |key| key.split("#").first }.uniq,
        sources: sources, project_root: "/project"
      )
    end

    it "selects a class by any file that defines one of its methods" do
      envelopes = resolve(
        [entry(match: "app/presenters/**/*.rb", effect: [])],
        { "Presenters::User#render" => ["/project/app/presenters/user.rb"],
          "Widgets::Bar#draw" => ["/project/lib/widgets/bar.rb"] }
      )

      expect(envelopes.keys).to eq(["Presenters::User"])
      expect(envelopes["Presenters::User"].bound.to_a).to eq([])
    end

    # A class opened in two places is one class; the layer it belongs to is not decided by which of its
    # reopenings the scanner happened to see first.
    it "selects a class whose reopening matches, not only its first file" do
      envelopes = resolve(
        [entry(match: "app/presenters/**/*.rb", effect: [])],
        { "Presenters::User#render" => ["/project/lib/patch.rb", "/project/app/presenters/user.rb"] }
      )

      expect(envelopes.keys).to eq(["Presenters::User"])
    end

    it "gives the first matching entry the class, in list order" do
      sources = { "Ordered::Thing#touch" => ["/project/app/ordered/thing.rb"] }
      first = resolve([entry(namespace: "Ordered::*", effect: ["io.fs.read"]),
                       entry(namespace: "Ordered::**", effect: [])], sources)
      reversed = resolve([entry(namespace: "Ordered::**", effect: []),
                          entry(namespace: "Ordered::*", effect: ["io.fs.read"])], sources)

      expect(first["Ordered::Thing"].bound.to_a).to eq(["io.fs.read"])
      expect(reversed["Ordered::Thing"].bound.to_a).to eq([])
    end

    it "names the stanza it came from, so the diagnostic can quote it" do
      envelopes = resolve([entry(namespace: "A::*", effect: []), entry(namespace: "B::*", effect: ["io.db"])],
                          { "B::Repo#find" => ["/project/app/b/repo.rb"] })

      expect(envelopes["B::Repo"].location).to eq(".rigor.yml effects.envelopes[1]")
      expect(envelopes["B::Repo"].spelling).to eq("effect: [io.db]")
      expect(envelopes["B::Repo"].source).to eq(:config_envelope)
    end

    # Distribution is what a configured envelope IS, so `rebind` must not restamp it as a class
    # annotation — the message would then say "on Presenters::User" and hide `.rigor.yml`.
    it "keeps its own source when rebound onto a method key" do
      envelope = resolve([entry(namespace: "A::*", effect: [])], { "A::B#c" => ["/project/a.rb"] })["A::B"]

      expect(envelope.rebind("A::B#c").source).to eq(:config_envelope)
      expect(envelope.rebind("A::B#c").owner_key).to eq("A::B#c")
    end
  end

  # The fail-open rule, spelled for the config surface: one unrecognised member and the WHOLE entry
  # bounds nothing, exactly as an annotation carrying one does.
  describe "an unrecognised label" do
    it "makes the entry read ⊤ and records the token" do
      built = entries(entry(namespace: "A::*", effect: %w[io.db io.bd])).first

      expect(built.bound).to be_top
      expect(built.unknown_labels).to eq(["io.bd"])
      expect(built.labels).to eq(%w[io.db io.bd])
    end

    it "leaves a fully recognised entry bounding what it says" do
      built = entries(entry(namespace: "A::*", effect: ["io.db"])).first

      expect(built.bound.to_a).to eq(["io.db"])
      expect(built.unknown_labels).to eq([])
    end
  end
end
