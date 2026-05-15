# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Macro::BlockAsMethod do
  describe "construction" do
    it "stores the declared receiver_constraint, verbs, and self_type" do
      entry = described_class.new(
        receiver_constraint: "Sinatra::Base",
        verbs: %i[get post]
      )

      expect(entry.receiver_constraint).to eq("Sinatra::Base")
      expect(entry.verbs).to eq(%i[get post])
      expect(entry.self_type).to eq(:receiver_instance)
    end

    it "defaults self_type to :receiver_instance" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %i[get])
      expect(entry.self_type).to eq(:receiver_instance)
    end

    it "freezes the entry and its verbs array after construction" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %i[get])
      expect(entry).to be_frozen
      expect(entry.verbs).to be_frozen
      expect(entry.receiver_constraint).to be_frozen
    end

    it "coerces String verb entries to Symbols" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %w[get post])
      expect(entry.verbs).to eq(%i[get post])
    end

    it "is Ractor.shareable? at construction (ADR-15 Phase 1)" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %i[get])
      expect(Ractor.shareable?(entry)).to be(true)
    end

    it "does not mutate the caller's verbs array" do
      verbs = %i[get post]
      described_class.new(receiver_constraint: "Sinatra::Base", verbs: verbs)
      expect(verbs).to eq(%i[get post])
    end
  end

  describe "validation" do
    it "rejects an empty receiver_constraint" do
      expect do
        described_class.new(receiver_constraint: "", verbs: %i[get])
      end.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects a non-String receiver_constraint" do
      expect do
        described_class.new(receiver_constraint: :SinatraBase, verbs: %i[get])
      end.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects an empty verbs array" do
      expect do
        described_class.new(receiver_constraint: "Sinatra::Base", verbs: [])
      end.to raise_error(ArgumentError, /verbs/)
    end

    it "rejects a non-Array verbs argument" do
      expect do
        described_class.new(receiver_constraint: "Sinatra::Base", verbs: :get)
      end.to raise_error(ArgumentError, /verbs/)
    end

    it "rejects verb entries that are not Symbol or non-empty String" do
      expect do
        described_class.new(receiver_constraint: "Sinatra::Base", verbs: [:get, ""])
      end.to raise_error(ArgumentError, /verbs/)

      expect do
        described_class.new(receiver_constraint: "Sinatra::Base", verbs: [:get, 42])
      end.to raise_error(ArgumentError, /verbs/)
    end

    it "rejects self_type values outside the slice-1a set" do
      expect do
        described_class.new(
          receiver_constraint: "Sinatra::Base",
          verbs: %i[get],
          self_type: :dsl_recorder
        )
      end.to raise_error(ArgumentError, /self_type/)
    end
  end

  describe "#to_h" do
    it "renders the entry as a stable Hash for cache-key inclusion" do
      entry = described_class.new(
        receiver_constraint: "Sinatra::Base",
        verbs: %i[get post]
      )

      expect(entry.to_h).to eq(
        "receiver_constraint" => "Sinatra::Base",
        "verbs" => %w[get post],
        "self_type" => "receiver_instance"
      )
    end
  end

  describe "equality" do
    it "treats entries with the same fields as equal" do
      a = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %i[get])
      b = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %i[get])
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when receiver_constraint differs" do
      a = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %i[get])
      b = described_class.new(receiver_constraint: "Sinatra::Application", verbs: %i[get])
      expect(a).not_to eq(b)
    end

    it "differs when verbs differ" do
      a = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %i[get])
      b = described_class.new(receiver_constraint: "Sinatra::Base", verbs: %i[post])
      expect(a).not_to eq(b)
    end
  end
end
