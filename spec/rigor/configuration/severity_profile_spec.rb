# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Configuration::SeverityProfile do
  describe ".resolve" do
    it "returns the authored severity when rule is nil" do
      expect(
        described_class.resolve(rule: nil, authored_severity: :error)
      ).to eq(:error)
    end

    it "returns the profile-defined severity for a known rule" do
      expect(
        described_class.resolve(rule: "dump.type", authored_severity: :error, profile: :balanced)
      ).to eq(:info)
    end

    it "balanced is the default profile" do
      expect(
        described_class.resolve(rule: "dump.type", authored_severity: :error)
      ).to eq(:info)
    end

    it "lenient drops uncertain rules to :warning" do
      expect(
        described_class.resolve(rule: "call.argument-type-mismatch", authored_severity: :error, profile: :lenient)
      ).to eq(:warning)
    end

    it "strict promotes every rule to :error" do
      expect(
        described_class.resolve(rule: "dump.type", authored_severity: :info, profile: :strict)
      ).to eq(:error)
    end

    it "falls back to authored severity for unknown rules" do
      expect(
        described_class.resolve(rule: "unknown.rule", authored_severity: :warning, profile: :balanced)
      ).to eq(:warning)
    end

    it "applies a per-rule override above the profile" do
      expect(
        described_class.resolve(
          rule: "call.undefined-method", authored_severity: :error,
          profile: :balanced, overrides: { "call.undefined-method" => :warning }
        )
      ).to eq(:warning)
    end

    it "applies a family-wildcard override above the profile" do
      expect(
        described_class.resolve(
          rule: "call.undefined-method", authored_severity: :error,
          profile: :balanced, overrides: { "call" => :off }
        )
      ).to eq(:off)
    end

    it "matches a family only through a dot-free key, never through another rule's override" do
      expect(
        described_class.resolve(
          rule: "call.undefined-method", authored_severity: :error,
          profile: :balanced, overrides: { "call.wrong-arity" => :off }
        )
      ).to eq(:error)
      expect(
        described_class.resolve(
          rule: "call.undefined-method", authored_severity: :error,
          profile: :balanced, overrides: { "call.wrong-arity" => :off, "call" => :warning }
        )
      ).to eq(:warning)
    end

    it "per-rule override beats family-wildcard override" do
      expect(
        described_class.resolve(
          rule: "call.undefined-method", authored_severity: :error,
          profile: :strict,
          overrides: {
            "call" => :off,
            "call.undefined-method" => :error
          }
        )
      ).to eq(:error)
    end

    it "treats unknown profile values as the default profile" do
      expect(
        described_class.resolve(rule: "dump.type", authored_severity: :error, profile: :nonsense)
      ).to eq(:info)
    end

    # Issue #1985 — a plugin's row (`plugin_family:` set) answers to its qualified id or `plugin.<id>` only; any other
    # row keeps its bare rule, then its qualified id, then a family wildcard.
    describe "qualified ids" do
      def resolve_plugin_row(overrides, rule: "load-error")
        described_class.resolve(rule: rule, authored_severity: :warning, overrides: overrides,
                                qualified_rule: "plugin.acme.#{rule}", plugin_family: "plugin.acme")
      end

      it "matches a plugin row by its qualified id or its `plugin.<id>`" do
        expect(resolve_plugin_row({ "plugin.acme.load-error" => :off })).to eq(:off)
        expect(resolve_plugin_row({ "plugin.acme" => :info })).to eq(:info)
        expect(resolve_plugin_row({ "plugin.acme" => :info, "plugin.acme.load-error" => :error })).to eq(:error)
      end

      it "does not match a plugin row by its bare rule, a family wildcard or another plugin's id" do
        expect(resolve_plugin_row({ "load-error" => :off })).to eq(:warning)
        expect(resolve_plugin_row({ "unknown" => :off }, rule: "unknown.col")).to eq(:warning)
        expect(resolve_plugin_row({ "plugin.acme2" => :off, "plugin.other.load-error" => :off })).to eq(:warning)
      end

      it "matches a non-plugin row by its bare rule or its qualified id" do
        row = { rule: "load-error", authored_severity: :error, qualified_rule: "plugin_loader.load-error" }
        expect(described_class.resolve(**row, overrides: { "load-error" => :off })).to eq(:off)
        expect(described_class.resolve(**row, overrides: { "plugin_loader.load-error" => :info })).to eq(:info)
        expect(described_class.resolve(**row, overrides: { "plugin_loader.runtime-error" => :off })).to eq(:error)
      end

      it "lets a non-plugin row's qualified key beat its bare key" do
        row = { rule: "load-error", authored_severity: :error, qualified_rule: "plugin_loader.load-error" }
        expect(described_class.resolve(**row, overrides: { "load-error" => :info, "plugin_loader.load-error" => :off }))
          .to eq(:off)
      end

      it "keeps the bleeding-edge overlay beneath a qualified key" do
        row = { rule: "dump.type", authored_severity: :error, qualified_rule: "dump.type" }
        overlay = { "dump.type" => :warning }
        expect(described_class.resolve(**row, bleeding_edge_overrides: overlay)).to eq(:warning)
        expect(described_class.resolve(**row, bleeding_edge_overrides: overlay, overrides: { "dump.type" => :off }))
          .to eq(:off)
      end
    end

    # ADR-50 § WD2 — the bleeding-edge overlay composes below the user's own overrides and above the profile table.
    # Defaults to {} so the shipped (empty) overlay leaves resolution bit-for-bit unchanged.
    describe "bleeding_edge_overrides:" do
      it "defaults to an empty map, leaving resolution unchanged" do
        expect(
          described_class.resolve(rule: "dump.type", authored_severity: :error, profile: :balanced)
        ).to eq(:info)
      end

      it "applies above the profile table when no user override exists" do
        expect(
          described_class.resolve(
            rule: "dump.type", authored_severity: :error, profile: :balanced,
            bleeding_edge_overrides: { "dump.type" => :error }
          )
        ).to eq(:error)
      end

      it "yields to an explicit per-rule user override" do
        expect(
          described_class.resolve(
            rule: "dump.type", authored_severity: :error, profile: :balanced,
            overrides: { "dump.type" => :warning },
            bleeding_edge_overrides: { "dump.type" => :error }
          )
        ).to eq(:warning)
      end

      it "yields to a user family-wildcard override" do
        expect(
          described_class.resolve(
            rule: "dump.type", authored_severity: :error, profile: :balanced,
            overrides: { "dump" => :off },
            bleeding_edge_overrides: { "dump.type" => :error }
          )
        ).to eq(:off)
      end
    end
  end
end
