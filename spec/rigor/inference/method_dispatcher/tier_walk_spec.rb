# frozen_string_literal: true

require "spec_helper"

# `MethodDispatcher.first_tier_answer`, the walk behind every tier array (`PRECISE_TIERS_HEAD`, `PRECISE_TIERS_TAIL`,
# `BUNDLED_OVERRIDE_TIERS`, `STUB_TIERS`). The last example is why it is a `while` loop: a `return` out of an `each`
# block allocates one object per answering call on Ruby 4.0.5, and these arrays answer about 170,000 dispatches in
# one `rigor check lib`.
# rubocop:disable RSpec/SpecFilePathFormat
RSpec.describe Rigor::Inference::MethodDispatcher, ".first_tier_answer" do
  # rubocop:enable RSpec/SpecFilePathFormat
  def tier(answer, asked)
    Module.new do
      define_singleton_method(:try_dispatch) do |context|
        asked << context
        answer
      end
    end
  end

  let(:context) { cc(receiver: Rigor::Type::Combinator.nominal_of("String"), method_name: :upcase, args: []) }
  let(:answer) { Rigor::Type::Combinator.nominal_of("Integer") }

  it "answers the first tier that answers and asks none after it" do
    asked = []
    later = []
    tiers = [tier(nil, asked), tier(answer, asked), tier(Rigor::Type::Combinator.untyped, later)]

    expect(described_class.first_tier_answer(tiers, context)).to equal(answer)
    expect(asked).to eq([context, context])
    expect(later).to be_empty
  end

  it "answers nil when every tier declines, having asked each once, and for an empty array" do
    asked = []

    expect(described_class.first_tier_answer([tier(nil, asked), tier(nil, asked)], context)).to be_nil
    expect(asked.size).to eq(2)
    expect(described_class.first_tier_answer([], context)).to be_nil
  end

  describe "allocations" do
    # The counter is the process's, so the least of three windows is the walk's own cost even when another thread
    # allocates during one of them.
    def allocated
      Array.new(3) do
        # Reading the counter may itself allocate; an empty window measures that floor.
        before = GC.stat(:total_allocated_objects)
        floor = GC.stat(:total_allocated_objects) - before
        before = GC.stat(:total_allocated_objects)
        yield
        GC.stat(:total_allocated_objects) - before - floor
      end.min
    end

    # The tiers here allocate nothing themselves, so whatever is counted is the walk's.
    let(:answering) do
      found = answer
      Module.new { define_singleton_method(:try_dispatch) { |_context| found } }
    end
    let(:declining) { Module.new { define_singleton_method(:try_dispatch) { |_context| nil } } }

    it "allocates nothing for a walk a tier answers, nor for one every tier declines" do
      dispatcher = described_class
      site = context
      hit = [declining, answering].freeze
      miss = [declining, declining].freeze
      walk_hit = -> { 100.times { dispatcher.first_tier_answer(hit, site) } }
      walk_miss = -> { 100.times { dispatcher.first_tier_answer(miss, site) } }
      walk_hit.call
      walk_miss.call

      expect(allocated(&walk_hit)).to eq(0)
      expect(allocated(&walk_miss)).to eq(0)
    end
  end
end
