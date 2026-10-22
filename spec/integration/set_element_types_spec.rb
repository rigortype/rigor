# frozen_string_literal: true

# Issue #2278 — a `Set` built from non-constant members names its element type, the way an `Array` literal does,
# and keeps it through `.freeze` / `.dup`. Before, `Set[x]` answered `Set[Dynamic[top]]` and its `.freeze` the bare
# `Set`, so a reader over such a value was skipped by `rigor sig-gen` as `untyped`.
#
# The element is widened off value pins and literal containers and joined with a `Dynamic[top]` floor: nothing widens
# a Set's element on mutation, and a set is mutable (#2177), so a read of it must not report on the built-with classes.
require "spec_helper"

RSpec.describe "Set element types", type: :runner do
  def dumped(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\nx = ARGV.first\nn = ARGV.size\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def errors(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\nx = ARGV.first.to_s\nys = [1, 2].select { |e| e > ARGV.size }\n#{source})).diagnostics
      .select { |d| d.severity == :error }.map(&:qualified_rule)
  end

  it "types Set[...] over non-constant members as the union of their widened classes" do
    expect(dumped("dump_type(Set[x, n])")).to eq(["Set[Dynamic[top] | Integer | String]"])
  end

  it "widens a literal container member to its nominal" do
    expect(dumped("dump_type(Set[[:a, :b]])")).to eq(["Set[Array[Symbol] | Dynamic[top]]"])
  end

  it "types Set.new over an array of non-constant members" do
    expect(dumped("dump_type(Set.new([x]))")).to eq(["Set[Dynamic[top] | String]"])
  end

  it "types Set.new over a nominal Array argument" do
    expect(dumped("dump_type(Set.new(ARGV))")).to eq(["Set[Dynamic[top] | String]"])
  end

  it "keeps the element type through freeze and dup" do
    expect(dumped("dump_type(Set[x].freeze)\ndump_type(Set[x].dup)")).to eq(["Set[Dynamic[top] | String]", "Set[Dynamic[top] | String]"])
  end

  # Positive control: an all-constant Set still folds to its value carrier.
  it "still folds Set[] over constant members" do
    expect(dumped("dump_type(Set[1, 2])\ndump_type(Set.new([1, 2]))")).to eq(["Set[1, 2]", "Set[1, 2]"])
  end

  # Ruby: `Set.new([1, 2], &:to_s).to_a` is `["1", "2"]` and `Set.new([1, 2]) { |v| v * 2 }.to_a` is `[2, 4]`, so the
  # argument's elements are not the set's.
  it "does not fold Set.new with a block to the argument's elements" do
    out = dumped("dump_type(Set.new([1, 2], &:to_s))\ndump_type(Set.new([1, 2]) { |v| v * 2 })")
    expect(out.join).not_to include("Set[1, 2]")
  end

  # `Set[0, *xs]` holds the members of `xs`; reading the splat's array as one more member would add a class the set
  # does not hold. The call stays at the RBS tier's answer.
  it "does not read a splat as one member" do
    expect(dumped("xs = [x, n]\ndump_type(Set[0, *xs])")).to eq(["Set[Dynamic[top]]"])
  end

  # The element is read after a mutation that changes its class. Each is correct Ruby; none may report. The first
  # line is the positive control: a missing method on an Integer still reports.
  describe "a mutated set" do
    {
      "replace" => "s = Set[x]\ns.replace([1])\ns.each { |e| e.fdiv(2) }",
      "clear then <<" => "s = Set.new(ARGV)\ns.clear\ns << 1\ns.each { |e| e.fdiv(2) }",
      "map!" => "s = Set[x]\ns.map! { |e| e.size }\ns.each { |e| e.fdiv(2) }",
      "a callee that fills it" => "def fill(set) = (set.clear; set << 42)\ns = Set[x]\nfill(s)\ns.each { |v| v.fdiv(2) }",
      "tap" => "s = Set[x].tap { |q| q << 1 }\ns.each { |v| v.fdiv(2) }",
      "union" => "s = Set[x] | Set[1]\ns.find { |e| e.is_a?(Integer) }&.fdiv(2)"
    }.each do |label, body|
      it "does not report a read after #{label}" do
        expect(errors("1.upcase\n#{body}")).to eq(%w[call.undefined-method])
      end
    end
  end

  # A nominal Array argument's element carries value pins (`Array[1 | 2]`); the set's must not, or `<< 3` followed by
  # a comparison reads always-falsey.
  it "drops the value pins of a nominal Array argument's element" do
    expect(dumped("ys = [1, 2].select { |e| e > n }\ndump_type(Set.new(ys))")).to eq(["Set[Dynamic[top] | Integer]"])
    expect(errors("s = Set.new(ys)\ns << 3\nputs 1 if s.max == 3")).to eq([])
  end
end
