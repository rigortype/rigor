# frozen_string_literal: true

# Issue #1783 — `Integer#step`'s block parameter.
#
# `ruby/rbs` declares every `Numeric#step` overload with a `{ (Numeric) -> void }` block and `Integer` does not
# redeclare `step`, so `1.step(n, 2) { |i| i.even? }` reported `even?` as undefined on Numeric. Every expectation
# below is what CRuby's block form yields: a silent line runs, a reported line raises `NoMethodError` (a Float has
# no `even?`).

require "spec_helper"

RSpec.describe "Integer#step block parameter (#1783)", type: :runner do
  def undefined_rows(source)
    result = analyze(files: { "app.rb" => source })
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }
          .map { |d| [d.line, d.method_name.to_s] }
          .sort
  end

  it "reports nothing on an Integer step, whether the limit is untyped or Integer" do
    expect(undefined_rows(<<~RUBY)).to eq([])
      def go(n) = 1.step(n, 2) { |i| i.even? }
      def literal = 1.step(10, 2) { |i| i.even? }
      def keywords(n) = 1.step(by: 2, to: n) { |i| i.even? }
      def unbounded = 1.step { |i| break if i.even? }
      def limit_only(n) = 1.step(n) { |i| i.even? }
    RUBY
  end

  it "keeps reporting where a Float receiver, step or limit makes the block yield Floats" do
    expect(undefined_rows(<<~RUBY)).to eq([[1, "even?"], [2, "even?"], [3, "even?"], [4, "even?"], [5, "even?"]])
      def float_receiver(n) = 1.0.step(n, 2) { |i| i.even? }
      def float_step(n) = 1.step(n, 0.5) { |i| i.even? }
      def float_step_literal = 1.step(10, 0.5) { |i| i.even? }
      def float_limit = 1.step(10.0) { |i| i.even? }
      def float_by(n) = 1.step(by: 0.5, to: n) { |i| i.even? }
    RUBY
  end
end
