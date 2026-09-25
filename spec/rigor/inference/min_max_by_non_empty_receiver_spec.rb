# frozen_string_literal: true

require "spec_helper"

# Issue #1333 — `min_by` / `max_by` with a block and no count return `nil` only for an empty receiver, so
# on a receiver the analyzer knows is non-empty (a non-empty Tuple, a non-empty integer Range literal) the
# element union MUST NOT carry `nil`. RBS declares `Elem?`, so `m = [1, 2].min_by { |s| rand(3) }; m + 1`
# reported `call.possible-nil-receiver` on correct code. Each fold is paired with a control whose type
# must NOT move: an empty receiver, a receiver of unknown size, and the count form.
RSpec.describe "min_by / max_by on a non-empty receiver", type: :runner do
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

  it "answers the element union without nil for a non-empty Tuple" do
    expect(dumped_types(<<~RUBY)).to eq(["1 | 2", "1 | 2", "1"])
      dump_type([1, 2].min_by { |s| rand(3) })
      dump_type([1, 2].max_by { |s| rand(3) })
      dump_type([1].max_by { |s| rand(3) })
    RUBY
  end

  it "no longer reports a nil receiver on the result" do
    expect(error_rules(<<~RUBY)).to be_empty
      m = [1, 2].min_by { |s| rand(3) }
      m + 1
      x = [1, 2].max_by { |s| rand(3) }
      x + 1
    RUBY
  end

  it "answers the element range without nil for a non-empty integer Range literal" do
    expect(dumped_types(<<~RUBY)).to eq(["Integer[1..3]", "Integer[1..2]"])
      dump_type((1..3).min_by { |s| rand(3) })
      dump_type((1...3).max_by { |s| rand(3) })
    RUBY
  end

  it "keeps nil for an empty receiver" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]?", "Dynamic[top]?"])
      dump_type([].min_by { |s| s })
      dump_type((1...1).max_by { |s| s })
    RUBY
  end

  it "keeps nil for a receiver of unknown size" do
    expect(dumped_types(<<~RUBY)).to eq(["Integer?", "Integer?"])
      ints = (1..rand(9)).to_a
      dump_type(ints.min_by { |s| s })
      dump_type(ints.max_by { |s| s })
    RUBY
  end

  it "leaves the count form's Array answer alone" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[1 | 2]", "Array[1 | 2]"])
      dump_type([1, 2].min_by(2) { |s| rand(3) })
      dump_type([1, 2].max_by(2) { |s| rand(3) })
    RUBY
  end
end
