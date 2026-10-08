# frozen_string_literal: true

require "spec_helper"
require_relative "../../tool/typing_census"

# ADR-119 WD7(f) — the pure half of the typing census: which pairs the head leaves untyped that the base typed.
RSpec.describe TypingCensus do
  let(:base) { [["C", "foo", 2, 0], ["C", "bar", 1, 1], ["D", "baz", 0, 3]] }
  let(:head) { [["C", "foo", 0, 2], ["C", "bar", 1, 1], ["D", "baz", 1, 2]] }

  it "lists a pair the base typed and the head never does as lost, and the reverse as gained" do
    result = described_class.compare(base, head)

    expect(result[:lost].map { |r| r[:pair] }).to eq([%w[C foo]])
    expect(result[:gained].map { |r| r[:pair] }).to eq([%w[D baz]])
  end

  it "keeps a pair typed at one call site and nil at another out of both lists" do
    result = described_class.compare(base, head)

    expect((result[:lost] + result[:gained]).map { |r| r[:pair] }).not_to include(%w[C bar])
  end

  it "totals the calls and the never-typed pairs of each side" do
    totals = described_class.compare(base, head)[:totals]

    expect(totals[:base]).to eq(pairs: 3, typed_calls: 3, untyped_calls: 4, untyped_only_pairs: 1)
    expect(totals[:head]).to eq(pairs: 3, typed_calls: 2, untyped_calls: 5, untyped_only_pairs: 1)
  end

  it "counts the lost pairs whose class matches a pattern" do
    text = described_class.render(described_class.compare(base, head), /\AC\z/)

    expect(text).to include("matches `\\AC\\z`: 1 of 1")
  end
end
