# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Macro::BlockAsMethod do
  describe "construction" do
    it "stores the declared receiver_constraint, method_names, and self_type" do
      entry = described_class.new(
        receiver_constraint: "Sinatra::Base",
        method_names: %i[get post]
      )

      expect(entry.receiver_constraint).to eq("Sinatra::Base")
      expect(entry.method_names).to eq(%i[get post])
      expect(entry.self_type).to eq(:receiver_instance)
    end

    it "defaults self_type to :receiver_instance" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      expect(entry.self_type).to eq(:receiver_instance)
    end

    it "freezes the entry and its method_names array after construction" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      expect(entry).to be_frozen
      expect(entry.method_names).to be_frozen
      expect(entry.receiver_constraint).to be_frozen
    end

    it "coerces String verb entries to Symbols" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %w[get post])
      expect(entry.method_names).to eq(%i[get post])
    end

    it "is Ractor.shareable? at construction (ADR-15 Phase 1)" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      expect(Ractor.shareable?(entry)).to be(true)
    end

    it "does not mutate the caller's method_names array" do
      method_names = %i[get post]
      described_class.new(receiver_constraint: "Sinatra::Base", method_names: method_names)
      expect(method_names).to eq(%i[get post])
    end
  end

  describe "validation" do
    it "rejects an empty receiver_constraint" do
      expect do
        described_class.new(receiver_constraint: "", method_names: %i[get])
      end.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects a non-String receiver_constraint" do
      expect do
        described_class.new(receiver_constraint: :SinatraBase, method_names: %i[get])
      end.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects an empty method_names array" do
      expect do
        described_class.new(receiver_constraint: "Sinatra::Base", method_names: [])
      end.to raise_error(ArgumentError, /method_names/)
    end

    it "rejects a non-Array method_names argument" do
      expect do
        described_class.new(receiver_constraint: "Sinatra::Base", method_names: :get)
      end.to raise_error(ArgumentError, /method_names/)
    end

    it "rejects verb entries that are not Symbol or non-empty String" do
      expect do
        described_class.new(receiver_constraint: "Sinatra::Base", method_names: [:get, ""])
      end.to raise_error(ArgumentError, /method_names/)

      expect do
        described_class.new(receiver_constraint: "Sinatra::Base", method_names: [:get, 42])
      end.to raise_error(ArgumentError, /method_names/)
    end

    it "rejects self_type values outside the accepted set" do
      expect do
        described_class.new(
          receiver_constraint: "Sinatra::Base",
          method_names: %i[get],
          self_type: :dsl_recorder
        )
      end.to raise_error(ArgumentError, /self_type/)
    end

    it "accepts a named instance-binding self_type (#1099)" do
      entry = described_class.new(
        receiver_constraint: "Grape::API",
        method_names: %i[params],
        self_type: "Grape::Validations::ParamsScope"
      )

      expect(entry.self_type).to eq("Grape::Validations::ParamsScope")
      expect(entry.self_type_name).to eq("Grape::Validations::ParamsScope")
      expect(entry.named_instance_binding?).to be(true)
      expect(entry.singleton_binding?).to be(false)
      expect(entry.self_type).to be_frozen
      expect(Ractor.shareable?(entry)).to be(true)
    end

    it "accepts a singleton-binding self_type (#1099)" do
      entry = described_class.new(
        receiver_constraint: "Grape::API",
        method_names: %i[namespace],
        self_type: "singleton(Grape::API::Instance)"
      )

      expect(entry.singleton_binding?).to be(true)
      expect(entry.named_instance_binding?).to be(false)
      expect(entry.self_type_name).to eq("Grape::API::Instance")
    end

    it "rejects malformed self_type Strings" do
      ["foo::Bar", "singleton()", "singleton(Foo", "Foo Bar", ""].each do |bad|
        expect do
          described_class.new(
            receiver_constraint: "Sinatra::Base",
            method_names: %i[get],
            self_type: bad
          )
        end.to raise_error(ArgumentError, /self_type/)
      end
    end
  end

  describe "#to_h" do
    it "renders the entry as a stable Hash for cache-key inclusion" do
      entry = described_class.new(
        receiver_constraint: "Sinatra::Base",
        method_names: %i[get post]
      )

      expect(entry.to_h).to eq(
        "receiver_constraint" => "Sinatra::Base",
        "method_names" => %w[get post],
        "self_type" => "receiver_instance",
        "refinements" => []
      )
    end

    it "renders refinements and a :lexical self_type" do
      entry = described_class.new(
        receiver_constraint: "ActiveRecord::Relation", method_names: %i[where],
        self_type: :lexical, refinements: %w[ActiveRecord::Refined::BlockSyntax Other]
      )

      expect(entry.to_h).to include(
        "self_type" => "lexical", "refinements" => %w[ActiveRecord::Refined::BlockSyntax Other]
      )
    end
  end

  # Issue #1667 (ADR-121 WD5) — the modules a matched call runs its block under, via `Proc#refined`.
  describe "refinements" do
    it "defaults to an empty frozen list" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      expect(entry.refinements).to eq([])
      expect(entry.refinements).to be_frozen
    end

    it "keeps the declared order, frozen and Ractor-shareable, without aliasing the caller's array" do
      names = +"SymSyntax"
      declared = [names, "Other::Syntax"]
      entry = described_class.new(receiver_constraint: "Object", method_names: %i[build], refinements: declared)
      names << "X"
      declared << "Third"

      expect(entry.refinements).to eq(%w[SymSyntax Other::Syntax])
      expect(entry.refinements).to all(be_frozen)
      expect(Ractor.shareable?(entry)).to be(true)
    end

    [nil, "SymSyntax", [:SymSyntax], [""], ["sym_syntax"], ["Sym Syntax"]].each do |bad|
      it "rejects #{bad.inspect}" do
        expect do
          described_class.new(receiver_constraint: "Object", method_names: %i[build], refinements: bad)
        end.to raise_error(ArgumentError, /refinements/)
      end
    end
  end

  describe "self_type: :lexical" do
    it "is accepted and keeps the caller's self" do
      entry = described_class.new(receiver_constraint: "Object", method_names: %i[run], self_type: :lexical)
      expect(entry.lexical_self?).to be(true)
      expect(entry.self_type_name).to be_nil
      expect(entry.matches_instance_receivers?).to be(true)
    end

    it "is the only Symbol self_type that matches instance receivers" do
      entry = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      expect(entry.lexical_self?).to be(false)
      expect(entry.matches_instance_receivers?).to be(false)
    end
  end

  describe "equality" do
    it "treats entries with the same fields as equal" do
      a = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      b = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when receiver_constraint differs" do
      a = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      b = described_class.new(receiver_constraint: "Sinatra::Application", method_names: %i[get])
      expect(a).not_to eq(b)
    end

    it "differs when method_names differ" do
      a = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
      b = described_class.new(receiver_constraint: "Sinatra::Base", method_names: %i[post])
      expect(a).not_to eq(b)
    end

    it "differs when refinements differ, in content or order" do
      base = { receiver_constraint: "Object", method_names: %i[build] }
      a = described_class.new(**base, refinements: %w[A B])
      expect(a).not_to eq(described_class.new(**base, refinements: %w[B A]))
      expect(a).not_to eq(described_class.new(**base))
      expect(a).to eq(described_class.new(**base, refinements: %w[A B]))
      expect(a.hash).to eq(described_class.new(**base, refinements: %w[A B]).hash)
    end
  end
end
