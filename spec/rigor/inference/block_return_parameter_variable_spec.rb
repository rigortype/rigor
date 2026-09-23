# frozen_string_literal: true

require "spec_helper"

# Core RBS declares five overloads whose block-return variable also names a parameter:
# `Enumerable#inject` / `#reduce` (`[A] (A initial) { (A, E) -> A } -> A`), `Enumerable#sum`
# (`[U] (?U) { (E) -> U } -> U`), `Enumerator.produce` (`[T] (T initial) { (T prev) -> T }`) and
# `Hash#transform_keys`, whose own tier answers first. With an argument the result depends on it as well
# as on the block, so the variable is left `Dynamic[top]` instead of taking the block's type. Each
# false-positive example here fired on correct code while the block alone decided the variable; the ones
# under "one call later" also fired while it was bound to `Dynamic[block_type]`.
RSpec.describe "a block-return type variable that a parameter also names", type: :runner do
  def run(source)
    analyze(<<~RUBY)
      require "rigor/testing"
      include Rigor::Testing
      #{source}
    RUBY
  end

  def dumped_types(result)
    result.diagnostics.filter_map { |d| d.message.delete_prefix("dump_type: ") if d.message.start_with?("dump_type") }
  end

  def rules(result, *names)
    result.diagnostics.map { |d| d.rule.to_s }.select { |rule| names.include?(rule) }
  end

  it "does not fold a comparison against an Enumerable#sum with an initial value" do
    # Runtime: 3.0. The block returns `1 | 2`, and the Float the seed contributes is in neither.
    result = run(<<~RUBY)
      s = [1, 2].each.sum(0.0) { |x| x }
      dump_type(s)
      puts "three" if s == 3.0
    RUBY
    expect(dumped_types(result)).to eq(["Dynamic[top]"])
    expect(rules(result, "flow.always-truthy-condition")).to be_empty
  end

  it "does not pin the size of an Enumerable#sum that concatenates" do
    # Runtime: `[:a, :b]`, where the block alone reads one-element tuples.
    result = run(<<~RUBY)
      h = { a: 1, b: 2 }.sum([]) { |k, _v| [k] }
      puts "two" if h.size == 2
    RUBY
    expect(rules(result, "flow.always-truthy-condition")).to be_empty
  end

  it "does not reject a method the inject seed's class answers" do
    # An empty ARGV returns the seed, 0.0, which answers `nan?`.
    result = run(<<~RUBY)
      e = ARGV.map(&:to_i).each.inject(0.0) { |_acc, x| x }
      dump_type(e)
      puts e.nan?
    RUBY
    expect(dumped_types(result)).to eq(["Dynamic[top]"])
    expect(rules(result, "call.undefined-method")).to be_empty
  end

  it "leaves Enumerator.produce's element untyped when the call passes an initial value" do
    # The first element is the initial value, 1; the block's `"a"` comes after it.
    expect(dumped_types(run('dump_type(Enumerator.produce(1) { "a" })'))).to eq(["Enumerator[Dynamic[top], bot]"])
  end

  describe "one call later" do
    it "does not reject Float#nan? on an average over Hash#sum" do
      # An empty ARGV makes `total` 0.0 and the average NaN.
      result = run(<<~RUBY)
        h = ARGV.to_h { |a| [a, a.size] }
        total = h.sum(0.0) { |_k, v| v }
        avg = total / h.size
        puts avg.nan?
      RUBY
      expect(rules(result, "call.undefined-method")).to be_empty
    end

    it "does not fold a comparison against the seed's first element" do
      # Runtime: `["s", 1, 2]`.
      result = run(<<~RUBY)
        x = [1, 2].each.sum(["s"]) { |i| [i] }
        puts "hit" if x.first == "s"
      RUBY
      expect(rules(result, "flow.always-truthy-condition")).to be_empty
    end

    it "does not fold a predicate the inject seed answers differently" do
      # An empty ARGV returns the seed, 0.0, whose `integer?` is false.
      result = run(<<~RUBY)
        e = ARGV.map(&:to_i).each.inject(0.0) { |_acc, i| i }
        puts "empty" if e.integer? == false
      RUBY
      expect(rules(result, "flow.always-truthy-condition")).to be_empty
    end
  end

  describe "controls" do
    it "keeps a block-only generic exact" do
      expect(dumped_types(run("dump_type(Mutex.new.synchronize { 1 })"))).to eq(["1"])
    end

    it "keeps an Enumerable#sum without an initial value on its parameterless overload" do
      expect(dumped_types(run("dump_type(ARGV.each.sum { |s| s.to_f })"))).to eq(["Float | Integer"])
    end

    # Other tiers answer these ahead of RbsDispatch. They guard against the change rerouting them.
    it "keeps block-only transform_keys on its exact HashShape fold" do
      expect(dumped_types(run("dump_type({ a: 1, b: 2 }.transform_keys { |k| k.to_s })")))
        .to eq(['{ "a": 1, "b": 2 }'])
    end

    it "keeps the mapping-only transform_keys answer" do
      expect(dumped_types(run("dump_type({ a: 1, b: 2 }.transform_keys({ a: :x }))")))
        .to eq(["Hash[:a | :b | :x, 1 | 2]"])
    end

    it "keeps the mapping-and-block transform_keys answer" do
      expect(dumped_types(run("dump_type({ a: 1, b: 2 }.transform_keys({ a: :x }) { |k| k.to_s })")))
        .to eq(['Hash["a" | "b" | :x, 1 | 2]'])
    end

    it "keeps the Array#inject fold that joins the seed and the block" do
      expect(dumped_types(run('dump_type([1, 2].inject("s") { |_acc, x| x })'))).to eq(['"s" | 1 | 2'])
    end
  end
end
