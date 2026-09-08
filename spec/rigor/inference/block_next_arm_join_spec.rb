# frozen_string_literal: true

require "spec_helper"

# Issue #841 — `next value` arms join into the block's value type.
#
# The block-return pass modelled only the fall-through tail, so `ops.all? { |o| next false unless o; true }`
# read as `Constant[true]` and `MethodDispatcher::BlockFolding` folded the call to always-truthy on a program
# that really can answer false. The join mirrors what `ExpressionTyper#evaluate_body_with_returns` does one
# level up for a method's early `return`: the escaping arms union with the tail.
#
# Every "joins" example is paired with a control that must NOT move — a jump the enclosing construct
# retargets, a `break` (whose value belongs to the yielding call, not the block), and a guard the analyzer
# proves dead.
RSpec.describe "block `next` arm join", type: :runner do
  def dumped_type(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    dumps = result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
    dumps.first
  end

  # Every diagnostic a flow rule produced for `source` — the always-truthy / always-falsey family.
  def flow_rules(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
  end

  # `Mutex#synchronize` is `[X] () { () -> X } -> X`, so the call's type IS the block's value type — the
  # shortest probe of what the block-return pass decided. `flag` is `[true, false].sample` rather than a
  # literal so the guard stays live: a literal would make the `next` arm provably dead, which is a different
  # (and separately asserted) behaviour.
  def synchronize_block(body)
    <<~RUBY
      m = Mutex.new
      flag = [true, false].sample
      dump_type(m.synchronize do
      #{body.lines.map { |line| "  #{line}" }.join}
      end)
    RUBY
  end

  describe "the arms that leave the block" do
    it "joins a value-carrying `next` with the tail" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5")
        next 5 if flag
        42
      RUBY
    end

    it "joins a bare `next` as nil" do
      # `next` with no argument ends the invocation with nil, exactly as a bare `return` returns nil.
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42?")
        next if flag
        42
      RUBY
    end

    it "joins a `next` nested inside an `unless` guard" do
      # The issue's own shape. The arm is not a direct child of the body — the walk reaches it through the
      # `unless`, which retargets nothing.
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5")
        unless flag
          next 5
        end
        42
      RUBY
    end

    it "joins a `next` nested two conditionals deep" do
      # Two independent guards: re-testing `flag` inside `if flag` would narrow the inner one to a provably
      # dead arm, which the evaluator correctly never enters.
      expect(dumped_type(<<~RUBY)).to eq("42 | 5")
        m = Mutex.new
        flag = [true, false].sample
        other = [true, false].sample
        dump_type(m.synchronize do
          if flag
            next 5 unless other
          end
          42
        end)
      RUBY
    end

    it "joins a `next` reached through a `case` arm" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5")
        case [1, 2].sample
        when 1 then next 5
        end
        42
      RUBY
    end

    it "joins every arm when the body carries several" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5 | :other")
        next 5 if flag
        next :other unless flag
        42
      RUBY
    end

    it "types a body that is nothing but a `next`" do
      # The fall-through is `Bot` (control never reaches the end of the body), which the union absorbs, so
      # the arm alone is the answer.
      expect(dumped_type(synchronize_block("next 5"))).to eq("5")
    end

    it "types a `next` arm in the scope that reaches it, not the block's entry scope" do
      # The arm is collected during the same evaluation that produces the tail, so it reads the binding the
      # preceding statement made. Typing it in the entry scope would answer `1` here — the stale outer value.
      expect(dumped_type(<<~RUBY)).to eq("\"s\" | 42")
        m = Mutex.new
        flag = [true, false].sample
        y = 1
        dump_type(m.synchronize do
          y = "s"
          next y if flag
          42
        end)
      RUBY
    end

    it "packs a multi-value `next` into a Tuple" do
      # `next 1, "x"` ends the invocation with the array `[1, "x"]`, matching `return 1, "x"`.
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | [1, \"x\"]")
        next 1, "x" if flag
        42
      RUBY
    end
  end

  describe "jumps this block does not own" do
    it "leaves a `next` belonging to a nested block out of the join" do
      # `next` inside `each`'s block ends THAT iteration; it cannot carry a value out of the outer block.
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42")
        [1, 2].each { next 1 }
        42
      RUBY
    end

    it "leaves a `next` belonging to a loop out of the join" do
      # A loop consumes `next` as "continue"; nothing escapes the block through it.
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42")
        while flag
          next 5
        end
        42
      RUBY
    end

    it "leaves a `next` belonging to a lambda out of the join" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42")
        fn = -> { next 1 }
        42
      RUBY
    end

    it "leaves an early `return` out of the join" do
      # A `return` exits the enclosing METHOD, and already joins into that method's return type; the block's
      # own value is unaffected.
      expect(dumped_type(<<~RUBY)).to eq("42")
        def run(flag)
          m = Mutex.new
          dump_type(m.synchronize do
            return 7 if flag
            42
          end)
        end
      RUBY
    end

    it "leaves a `break` out of the BLOCK's value and lets the call absorb it" do
      # `break value` is the value of the yielding CALL rather than of the block, so it is not a block arm.
      # The block's own value here is the tail alone; the 5 in the answer arrives from the other end, where
      # issue #853 unions the arms into the call — the `Mutex#synchronize` signature makes the two visible
      # at the same position, and this asserts they compose rather than that either absorbed the other.
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5")
        break 5 if flag
        42
      RUBY
    end
  end

  describe "arms the analyzer proves unreachable" do
    it "keeps the exact per-element answer when the guard is provably false" do
      # `x` is pinned per position, so `x.nil?` folds to false and the evaluator never enters the arm — the
      # join is flow-sensitive for free rather than widening every guarded `next` unconditionally.
      expect(dumped_type(<<~RUBY)).to eq('["1", "2"]')
        dump_type([1, 2].map { |x| next nil if x.nil?; x.to_s })
      RUBY
    end
  end

  # The reported symptom. `BlockFolding#predicate_decision` is correct given a truthy block type; the defect
  # was the block type it was given.
  describe "the predicate folds the join feeds" do
    it "no longer reports the issue's condition as always truthy" do
      expect(flow_rules(<<~RUBY)).to be_empty
        def all_present?(ops)
          ops.all? do |o|
            next false unless o
            true
          end
        end
        puts "yes" if all_present?([1, nil])
      RUBY
    end

    it "still reports a block that is truthy on every arm" do
      # The must-fire sibling: no falsey arm, so `all?` genuinely is unconditionally true and the fold — and
      # the warning it justifies — must survive.
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        def all_true?(ops)
          ops.all? do |o|
            o
            true
          end
        end
        puts "yes" if all_true?([1, nil])
      RUBY
    end

    it "keeps folding when every `next` arm is truthy too" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        def all_true?(ops)
          ops.all? do |o|
            next true unless o
            true
          end
        end
        puts "yes" if all_true?([1, nil])
      RUBY
    end

    it "stops folding `count` to a constant when an arm is falsey" do
      expect(dumped_type(<<~RUBY)).to eq("Integer")
        flag = [true, false].sample
        dump_type([1, 2, 3].count { |_e| next false if flag; true })
      RUBY
    end

    it "still folds `count` when every arm is truthy" do
      expect(dumped_type(<<~RUBY)).to eq("3")
        flag = [true, false].sample
        dump_type([1, 2, 3].count { |_e| next true if flag; true })
      RUBY
    end

    it "stops folding `any?` to a constant when an arm is falsey" do
      expect(dumped_type(<<~RUBY)).to eq("bool")
        flag = [true, false].sample
        dump_type([1, 2, 3].any? { |_e| next false if flag; true })
      RUBY
    end

    it "stops folding `none?` to a constant when an arm is truthy" do
      expect(dumped_type(<<~RUBY)).to eq("bool")
        flag = [true, false].sample
        dump_type([1, 2, 3].none? { |_e| next true if flag; false })
      RUBY
    end
  end
end
