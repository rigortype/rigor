# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1507 — `ScopeIndexer.merge_def_nestings` layers a file's def-nesting table over the cross-file seed by
# lookup instead of copying the seed once per analysed file. No diagnostic assertion can tell the two apart while
# the layering holds, so these examples pin the lookup itself: the file layer first, the seed behind it, `empty?`
# over both, and the early returns that hand back one table untouched.
RSpec.describe Rigor::Inference::ScopeIndexer::LayeredDefNestings do
  def identity_table(pairs)
    pairs.each_with_object({}.compare_by_identity) { |(key, value), table| table[key] = value }.freeze
  end

  def parse(source)
    Prism.parse(source).value
  end

  let(:file_only) { Object.new }
  let(:seed_only) { Object.new }
  let(:shared) { Object.new }
  let(:file) { identity_table([[file_only, %w[File]], [shared, %w[FromFile]]]) }
  let(:seed) { identity_table([[seed_only, %w[Seed]], [shared, %w[FromSeed]]]) }
  let(:empty) { {}.compare_by_identity.freeze }

  describe "#[]" do
    subject(:layered) { described_class.new(file, seed) }

    it "answers a key only the file records from the file layer" do
      expect(layered[file_only]).to eq(%w[File])
    end

    it "falls back to the seed for a key the file does not record" do
      expect(layered[seed_only]).to eq(%w[Seed])
    end

    # The later `merge!(file)` of the copy this replaces won a shared key. Node identity keeps the two layers'
    # keys apart in practice; the order is pinned so the answer cannot depend on that.
    it "answers a key both layers record from the file layer" do
      expect(layered[shared]).to eq(%w[FromFile])
    end

    it "answers nil for a key neither layer records" do
      expect(layered[Object.new]).to be_nil
    end

    # Issue #716 — `[]` is a recorded top-level chain, not "not recorded", so presence in the file layer decides.
    it "keeps a file's empty chain rather than falling through to the seed" do
      layered = described_class.new(identity_table([[shared, []]]), seed)

      expect(layered[shared]).to eq([])
    end

    it "is frozen" do
      expect(layered).to be_frozen
    end
  end

  describe "#empty?" do
    it "is false while either layer records something" do
      expect([described_class.new(file, empty), described_class.new(empty, seed), described_class.new(file, seed)]
               .map(&:empty?)).to eq([false, false, false])
    end

    it "is true only when both layers are empty" do
      expect(described_class.new(empty, empty)).to be_empty
    end
  end

  describe "ScopeIndexer.merge_def_nestings" do
    def merge(seed_table, file_table)
      Rigor::Inference::ScopeIndexer.merge_def_nestings(seed_table, file_table)
    end

    it "hands back the seed itself when the file records nothing" do
      expect(merge(seed, empty)).to be(seed)
    end

    it "hands back the file table itself when the seed is empty" do
      expect(merge(empty, file)).to be(file)
    end

    it "layers the file over the seed when both record something" do
      merged = merge(seed, file)

      expect(merged).to be_a(described_class)
      expect([merged[file_only], merged[seed_only], merged[shared]]).to eq([%w[File], %w[Seed], %w[FromFile]])
      expect(merged).not_to be_empty
    end
  end

  # End to end through `ScopeIndexer.index`: the analysed file's scope answers both its own `def` and one the
  # cross-file seed recorded from another file, by node identity.
  describe "the indexed scope's discovery" do
    let(:seed_program) { parse("module Lib\n  def helper; end\nend\n") }
    let(:program) { parse("module App\n  class Widget\n    def render; end\n  end\nend\n") }

    def seeded_scope(nestings)
      scope = Rigor::Scope.empty
      scope.with_discovery(scope.discovery.with(discovered_def_nestings: nestings))
    end

    def first_def(root)
      root.breadth_first_search { |node| node.is_a?(Prism::DefNode) }
    end

    it "answers the file's own def and the seed's def" do
      seed_table = Rigor::Inference::ScopeIndexer.build_def_nestings(seed_program)
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: seeded_scope(seed_table))
      nestings = index[program].discovery.discovered_def_nestings

      expect([nestings[first_def(program)], nestings[first_def(seed_program)]])
        .to eq([%w[App::Widget App], %w[Lib]])
      expect(nestings[first_def(parse("module Lib\n  def helper; end\nend\n"))]).to be_nil
    end
  end
end
