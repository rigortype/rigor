# frozen_string_literal: true

require "spec_helper"

# Issue #1121 — `Enumerator::Lazy` reassigns most of `Enumerable` so the call chains another lazy
# enumerator, but upstream `ruby/rbs` declares none of those rewrites on the class. Dispatch therefore
# walked up to `Enumerable` and adopted its EAGER return type on the first chained call: the receiver
# class was lost (`Array[Dynamic[top]]`) and the terminal `force` / `eager` reported
# `call.undefined-method` on correct code. See `data/core_overlay/enumerator.rbs` for the rewrites and
# `docs/internal-spec/inference-engine.md` § generic dispatch for the partial-application binding that
# keeps the element type.
RSpec.describe "Enumerator::Lazy chained calls", type: :runner do
  def analyzed(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
  end

  def dumped_type(expression)
    analyzed("dump_type(#{expression})").diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end.first
  end

  def rules(source)
    analyze(source).diagnostics.map { |diagnostic| diagnostic.rule.to_s }.uniq
  end

  describe "the first chained call" do
    it "keeps Enumerator::Lazy and takes its element from the block's return type" do
      expect(dumped_type("[1, 2, 3].lazy.map { |x| x * 2 }")).to eq("Enumerator::Lazy[2 | 4 | 6]")
    end

    it "binds the receiver's element inside the block body" do
      expect(dumped_type("[1, 2, 3].lazy.map { |x| x.succ }")).to eq("Enumerator::Lazy[2 | 3 | 4]")
    end

    it "types a `&:symbol` block through the same element binding" do
      expect(dumped_type("[1, 2, 3].lazy.map(&:to_s)")).to eq(%(Enumerator::Lazy["1" | "2" | "3"]))
    end

    it "leaves the already-correct lazy receiver unchanged" do
      expect(dumped_type("[1, 2, 3].lazy")).to eq("Enumerator::Lazy[1 | 2 | 3]")
    end
  end

  describe "the intermediate chain stays lazy" do
    it "keeps select / reject / take(n) / take_while / uniq as Enumerator::Lazy" do
      {
        "[1, 2, 3].lazy.select { |x| x.odd? }" => "Enumerator::Lazy[1 | 2 | 3]",
        "[1, 2, 3].lazy.reject { |x| x.odd? }" => "Enumerator::Lazy[1 | 2 | 3]",
        "[1, 2, 3].lazy.take(2)" => "Enumerator::Lazy[1 | 2 | 3]",
        "[1, 2, 3].lazy.take_while { |x| x < 3 }" => "Enumerator::Lazy[1 | 2 | 3]",
        "[1, 2, 3].lazy.uniq" => "Enumerator::Lazy[1 | 2 | 3]"
      }.each do |expression, expected|
        expect(dumped_type(expression)).to eq(expected), expression
      end
    end

    # `filter_map` / `flat_map` mirror upstream's `(nil | false | U)` / `(Array[U] | U)` block-return
    # spelling, which the method-level type-parameter binder does not read as a bare variable, so `U` stays
    # free and the element is the `Dynamic[top]` floor. That is what the EAGER call answers on the same
    # nominal receiver (`ARGV.filter_map { |x| x.length }` is `Array[Dynamic[top]]`), so the lazy chain is no
    # worse than the eager one it replaces; only the receiver class is this lane's subject. Flip these two
    # expectations when the binder learns to read a union block return (`compose_block_type_vars`) — both
    # paths move together.
    it "keeps the class on filter_map / flat_map, whose element stays the eager path's floor" do
      {
        "[1, 2, 3].lazy.filter_map { |x| x * 2 }" => "Enumerator::Lazy[Dynamic[top]]",
        "[1, 2, 3].lazy.flat_map { |x| [x, x] }" => "Enumerator::Lazy[Dynamic[top]]",
        "ARGV.lazy.map { |x| x.length }" => "Enumerator::Lazy[non-negative-int]"
      }.each do |expression, expected|
        expect(dumped_type(expression)).to eq(expected), expression
      end
    end

    it "propagates the element through a two-step chain" do
      expect(dumped_type("[1, 2, 3].lazy.take(2).map { |x| x * 2 }")).to eq("Enumerator::Lazy[2 | 4 | 6]")
    end
  end

  describe "terminal methods" do
    it "ends the chain as a non-lazy Array" do
      %w[force to_a first(3)].each do |terminal|
        expect(dumped_type("[1, 2, 3].lazy.map { |x| x * 2 }.#{terminal}")).to eq("Array[2 | 4 | 6]"),
                                                                               terminal
      end
    end

    it "ends an intermediate chain as an Array" do
      expect(dumped_type("[1, 2, 3].lazy.select { |x| x.odd? }.to_a")).to eq("Array[1 | 2 | 3]")
    end

    it "answers a non-lazy Enumerator for eager" do
      expect(dumped_type("[1, 2, 3].lazy.map { |x| x * 2 }.eager"))
        .to eq("Enumerator[2 | 4 | 6, Dynamic[top]]")
    end

    # Deliberately un-prefixed: the `dump_type` prelude's own `include Rigor::Testing` is a toplevel
    # implicit-self call and draws ADR-34's `call.unresolved-toplevel`, which has nothing to do with the
    # chain under test.
    it "reports no diagnostic for a correct chain's terminal calls" do
      expect(rules(<<~RUBY)).to be_empty
        [1, 2, 3].lazy.map { |x| x * 2 }.force
        [1, 2, 3].lazy.map { |x| x * 2 }.eager
        [1, 2, 3].lazy.map { |x| x * 2 }.first(3)
      RUBY
    end
  end

  describe "an unbounded source" do
    # The element type is the pre-existing floor: a `Constant<Range>` whose endpoint is an infinity has no
    # static element to project. What this pins is that the chain neither hangs (the fold must not walk an
    # unbounded range) nor widens what the receiver's own `.lazy` already answered.
    it "does not hang and does not widen the element type" do
      expect(dumped_type("(1..Float::INFINITY).lazy")).to eq("Enumerator::Lazy[Dynamic[top]]")
      expect(dumped_type("(1..Float::INFINITY).lazy.map { |x| x * 2 }")).to eq("Enumerator::Lazy[Dynamic[top]]")
      expect(dumped_type("(1..Float::INFINITY).lazy.map { |x| x * 2 }.first(3)")).to eq("Array[Dynamic[top]]")
    end
  end

  describe "the eager control" do
    it "leaves the eager Array path untouched" do
      expect(dumped_type("[1, 2, 3].map { |x| x * 2 }")).to eq("[2, 4, 6]")
      expect(dumped_type("[1, 2, 3].map(&:to_s)")).to eq(%(["1", "2", "3"]))
      expect(dumped_type("[1, 2, 3].select { |x| x.odd? }")).to eq("[1, 3]")
      expect(dumped_type("[1, 2, 3].filter_map { |x| x * 2 }")).to eq("[2, 4, 6]")
    end
  end
end
