# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Macro::ExternalFile do
  let(:webhook_payload) do
    described_class.new(
      glob: "config/webhooks/*.rb",
      receiver_type: "Redmine::WebhookPayload",
      bound_ivars: {
        "@event" => "Symbol",
        "@issue" => "Issue?",
        "@user" => "User"
      }
    )
  end

  describe "construction" do
    it "stores the declared fields" do
      e = webhook_payload
      expect(e.glob).to eq("config/webhooks/*.rb")
      expect(e.receiver_type).to eq("Redmine::WebhookPayload")
      expect(e.bound_ivars).to eq(
        "@event" => "Symbol",
        "@issue" => "Issue?",
        "@user" => "User"
      )
    end

    it "defaults bound_ivars to an empty Hash" do
      e = described_class.new(glob: "config/foo/*.rb", receiver_type: "Foo")
      expect(e.bound_ivars).to eq({})
    end

    it "freezes the entry and its bound_ivars after construction" do
      e = webhook_payload
      expect(e).to be_frozen
      expect(e.bound_ivars).to be_frozen
      expect(e.glob).to be_frozen
      expect(e.receiver_type).to be_frozen
    end

    it "is Ractor.shareable? at construction (ADR-15 Phase 1)" do
      e = webhook_payload
      expect(Ractor.shareable?(e)).to be(true)
    end

    it "does not mutate the caller's bound_ivars Hash" do
      ivars = { "@event" => "Symbol" }
      described_class.new(glob: "g", receiver_type: "R", bound_ivars: ivars)
      expect(ivars).to eq("@event" => "Symbol")
    end
  end

  describe "validation" do
    it "rejects an empty glob" do
      expect do
        described_class.new(glob: "", receiver_type: "Foo")
      end.to raise_error(ArgumentError, /glob/)
    end

    it "rejects a non-String glob" do
      expect do
        described_class.new(glob: :"config/*.rb", receiver_type: "Foo")
      end.to raise_error(ArgumentError, /glob/)
    end

    it "rejects an empty receiver_type" do
      expect do
        described_class.new(glob: "g", receiver_type: "")
      end.to raise_error(ArgumentError, /receiver_type/)
    end

    it "rejects a non-Hash bound_ivars" do
      expect do
        described_class.new(glob: "g", receiver_type: "R", bound_ivars: ["@event"])
      end.to raise_error(ArgumentError, /bound_ivars must be a Hash/)
    end

    it "rejects bound_ivars keys that do not start with @" do
      expect do
        described_class.new(glob: "g", receiver_type: "R", bound_ivars: { "event" => "Symbol" })
      end.to raise_error(ArgumentError, /bound_ivars key/)
    end

    it "rejects bound_ivars keys that are just `@`" do
      expect do
        described_class.new(glob: "g", receiver_type: "R", bound_ivars: { "@" => "Symbol" })
      end.to raise_error(ArgumentError, /bound_ivars key/)
    end

    it "rejects bound_ivars values that are not non-empty Strings" do
      expect do
        described_class.new(glob: "g", receiver_type: "R", bound_ivars: { "@event" => "" })
      end.to raise_error(ArgumentError, /bound_ivars value/)
      expect do
        described_class.new(glob: "g", receiver_type: "R", bound_ivars: { "@event" => :Symbol })
      end.to raise_error(ArgumentError, /bound_ivars value/)
    end
  end

  describe "#to_h" do
    it "renders a stable Hash for cache-key inclusion" do
      expect(webhook_payload.to_h).to eq(
        "glob" => "config/webhooks/*.rb",
        "receiver_type" => "Redmine::WebhookPayload",
        "bound_ivars" => {
          "@event" => "Symbol",
          "@issue" => "Issue?",
          "@user" => "User"
        }
      )
    end
  end

  describe "equality" do
    it "treats entries with equal fields as equal" do
      a = webhook_payload
      b = described_class.new(
        glob: "config/webhooks/*.rb",
        receiver_type: "Redmine::WebhookPayload",
        bound_ivars: {
          "@event" => "Symbol",
          "@issue" => "Issue?",
          "@user" => "User"
        }
      )
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when glob differs" do
      a = described_class.new(glob: "a/*.rb", receiver_type: "R")
      b = described_class.new(glob: "b/*.rb", receiver_type: "R")
      expect(a).not_to eq(b)
    end

    it "differs when bound_ivars differs" do
      a = described_class.new(glob: "g", receiver_type: "R", bound_ivars: { "@x" => "Foo" })
      b = described_class.new(glob: "g", receiver_type: "R", bound_ivars: { "@x" => "Bar" })
      expect(a).not_to eq(b)
    end
  end
end
