# frozen_string_literal: true

require "spec_helper"

# Plain data in, tables out: `Runner::ScopeSeed` fills the Hash it is handed from the project tables passed beside it
# and reads no `Runner` state. `runner_spec.rb` pins the seeded scope through a whole run; the examples here pin each
# table's rule (present only when non-empty, which input wins) on bare Hashes.
RSpec.describe Rigor::Analysis::Runner::ScopeSeed do
  let(:dynamic_prefix) { Rigor::Inference::ScopeIndexer::DYNAMIC_TARGET_PREFIX }

  describe ".seed_mixin_tables" do
    it "writes each of the four tables under its key, and only the non-empty ones" do
      tables = {}

      described_class.seed_mixin_tables(tables, { "A" => ["M"] }, {}, { "A" => ["E"] }, { "A" => [1] })

      expect(tables).to eq(discovered_includes: { "A" => ["M"] }, discovered_extends: { "A" => ["E"] },
                           unpositioned_mixins: { "A" => [1] })
    end

    it "writes nothing when all four are empty" do
      tables = {}

      described_class.seed_mixin_tables(tables, {}, {}, {}, {})

      expect(tables).to eq({})
    end

    it "keeps a table the base seed brought in when this run found none" do
      tables = { discovered_prepends: { "B" => ["P"] } }

      described_class.seed_mixin_tables(tables, {}, {}, {}, {})

      expect(tables).to eq(discovered_prepends: { "B" => ["P"] })
    end
  end

  describe ".seed_def_source_tables" do
    it "leaves the singleton table out when it is empty" do
      tables = {}

      described_class.seed_def_source_tables(tables, { "A#m" => "a.rb:1" }, {})

      expect(tables).to eq(discovered_def_sources: { "A#m" => "a.rb:1" })
    end

    it "seeds the instance and singleton def-source tables, each only when non-empty" do
      both = {}
      described_class.seed_def_source_tables(both, { "A#m" => "a.rb:1" }, { "A.m" => "a.rb:2" })
      only_singleton = {}
      described_class.seed_def_source_tables(only_singleton, {}, { "A.m" => "a.rb:2" })

      expect(both).to eq(discovered_def_sources: { "A#m" => "a.rb:1" },
                         discovered_singleton_def_sources: { "A.m" => "a.rb:2" })
      expect(only_singleton).to eq(discovered_singleton_def_sources: { "A.m" => "a.rb:2" })
    end
  end

  describe ".seed_member_layout_tables" do
    it "seeds the Data and Struct layouts, each only when non-empty" do
      tables = {}

      described_class.seed_member_layout_tables(tables, {}, { "S" => [:a] })

      expect(tables).to eq(struct_member_layouts: { "S" => [:a] })
    end

    it "seeds the Data layouts without a Struct table" do
      tables = {}

      described_class.seed_member_layout_tables(tables, { "D" => [:a] }, {})

      expect(tables).to eq(data_member_layouts: { "D" => [:a] })
    end
  end

  describe ".seed_dependency_attribution_tables" do
    it "seeds the writer, shadower and class-source tables on every run" do
      tables = {}

      described_class.seed_dependency_attribution_tables(tables, { "X" => ["X"] }, { "Y" => ["Y"] },
                                                         { "C" => ["c.rb"] }, false, { "X" => ["a.rb"] })

      expect(tables).to eq(constant_writers: { "X" => ["X"] }, constant_shadowers: { "Y" => ["Y"] },
                           discovered_class_sources: { "C" => ["c.rb"] })
    end

    it "seeds the constant-write map only for a run recording dependencies" do
      recording = {}
      plain = {}

      described_class.seed_dependency_attribution_tables(recording, {}, {}, {}, true, { "X" => ["a.rb"] })
      described_class.seed_dependency_attribution_tables(plain, {}, {}, {}, false, { "X" => ["a.rb"] })

      expect(recording).to eq(constant_sources: { "X" => ["a.rb"] })
      expect(plain).to eq({})
    end

    it "does not seed an empty constant-write map for a recording run" do
      tables = {}

      described_class.seed_dependency_attribution_tables(tables, {}, {}, {}, true, {})

      expect(tables).to eq({})
    end
  end

  describe ".merged_seed_constants" do
    def merged(pre_eval: {}, values: {}, seed: nil, sources: {}, listed: Set.new)
      described_class.merged_seed_constants(pre_eval, values, seed, sources, listed)
    end

    it "answers the literal table when no `pre_eval:` constant is published" do
      expect(merged(values: { "X" => :literal })).to eq("X" => :literal)
    end

    it "answers the very literal table when no `pre_eval:` constant is published, without a copy" do
      values = { "X" => :literal }

      expect(merged(values: values)).to equal(values)
    end

    it "answers the `pre_eval:` publication when the run has no literal table" do
      expect(merged(pre_eval: { "X" => :published })).to eq("X" => :published)
    end

    it "answers the very `pre_eval:` publication when the run has no literal table, without a copy" do
      published = { "X" => :published }

      expect(merged(pre_eval: published)).to equal(published)
    end

    it "lets the literal table win over a `pre_eval:` publication of the same name, and keeps the rest of both" do
      result = merged(pre_eval: { "X" => :published, "Y" => :only_published }, values: { "X" => :literal, "Z" => :z })

      expect(result).to eq("X" => :literal, "Y" => :only_published, "Z" => :z)
      expect(result).to be_frozen
    end

    it "retracts a `pre_eval:` name an unlisted file also assigns" do
      sources = { "X" => ["/p/other.rb"], "Y" => ["/p/listed.rb"] }

      result = merged(pre_eval: { "X" => :a, "Y" => :b }, sources: sources, listed: Set["/p/listed.rb"])

      expect(result).to eq("Y" => :b)
    end

    it "retracts through the wildcard key of the name's last segment" do
      sources = { "#{dynamic_prefix}X" => ["/p/other.rb"] }

      result = merged(pre_eval: { "Outer::X" => :a }, sources: sources, listed: Set["/p/listed.rb"])

      expect(result).to eq({})
    end

    it "keeps a name only listed files write" do
      sources = { "X" => ["/p/listed.rb"] }

      result = merged(pre_eval: { "X" => :a }, sources: sources, listed: Set["/p/listed.rb"])

      expect(result).to eq("X" => :a)
    end

    it "returns the same Hash object when nothing was retracted" do
      published = { "X" => :a }.freeze

      expect(merged(pre_eval: published, sources: { "X" => ["/p/listed.rb"] }, listed: Set["/p/listed.rb"]))
        .to equal(published)
    end

    it "reads the literal table off a `discovery_seed:` when the run computed none (ADR-124)" do
      seed = { in_source_constants: { "X" => :seeded } }

      expect(merged(seed: seed)).to eq("X" => :seeded)
    end

    it "prefers this run's literal table over the seed's" do
      seed = { in_source_constants: { "X" => :seeded } }

      expect(merged(values: { "X" => :own }, seed: seed)).to eq("X" => :own)
    end

    it "reads the retraction's writer census off a `discovery_seed:` when the run computed none" do
      seed = { constant_sources: { "X" => ["/p/other.rb"] } }

      expect(merged(pre_eval: { "X" => :a }, seed: seed, listed: Set["/p/listed.rb"])).to eq({})
    end

    it "prefers this run's writer census over the seed's" do
      seed = { constant_sources: { "X" => ["/p/other.rb"] } }

      result = merged(pre_eval: { "X" => :a }, sources: { "Z" => ["/p/z.rb"] }, seed: seed, listed: Set["/p/z.rb"])

      expect(result).to eq("X" => :a)
    end
  end

  it "keeps the helpers behind `merged_seed_constants` private" do
    expect(described_class).not_to respond_to(:literal_seed_constants, :constant_writer_sources,
                                              :publishable_pre_eval_constants, :unlisted_constant_writer?)
  end
end
