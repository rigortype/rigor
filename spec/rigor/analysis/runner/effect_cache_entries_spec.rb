# frozen_string_literal: true

require "spec_helper"

# Plain data in, answers out: `Runner::EffectCacheEntries` is handed a cache store and reads and writes only through it,
# so a fake store with `peek_validated` and `fetch_or_validate` stands for the cache. The runner's effects specs pin
# the serve and store sequences end to end; the examples here pin the entry shapes the warm lanes accept (#482).
RSpec.describe Rigor::Analysis::Runner::EffectCacheEntries do
  let(:key) { Rigor::Analysis::RunCacheKey }
  let(:descriptor) { Rigor::Cache::Descriptor.new }
  let(:table) { Rigor::Effects::EffectTable.new({}) }

  let(:store_class) do
    Struct.new(:answers, :fetches) do
      def peek_validated(producer_id:, **)
        raise answers[producer_id] if answers[producer_id].is_a?(Class)

        answers[producer_id]
      end

      def fetch_or_validate(**kwargs, &block)
        fetches << [kwargs, block.call]
        :written
      end
    end
  end

  def store(answers = {})
    store_class.new(answers, [])
  end

  describe ".peek_effect_summary" do
    it "answers the stored `[table, sources, ancestry]` triple" do
      triple = [table, {}, {}]

      expect(described_class.peek_effect_summary(store(key::RUN_EFFECTS_TABLE_PRODUCER_ID => triple), descriptor))
        .to equal(triple)
    end

    it "reads the summary producer's entry, not the collections one" do
      stored = store(key::RUN_EFFECTS_PRODUCER_ID => [table, {}, {}])

      expect(described_class.peek_effect_summary(stored, descriptor)).to be_nil
    end

    it "answers nil for a miss, a wrong arity and a wrong member type" do
      [nil, [table, {}], [{}, {}, {}], [table, [], {}], [table, {}, []], :not_an_array].each do |bad|
        expect(described_class.peek_effect_summary(store(key::RUN_EFFECTS_TABLE_PRODUCER_ID => bad), descriptor))
          .to be_nil
      end
    end

    it "answers nil rather than raise when the store does" do
      stored = store(key::RUN_EFFECTS_TABLE_PRODUCER_ID => RuntimeError)

      expect(described_class.peek_effect_summary(stored, descriptor)).to be_nil
    end
  end

  describe ".peek_effect_collections" do
    it "answers the first member of the stored array" do
      collections = { "a.rb" => :collection }

      expect(described_class.peek_effect_collections(store(key::RUN_EFFECTS_PRODUCER_ID => [collections]), descriptor))
        .to equal(collections)
    end

    it "still reads an entry from before the split, `[collections, table]`" do
      collections = { "a.rb" => :collection }
      stored = store(key::RUN_EFFECTS_PRODUCER_ID => [collections, table])

      expect(described_class.peek_effect_collections(stored, descriptor)).to equal(collections)
    end

    it "answers nil for a miss and for a first member that is not a Hash" do
      [nil, [], [[]], :not_an_array].each do |bad|
        expect(described_class.peek_effect_collections(store(key::RUN_EFFECTS_PRODUCER_ID => bad), descriptor))
          .to be_nil
      end
    end

    it "answers nil rather than raise when the store does" do
      expect(described_class.peek_effect_collections(store(key::RUN_EFFECTS_PRODUCER_ID => RuntimeError), descriptor))
        .to be_nil
    end
  end

  describe ".write_effect_entry" do
    it "stores `[payload, dependencies]` under the producer and descriptor, capped at the effects generation cap" do
      stored = store
      dependencies = Rigor::Cache::Descriptor.new

      result = described_class.write_effect_entry(stored, "analysis.x", descriptor, [:payload], dependencies)

      expect(result).to eq(:written)
      kwargs, value = stored.fetches.fetch(0)
      expect(kwargs).to eq(producer_id: "analysis.x", key_descriptor: descriptor,
                           generation_cap: key::EFFECTS_GENERATION_CAP)
      expect(value).to eq([[:payload], dependencies])
    end
  end

  describe ".storable_effect_table" do
    let(:collection_with) { Struct.new(:summaries) }

    it "answers nil without a table" do
      expect(described_class.storable_effect_table(nil, {})).to be_nil
    end

    it "answers the table when it has rows" do
      filled = instance_double(Rigor::Effects::EffectTable, empty?: false)

      expect(described_class.storable_effect_table(filled, { "a.rb" => collection_with.new([1]) })).to equal(filled)
    end

    it "answers nil for an empty table over non-empty summaries (the fail-soft answer, never a result)" do
      expect(described_class.storable_effect_table(table, { "a.rb" => collection_with.new([1]) })).to be_nil
    end

    it "answers an empty table when no collection has a summary" do
      expect(described_class.storable_effect_table(table, { "a.rb" => collection_with.new([]) })).to equal(table)
    end
  end
end
