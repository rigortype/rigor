# frozen_string_literal: true

require "spec_helper"

# Issue #1393 — a `nil` count on `min` / `max` / `min_by` / `max_by` is the no-count call in Ruby
# (`[1, 2].min_by(nil) { |s| s }` is `1`), but the RBS declares no `nil` arm, so the selector fell back to the
# blockless Enumerator arm. Each case is paired with a control whose type must not move: an Integer count and
# a blockless `min_by(nil)`.
RSpec.describe "min / max / min_by / max_by with a nil count", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def error_rules(source)
    analyze(source).diagnostics.filter_map do |diagnostic|
      diagnostic.qualified_rule if diagnostic.severity == :error
    end
  end

  it "answers the element for a literal nil count with a block, as the no-count form does" do
    expect(dumped_types(<<~RUBY)).to eq(["1 | 2", "1 | 2", "1 | 2"])
      dump_type([1, 2].min_by(nil) { |s| s })
      dump_type([1, 2].max_by(nil) { |s| s })
      dump_type([1, 2].min_by { |s| s })
    RUBY
  end

  it "answers the element for a nil count on min / max" do
    expect(dumped_types(<<~RUBY)).to eq(%w[1 2])
      dump_type([1, 2].min(nil))
      dump_type([1, 2].max(nil))
    RUBY
  end

  it "keeps nil for an unknown-size receiver" do
    expect(dumped_types(<<~RUBY)).to eq(["Integer?"])
      ints = (1..rand(9)).to_a
      dump_type(ints.min_by(nil) { |s| s })
    RUBY
  end

  it "unions the element and Array forms for a count that may be nil, never an Enumerator" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[Integer] | Integer | nil"])
      xs = (1..rand(9)).to_a
      limit = rand < 0.5 ? nil : 2
      dump_type(xs.min_by(limit) { |s| s })
    RUBY
  end

  it "reports no undefined method on the result of a maybe-nil count" do
    expect(error_rules(<<~RUBY)).not_to include("call.undefined-method")
      xs = (1..rand(9)).to_a
      limit = rand < 0.5 ? nil : 2
      xs.min_by(limit) { |s| s }.succ
    RUBY
  end

  it "leaves an Integer count an Array and a blockless nil count an Enumerator" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[1 | 2]", "Enumerator[1 | 2, 1 | 2 | nil]"])
      dump_type([1, 2].min_by(1) { |s| s })
      dump_type([1, 2].min_by(nil))
    RUBY
  end
end
