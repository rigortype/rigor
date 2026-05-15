# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Macro::TraitRegistry do
  let(:devise_registry) do
    described_class.new(
      receiver_constraint: "ActiveRecord::Base",
      method_name: :devise,
      symbol_arg_position: :rest,
      modules_by_symbol: {
        database_authenticatable: "Devise::Models::DatabaseAuthenticatable",
        recoverable: "Devise::Models::Recoverable"
      },
      always_included: ["Devise::Models::Authenticatable"]
    )
  end

  describe "construction" do
    it "stores the declared fields" do
      r = devise_registry
      expect(r.receiver_constraint).to eq("ActiveRecord::Base")
      expect(r.method_name).to eq(:devise)
      expect(r.symbol_arg_position).to eq(:rest)
      expect(r.modules_by_symbol).to eq(
        database_authenticatable: "Devise::Models::DatabaseAuthenticatable",
        recoverable: "Devise::Models::Recoverable"
      )
      expect(r.always_included).to eq(["Devise::Models::Authenticatable"])
    end

    it "coerces String keys in modules_by_symbol to Symbol" do
      r = described_class.new(
        receiver_constraint: "Foo",
        method_name: :bar,
        modules_by_symbol: { "trait_one" => "Mod::A" }
      )
      expect(r.modules_by_symbol).to eq(trait_one: "Mod::A")
    end

    it "accepts String method_name and coerces to Symbol" do
      r = described_class.new(receiver_constraint: "Foo", method_name: "devise")
      expect(r.method_name).to eq(:devise)
    end

    it "defaults symbol_arg_position to :rest, modules_by_symbol to empty, always_included to empty" do
      r = described_class.new(receiver_constraint: "Foo", method_name: :devise)
      expect(r.symbol_arg_position).to eq(:rest)
      expect(r.modules_by_symbol).to eq({})
      expect(r.always_included).to eq([])
    end

    it "accepts a non-negative Integer for symbol_arg_position" do
      r = described_class.new(receiver_constraint: "Foo", method_name: :bar, symbol_arg_position: 1)
      expect(r.symbol_arg_position).to eq(1)
    end

    it "freezes the registry and its tables after construction" do
      r = devise_registry
      expect(r).to be_frozen
      expect(r.modules_by_symbol).to be_frozen
      expect(r.always_included).to be_frozen
      expect(r.receiver_constraint).to be_frozen
    end

    it "is Ractor.shareable? at construction (ADR-15 Phase 1)" do
      r = devise_registry
      expect(Ractor.shareable?(r)).to be(true)
    end
  end

  describe "validation" do
    it "rejects an empty receiver_constraint" do
      expect do
        described_class.new(receiver_constraint: "", method_name: :devise)
      end.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects a non-Symbol-or-String method_name" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: 42)
      end.to raise_error(ArgumentError, /method_name/)
    end

    it "rejects symbol_arg_position that is neither :rest nor a non-negative Integer" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :devise, symbol_arg_position: -1)
      end.to raise_error(ArgumentError, /symbol_arg_position/)
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :devise, symbol_arg_position: :head)
      end.to raise_error(ArgumentError, /symbol_arg_position/)
    end

    it "rejects a non-Hash modules_by_symbol" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :devise, modules_by_symbol: ["bad"])
      end.to raise_error(ArgumentError, /modules_by_symbol must be a Hash/)
    end

    it "rejects modules_by_symbol values that are not non-empty Strings" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :devise, modules_by_symbol: { x: "" })
      end.to raise_error(ArgumentError, /modules_by_symbol value/)
    end

    it "rejects a non-Array always_included" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :devise, always_included: "Mod::A")
      end.to raise_error(ArgumentError, /always_included must be an Array/)
    end

    it "rejects always_included entries that are not non-empty Strings" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :devise, always_included: [""])
      end.to raise_error(ArgumentError, /always_included entry/)
    end
  end

  describe "#module_for" do
    it "returns the module name for a registered trait symbol" do
      expect(devise_registry.module_for(:database_authenticatable))
        .to eq("Devise::Models::DatabaseAuthenticatable")
    end

    it "accepts a String trait name (coerced to Symbol)" do
      expect(devise_registry.module_for("recoverable")).to eq("Devise::Models::Recoverable")
    end

    it "returns nil for an unregistered trait" do
      expect(devise_registry.module_for(:unknown_strategy)).to be_nil
    end
  end

  describe "#to_h" do
    it "renders a stable Hash for cache-key inclusion" do
      expect(devise_registry.to_h).to eq(
        "receiver_constraint" => "ActiveRecord::Base",
        "method_name" => "devise",
        "symbol_arg_position" => "rest",
        "modules_by_symbol" => {
          "database_authenticatable" => "Devise::Models::DatabaseAuthenticatable",
          "recoverable" => "Devise::Models::Recoverable"
        },
        "always_included" => ["Devise::Models::Authenticatable"]
      )
    end
  end

  describe "equality" do
    it "treats registries with equal fields as equal" do
      a = devise_registry
      b = described_class.new(
        receiver_constraint: "ActiveRecord::Base",
        method_name: :devise,
        symbol_arg_position: :rest,
        modules_by_symbol: {
          database_authenticatable: "Devise::Models::DatabaseAuthenticatable",
          recoverable: "Devise::Models::Recoverable"
        },
        always_included: ["Devise::Models::Authenticatable"]
      )
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when modules_by_symbol differs" do
      a = described_class.new(receiver_constraint: "Foo", method_name: :devise, modules_by_symbol: { a: "A" })
      b = described_class.new(receiver_constraint: "Foo", method_name: :devise, modules_by_symbol: { a: "B" })
      expect(a).not_to eq(b)
    end
  end
end
