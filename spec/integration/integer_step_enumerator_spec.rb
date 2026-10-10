# frozen_string_literal: true

# Issue #1794 — the elements of block-less `Integer#step`'s `Enumerator::ArithmeticSequence`.
#
# `ruby/rbs` declares `Enumerator::ArithmeticSequence < Enumerator[Numeric]`, so `1.step(n, 2).map { |i| i.even? }`
# reported `even?` as undefined on Numeric. Every expectation below is what CRuby's enumerator yields: a silent line
# runs, a reported line raises `NoMethodError` (a Float has no `even?`). Unlike the block form,
# `1.step(Float::INFINITY, 2)`'s sequence yields Floats (`.first(2) #=> [1.0, 3.0]`).

require "spec_helper"

RSpec.describe "Integer#step enumerator elements (#1794)", type: :runner do
  def undefined_rows(source)
    result = analyze(files: { "app.rb" => source })
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }
          .map { |d| [d.line, d.method_name.to_s] }
          .sort
  end

  it "reports nothing on an Integer step's sequence, through the chains that read its elements" do
    expect(undefined_rows(<<~RUBY)).to eq([])
      def go(n) = 1.step(n, 2).map { |i| i.even? }
      def literal = 1.step(10, 2).map { |i| i.even? }
      def keywords(n) = 1.step(by: 2, to: n).select { |i| i.even? }
      def unbounded = 1.step.first(3).map { |i| i.even? }
      def to_a = 1.step(10, 2).to_a.map { |i| i.even? }
      def each = 1.step(10, 2).each { |i| i.even? }
      def slices = 1.step(10, 2).each_slice(2).map { |pair| pair.first.even? }
      def lazy = 1.step(10, 2).lazy.map { |i| i.even? }.to_a
      def first = 1.step(10, 2).first&.even?
      def stored
        seq = 1.step(10, 2)
        seq.each_with_index.map { |i, _| i.even? }
      end
    RUBY
  end

  it "keeps reporting where a Float operand or receiver makes the sequence yield Floats" do
    expect(undefined_rows(<<~RUBY)).to eq([[1, "even?"], [2, "even?"], [3, "even?"], [4, "even?"], [5, "even?"]])
      def float_step = 1.step(10, 0.5).map { |i| i.even? }
      def infinite_limit = 1.step(Float::INFINITY, 2).first(2).map { |i| i.even? }
      def float_limit = 1.step(10.0).to_a.map { |i| i.even? }
      def float_receiver(n) = 1.0.step(n, 2).map { |i| i.even? }
      def float_by(n) = 1.step(by: 0.5, to: n).map { |i| i.even? }
    RUBY
  end
end
