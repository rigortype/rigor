# frozen_string_literal: true

require "spec_helper"

require "rigor/plugin/fact_store"

RSpec.describe Rigor::Plugin::FactStore do
  let(:store) { described_class.new }

  describe "#publish + #read" do
    it "registers a value under (plugin_id, name)" do
      store.publish(plugin_id: "activerecord", name: :model_index, value: { user: %i[id name] })

      expect(store.read(plugin_id: "activerecord", name: :model_index))
        .to eq(user: %i[id name])
    end

    it "returns nil for an unpublished (plugin_id, name)" do
      expect(store.read(plugin_id: "activerecord", name: :model_index)).to be_nil
    end

    it "canonicalises the plugin_id to String and name to Symbol" do
      store.publish(plugin_id: :activerecord, name: "model_index", value: 42)

      expect(store.read(plugin_id: "activerecord", name: :model_index)).to eq(42)
    end

    it "is idempotent on a duplicate publish with the same value (==)" do
      payload = { user: %i[id name] }

      store.publish(plugin_id: "activerecord", name: :model_index, value: payload)
      expect do
        store.publish(plugin_id: "activerecord", name: :model_index, value: { user: %i[id name] })
      end.not_to raise_error

      expect(store.read(plugin_id: "activerecord", name: :model_index)).to eq(payload)
    end

    it "raises Conflict on a duplicate publish with a different value" do
      store.publish(plugin_id: "activerecord", name: :model_index, value: { user: %i[id name] })

      err = nil
      begin
        store.publish(plugin_id: "activerecord", name: :model_index, value: { user: %i[id email] })
      rescue Rigor::Plugin::FactStore::Conflict => e
        err = e
      end

      expect(err).to be_a(Rigor::Plugin::FactStore::Conflict)
      expect(err.plugin_id).to eq("activerecord")
      expect(err.name).to eq(:model_index)
      expect(err.existing).to eq(user: %i[id name])
      expect(err.incoming).to eq(user: %i[id email])
      expect(err.message).to include("activerecord")
      expect(err.message).to include("model_index")
    end

    it "namespaces by plugin_id (different producers, same name, no conflict)" do
      store.publish(plugin_id: "activerecord", name: :index, value: 1)
      store.publish(plugin_id: "rails-routes", name: :index, value: 2)

      expect(store.read(plugin_id: "activerecord", name: :index)).to eq(1)
      expect(store.read(plugin_id: "rails-routes", name: :index)).to eq(2)
    end
  end

  describe "#published?" do
    it "returns true for a published key" do
      store.publish(plugin_id: "activerecord", name: :model_index, value: 1)
      expect(store.published?(plugin_id: "activerecord", name: :model_index)).to be true
    end

    it "returns false for an unpublished key" do
      expect(store.published?(plugin_id: "activerecord", name: :model_index)).to be false
    end

    it "distinguishes published-as-nil from unpublished" do
      store.publish(plugin_id: "activerecord", name: :model_index, value: nil)
      expect(store.published?(plugin_id: "activerecord", name: :model_index)).to be true
      expect(store.read(plugin_id: "activerecord", name: :model_index)).to be_nil
    end
  end

  describe "#each_fact" do
    it "yields every Fact in publication order" do
      store.publish(plugin_id: "a", name: :one, value: 1)
      store.publish(plugin_id: "b", name: :two, value: 2)
      store.publish(plugin_id: "a", name: :three, value: 3)

      facts = store.each_fact.to_a
      expect(facts.map { |f| [f.plugin_id, f.name, f.value] })
        .to eq([["a", :one, 1], ["b", :two, 2], ["a", :three, 3]])
    end

    it "yields nothing on an empty store" do
      expect(store.each_fact.to_a).to be_empty
    end
  end

  describe "Fact value object" do
    it "is a frozen Data shape" do
      fact = described_class::Fact.new(plugin_id: "x", name: :y, value: 1)
      expect(fact).to be_frozen
      expect(fact.plugin_id).to eq("x")
      expect(fact.name).to eq(:y)
      expect(fact.value).to eq(1)
    end
  end
end
