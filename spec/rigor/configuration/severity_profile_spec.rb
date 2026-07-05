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
