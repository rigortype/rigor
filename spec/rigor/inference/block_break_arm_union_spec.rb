# frozen_string_literal: true

require "spec_helper"

# Issue #853 — a block-level `break value` is the yielding CALL's value.
#
# The sibling of #841: there, `next` arms were dropped from the block's value type; here, `break` arms were
# dropped from the call's. `ops.all? { |o| break false unless o; true }` folded to `Constant[true]` and
# `flow.always-truthy-condition` fired on a program that really can answer false. The union happens above the
# folds rather than inside them, so a fold stays free to answer precisely for the no-break path.
#
# Every "unions" example is paired with a control that must NOT move — a `break` the enclosing construct
# owns, a call with no break at all, and a guard the analyzer proves dead.
RSpec.describe "block `break` arm union", type: :runner do
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

  # `Mutex#synchronize` is `[X] () { () -> X } -> X`, so with no break the call's type IS the block's value —
  # the shortest probe of what the union added. `flag` is `[true, false].sample` rather than a literal so the
  # guard stays live: a literal would make the arm provably dead, which is separately asserted below.
  def synchronize_block(body)
    <<~RUBY
      m = Mutex.new
      flag = [true, false].sample
      dump_type(m.synchronize do
      #{body.lines.map { |line| "  #{line}" }.join}
      end)
    RUBY
  end

  describe "the arms that terminate the call" do
    it "unions a value-carrying `break` with the callee's result" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5")
        break 5 if flag
        42
      RUBY
    end

    it "unions a bare `break` as nil" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42?")
        break if flag
        42
      RUBY
    end

    it "unions a `break` nested inside an `unless` guard" do
      # The issue's own shape: the arm is not a direct child of the body — the walk reaches it through the
      # `unless`, which retargets nothing.
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5")
        unless flag
          break 5
        end
        42
      RUBY
    end

    it "unions a `break` reached through a `case` arm" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5")
        case [1, 2].sample
        when 1 then break 5
        end
        42
      RUBY
    end

    it "unions every arm when the body carries several" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | 5 | :other")
        break 5 if flag
        break :other unless flag
        42
      RUBY
    end

    it "types a `break` arm in the scope that reaches it, not the block's entry scope" do
      # The arm is collected during an evaluation of the body, so it reads the binding the preceding statement
      # made. Typing it in the entry scope would answer `1` here — the stale outer value.
      expect(dumped_type(<<~RUBY)).to eq("\"s\" | 42")
        m = Mutex.new
        flag = [true, false].sample
        y = 1
        dump_type(m.synchronize do
          y = "s"
          break y if flag
          42
        end)
      RUBY
    end

    it "packs a multi-value `break` into a Tuple" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42 | [1, \"x\"]")
        break 1, "x" if flag
        42
      RUBY
    end

    it "types `loop` as its break arm" do
      # `loop` is a call with a block and never falls through, so the arm is the whole answer.
      expect(dumped_type("dump_type(loop { break 5 })")).to eq("5")
    end

    it "unions a `break` arm with the receiver `each` returns" do
      expect(dumped_type(<<~RUBY)).to eq("7 | Array")
        flag = [true, false].sample
        dump_type([1, 2, 3].each { |_x| break 7 if flag })
      RUBY
    end

    it "keeps the block's own `next` join alongside a `break` arm" do
      # The two exits are modelled at their own levels: `next` joins the BLOCK's value, `break` the CALL's.
      # Before this change a co-resident `break` suppressed the `next` join entirely.
      expect(dumped_type(<<~RUBY)).to eq("\"b\" | 42 | :n")
        m = Mutex.new
        flag = [true, false].sample
        other = [true, false].sample
        dump_type(m.synchronize do
          break "b" if flag
          next :n if other
          42
        end)
      RUBY
    end
  end

  describe "jumps this call does not own" do
    it "leaves a `break` belonging to a nested block out of the union" do
      # `break` inside `each`'s block terminates THAT call; nothing escapes to the outer one.
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42")
        [1, 2].each { break 9 }
        42
      RUBY
    end

    it "leaves a `break` belonging to a loop out of the union" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42")
        while flag
          break 5
        end
        42
      RUBY
    end

    it "leaves a `break` belonging to a lambda out of the union" do
      expect(dumped_type(synchronize_block(<<~RUBY))).to eq("42")
        fn = -> { break 1 }
        42
      RUBY
    end

    it "leaves an early `return` out of the union" do
      # A `return` exits the enclosing METHOD and joins that method's return type; the call is unaffected.
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

    it "leaves a call with no block untouched" do
      expect(dumped_type("dump_type([1, 2, 3].size)")).to eq("3")
    end
  end

  describe "arms the analyzer proves unreachable" do
    it "keeps the exact per-element answer when the guard is provably false" do
      # `x` is pinned per position, so `x.nil?` folds to false and the evaluator never enters the arm — the
      # union is flow-sensitive for free rather than widening every guarded `break` unconditionally.
      expect(dumped_type(<<~RUBY)).to eq('["1", "2"]')
        dump_type([1, 2].map { |x| break nil if x.nil?; x.to_s })
      RUBY
    end
  end

  # The reported symptom. `BlockFolding#predicate_decision` is correct for the path where the block never
  # breaks; the defect was that the call adopted that path as its whole answer.
  describe "the predicate folds the union sits above" do
    it "no longer reports the issue's condition as always truthy" do
      expect(flow_rules(<<~RUBY)).to be_empty
        def all_present?(ops)
          ops.all? do |o|
            break false unless o
            true
          end
        end
        puts "yes" if all_present?([1, nil])
      RUBY
    end

    it "still reports a block that is truthy with no break arm" do
      # The must-fire sibling: `all?` genuinely is unconditionally true, so the fold — and the warning it
      # justifies — must survive.
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

    it "keeps folding when the `break` arm is truthy too" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        def all_true?(ops)
          ops.all? do |o|
            break true unless o
            true
          end
        end
        puts "yes" if all_true?([1, nil])
      RUBY
    end

    it "stops folding `count` to a constant when the arm is falsey" do
      expect(dumped_type(<<~RUBY)).to eq("3 | false")
        flag = [true, false].sample
        dump_type([1, 2, 3].count { |_e| break false if flag; true })
      RUBY
    end

    it "still folds `count` when the block cannot break" do
      expect(dumped_type(<<~RUBY)).to eq("3")
        dump_type([1, 2, 3].count { |_e| true })
      RUBY
    end
  end
end
