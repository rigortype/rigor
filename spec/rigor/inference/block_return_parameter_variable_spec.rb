# frozen_string_literal: true

require "spec_helper"

# Core RBS declares five overloads whose block-return variable also names a parameter:
# `Enumerable#inject` / `#reduce` (`[A] (A initial) { (A, E) -> A } -> A`), `Enumerable#sum`
# (`[U] (?U) { (E) -> U } -> U`), `Enumerator.produce` (`[T] (T initial) { (T prev) -> T }`) and
# `Hash#transform_keys`, whose own tier answers first. With an argument the result depends on it as well
# as on the block, so a binding read from the block alone is not exact. Each false-positive example here fired on correct code before the binding went gradual; the
# controls keep the exact answers the change must not touch.
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
    expect(dumped_types(result)).to eq(["Dynamic[1 | 2]"])
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
    expect(dumped_types(result)).to eq(["Dynamic[Integer]"])
    expect(rules(result, "call.undefined-method")).to be_empty
  end

  it "keeps Enumerator.produce's element gradual when the initial value differs from the block's" do
    # The first element is the initial value, 1; the block's `"a"` comes after it.
    result = run(<<~RUBY)
      w = Enumerator.produce(1) { "a" }
      dump_type(w)
    RUBY
    expect(dumped_types(result)).to eq(['Enumerator[Dynamic["a"], bot]'])
  end

  describe "controls" do
    it "keeps a block-only generic exact" do
      expect(dumped_types(run("dump_type(Mutex.new.synchronize { 1 })"))).to eq(["1"])
    end

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

    it "keeps an Enumerable#sum without an initial value exact" do
      expect(dumped_types(run("dump_type(ARGV.each.sum { |s| s.to_f })"))).to eq(["Float | Integer"])
    end

    it "keeps the Array#inject fold that joins the seed and the block" do
      expect(dumped_types(run('dump_type([1, 2].inject("s") { |_acc, x| x })'))).to eq(['"s" | 1 | 2'])
    end
  end
end
