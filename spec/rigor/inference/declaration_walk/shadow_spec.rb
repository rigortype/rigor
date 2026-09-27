# frozen_string_literal: true

require "spec_helper"
require "rigor/inference/declaration_walk/shadow"

# ADR-116 WD5 — the discovery-table half of the `RIGOR_SHADOW_RULE_WALK` harness. Its comparer has to name the
# first difference precisely enough to act on, and it has to be strict where `Hash#==` is lenient: key order,
# frozenness and identity comparison all change what a later merge or seed bundle sees.
RSpec.describe Rigor::Inference::DeclarationWalk::Shadow do
  around do |example|
    saved = ENV.fetch(described_class::ENV_KEY, nil)
    example.run
  ensure
    saved.nil? ? ENV.delete(described_class::ENV_KEY) : ENV.store(described_class::ENV_KEY, saved)
  end

  let(:int) { Rigor::Type::Combinator.nominal_of("Integer") }
  let(:str) { Rigor::Type::Combinator.nominal_of("String") }

  def difference(legacy, walk)
    described_class.first_difference(legacy, walk, "")
  end

  describe ".first_difference" do
    it "finds none between equal tables, types compared by value" do
      legacy = { "C" => { :@@a => int }.freeze }.freeze
      walk = { "C" => { :@@a => Rigor::Type::Combinator.nominal_of("Integer") }.freeze }.freeze
      expect(difference(legacy, walk)).to be_nil
    end

    it "names a key only one side has" do
      expect(difference({ "C" => {}, "D" => {} }, { "C" => {} })).to eq('the table: key "D" only in legacy')
      expect(difference({ "C" => {} }, { "C" => {}, "E" => {} }))
        .to eq('the table: key "E" only in declaration walk')
    end

    it "names the first position where the key order differs" do
      expect(difference({ "A" => 1, "B" => 2 }, { "B" => 2, "A" => 1 }))
        .to eq('the table: key order differs at position 0: legacy "A", declaration walk "B"')
    end

    it "locates a nested value difference and renders types as they describe themselves" do
      expect(difference({ "C" => { :@@a => int } }, { "C" => { :@@a => str } }))
        .to eq('["C"][:@@a]: legacy Integer, declaration walk String')
    end

    it "tells an Array element and length apart" do
      expect(difference({ "C" => %w[a b] }, { "C" => %w[a c] })).to eq('["C"][1]: legacy "b", declaration walk "c"')
      expect(difference({ "C" => %w[a b] }, { "C" => %w[a] }))
        .to eq('["C"]: legacy has 2 elements, declaration walk 1')
    end

    it "compares frozenness and identity comparison" do
      expect(difference({ "C" => {}.freeze }, { "C" => {} }))
        .to eq('["C"]: legacy frozen=true, declaration walk frozen=false')
      expect(difference({}.compare_by_identity, {}))
        .to eq("the table: legacy compare_by_identity=true, declaration walk compare_by_identity=false")
    end

    it "compares classes, not just values" do
      expect(difference({ "C" => 1 }, { "C" => 1.0 })).to eq('["C"]: legacy 1, declaration walk 1.0')
    end
  end

  describe ".verified" do
    it "never builds the legacy table while the variable is unset" do
      ENV.delete(described_class::ENV_KEY)
      built = false
      result = described_class.verified(:class_cvars, "a.rb", { "C" => {} }) { built = true }
      expect(built).to be(false)
      expect(result).to eq({ "C" => {} })
    end

    it "returns the walk's table when the legacy one matches" do
      ENV.store(described_class::ENV_KEY, "1")
      walk = { "C" => { :@@a => int } }
      expect(described_class.verified(:class_cvars, "a.rb", walk) { { "C" => { :@@a => int } } }).to equal(walk)
    end

    it "raises on the first difference, naming the variable, the table, the file and the place" do
      ENV.store(described_class::ENV_KEY, "0")
      expect { described_class.verified(:class_cvars, "app/c.rb", { "C" => {} }) { { "C" => { :@@a => int } } } }
        .to raise_error(described_class::Divergence,
                        "RIGOR_SHADOW_RULE_WALK divergence: discovery table `class_cvars` for app/c.rb: " \
                        '["C"]: key :@@a only in legacy')
    end
  end
end
