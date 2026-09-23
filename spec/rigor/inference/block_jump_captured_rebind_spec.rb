# frozen_string_literal: true

require "spec_helper"

# A captured outer local that a block rebinds on a path that leaves through `next` or `break`.
#
# Both consumers of a block's captured rebinds — ADR-56's continuation write-back
# (`StatementEvaluator#write_back_block_captures`) and issue #587 (b)'s per-element / per-pair fold
# (`ExpressionTyper#per_element_captured_bindings`) — read the exit binding of one block invocation out of
# `StatementEvaluator`. That exit scope was the body's FALL-THROUGH scope alone, and a branch that ends in a jump
# is dropped from the fall-through (`eval_if` carries the other arm forward), so `if e.odd?; n = e; next; end`
# contributed nothing: `n` kept its pre-call `String` in the continuation although at runtime it is `3`.
#
# A `next` ends the invocation, so its scope is one of the invocation's exits and feeds the next iteration. A
# `break` ends the CALL, so its scope feeds the continuation only — never another iteration.
#
# A jump inside `begin … ensure` leaves only after the `ensure` clause has run, so its scope is carried through it.
#
# Every "widens" example is paired with a control: a rebind on the fall-through path still widens, a jump that
# rebinds nothing leaves the binding exact, and a jump belonging to a nested construct is not this block's.
RSpec.describe "captured rebinds on a block's jump paths", type: :runner do
  def analyzed(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
  end

  def dumped_types(source)
    analyzed(source).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # Every fixture here is written with exactly one `dump_type`.
  def dumped_type(source) = dumped_types(source).first

  # The rule id of every diagnostic a stale binding draws — an undefined method, a nil receiver, and the
  # always-truthy family.
  def reported_rules(source)
    analyzed(source).diagnostics.filter_map do |diagnostic|
      rule = diagnostic.rule.to_s
      rule if %w[call.undefined-method call.possible-nil-receiver].include?(rule) || rule.start_with?("flow.")
    end
  end

  describe "the continuation write-back (ADR-56)" do
    it "joins a rebind on a `next` path into the continuation" do
      # THE REPORTED PROBE. Before the fix `n` read `String` and `n.even?` was `undefined method` on a program
      # whose `n` is `3`. The zero-iteration path keeps the `String` arm.
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | 3 | String")
        n = String.new
        [1, 2, 3].each do |e|
          if e.odd?
            n = e
            next
          end
        end
        dump_type(n)
      RUBY
    end

    it "no longer reports the method the stale binding lacked" do
      expect(reported_rules(<<~RUBY)).not_to include("call.undefined-method")
        n = String.new
        [1, 2, 3].each do |e|
          if e.odd?
            n = e
            next
          end
        end
        n.even?
      RUBY
    end

    it "joins a rebind on a `next` path whose jump carries a value" do
      expect(dumped_type(<<~RUBY)).to eq("0 | :odd")
        n = 0
        [1, 2].each do |e|
          next(n = :odd) if e.odd?
        end
        dump_type(n)
      RUBY
    end

    it "still widens a rebind on the fall-through path of a block that also has a `next`" do
      # The control: the fall-through was always modelled, and the `next` arm (which rebinds nothing) adds only
      # the running assumption back.
      expect(dumped_type(<<~RUBY)).to eq("\"s\" | 0")
        n = 0
        [1, 2].each do |e|
          next if e.odd?
          n = "s"
        end
        dump_type(n)
      RUBY
    end

    it "keeps the exact binding when a block with a `next` rebinds nothing" do
      # The write-back's fast path: with no captured write the join is never reached, and the local stays exact.
      expect(dumped_type(<<~RUBY)).to eq("5")
        n = 5
        [1, 2].each do |e|
          next if e.odd?
          puts e
        end
        dump_type(n)
      RUBY
    end

    it "joins a flag a `rescue` arm sets before `next`" do
      # The commonest real shape: before the fix `failed` read `false` and `if failed` folded always-falsey.
      expect(reported_rules(<<~RUBY)).to be_empty
        failed = false
        ["1", "x"].each do |s|
          begin
            Integer(s)
          rescue ArgumentError
            failed = true
            next
          end
        end
        puts "bad input" if failed
      RUBY
    end

    it "joins a rebind on a `next` inside a value-position `||`" do
      expect(dumped_type(<<~RUBY)).to eq("0 | 1 | 2")
        n = 0
        [1, 2].each do |e|
          e.even? || (n = e; next)
        end
        dump_type(n)
      RUBY
    end

    it "joins a rebind on a `next` inside a `case` / `in` arm" do
      expect(dumped_type(<<~RUBY)).to eq("0 | :one")
        n = 0
        [1, 2].each do |e|
          case e
          in 1
            n = :one
            next
          else
            nil
          end
        end
        dump_type(n)
      RUBY
    end

    it "carries a `next` scope through an enclosing `ensure`" do
      # The `ensure` runs before the `next` leaves, so `buf` is never `nil` after the call; read at the jump, the
      # `nil` arm drew `possible nil receiver` on correct code.
      expect(dumped_type(<<~RUBY)).to eq('"init" | "reset"')
        buf = +"init"
        [1, 2].each do |e|
          begin
            buf = nil
            next if e.odd?
          ensure
            buf = +"reset"
          end
        end
        dump_type(buf)
      RUBY
    end

    it "does not take a nested block's `next` for this block's" do
      # The inner `next` ends an INNER invocation; the outer body rebinds `n` to `:sym` after the inner call on
      # every outer invocation, so `"s"` never reaches the outer continuation directly — only through the
      # inner call's own write-back, which the outer fall-through then overwrites.
      expect(dumped_type(<<~RUBY)).to eq("0 | :sym")
        n = 0
        [1, 2].each do |a|
          next if a > 5
          [2].each do |b|
            if b.even?
              n = "s"
              next
            end
          end
          n = :sym
        end
        dump_type(n)
      RUBY
    end

    it "does not take a nested loop's `next` for this block's" do
      # The loop's `next` ends a loop iteration, not this invocation — the loop collects it itself, beside the
      # block's collection that the block-level `next` on the first line installs — and the body rebinds `n` to
      # `:sym` after the loop.
      expect(dumped_type(<<~RUBY)).to eq("0 | :sym")
        n = 0
        [1, 2].each do |a|
          next if a > 1
          i = 0
          while i < 2
            i += 1
            if i == 1
              n = "s"
              next
            end
          end
          n = :sym
        end
        dump_type(n)
      RUBY
    end

    it "joins a rebind on a `break` path into the continuation" do
      # The `found = x; break` idiom. Before the fix `found` read `nil` and `if found` folded always-falsey. The arm
      # is read in the scope that reaches the `break`, so `x > 1` has already narrowed `x` to `2 | 3`.
      expect(dumped_type(<<~RUBY)).to eq("2 | 3 | nil")
        found = nil
        [1, 2, 3].each do |x|
          if x > 1
            found = x
            break
          end
        end
        dump_type(found)
      RUBY
    end

    it "no longer reports the condition the dropped `break` binding folded" do
      expect(reported_rules(<<~RUBY)).to be_empty
        found = nil
        [1, 2, 3].each do |x|
          if x > 1
            found = x
            break
          end
        end
        found.succ if found
      RUBY
    end

    it "does not feed a `break` binding into another iteration" do
      # `acc` enters every iteration as `0`: the `break` arm's `"s"` leaves the call and reaches only the
      # continuation. Fed back into the fixpoint it would type the body's next pass under `"s" | 0`.
      expect(dumped_type(<<~RUBY)).to eq("0")
        acc = 0
        [1, 2, 3].each do |x|
          dump_type(acc)
          if x > 2
            acc = "s"
            break
          end
        end
      RUBY
    end

    it "adds nothing from a `break` that leaves a fall-through rebind untouched" do
      # The `break` arm carries the running assumption, which the fixpoint already holds.
      expect(dumped_type(<<~RUBY)).to eq('"s" | 0')
        n = 0
        [1, 2].each do |e|
          break if e > 1
          n = "s"
        end
        dump_type(n)
      RUBY
    end

    it "carries a `next` scope through every enclosing `ensure`, innermost first" do
      expect(dumped_type(<<~RUBY)).to eq(":done | :idle")
        state = :idle
        [1, 2].each do |e|
          begin
            begin
              state = 1
              next if e.odd?
            ensure
              state = 2
            end
          ensure
            state = :done
          end
        end
        dump_type(state)
      RUBY
    end

    it "reads a capped fixpoint's `break` arms from its converged binding" do
      # `i` is still moving when the fixpoint's cap widens it to `Integer`, so no pass ran from the converged binding
      # and one more (unrecorded) pass reads the arm: `found` is any `i`, never only the first passes' `2 | 3`.
      expect(dumped_type(<<~RUBY)).to eq("Integer?")
        found = nil
        i = 0
        [1, 2, 3].each do |x|
          i += 1
          if x > 1
            found = i
            break
          end
        end
        dump_type(found)
      RUBY
    end

    it "carries a `break` scope through an enclosing `ensure`" do
      expect(dumped_type(<<~RUBY)).to eq(":done | :idle")
        state = :idle
        [1, 2].each do |e|
          begin
            state = 1
            break if e > 1
          ensure
            state = :done
          end
        end
        dump_type(state)
      RUBY
    end

    it "keeps reporting inside the block what the fixpoint's own passes see" do
      # A capped fixpoint reads its `break` arms from one more pass, which must not overwrite the per-node scope
      # index: re-recorded from the floored `x`, the real `undefined method 'upcase'` for Integer vanished.
      expect(reported_rules(<<~RUBY)).to include("call.undefined-method")
        x = 1
        [1, 2].each do |e|
          x.upcase
          x = [x]
          break if e > 1
        end
      RUBY
    end

    it "records a loop `break`'s argument writes" do
      # `break(flag = true)` leaves with the write; the loop join read the scope before the argument and kept
      # `false`.
      expect(dumped_type(<<~RUBY)).to eq("bool")
        flag = false
        while gets
          break(flag = true) if rand > 0.5
        end
        dump_type(flag)
      RUBY
    end

    it "keeps the fixpoint's floor rather than joining a `break` arm into it" do
      # `x = [x]` never converges, so the fixpoint floors `x` to `Dynamic[top]`; a precise arm unioned into the
      # floor would read as partial knowledge the analysis does not have.
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
        x = 1
        [1, 2].each do |e|
          x = [x]
          if e > 1
            x = "s"
            break
          end
        end
        dump_type(x)
      RUBY
    end
  end

  describe "the per-element / per-pair fold (issue #587 (b))" do
    it "binds a rebind on a `next` path at every pair" do
      # THE REPORTED PROBE's HashShape twin. Before the fix `total` converged on its `String` seed, so `r[:y]`
      # read `String` and `.even?` was `undefined method`; at runtime `r[:y]` is `1`.
      expect(reported_rules(<<~RUBY)).not_to include("call.undefined-method")
        total = String.new
        r = { x: 1, y: 2 }.transform_values do |e|
          if e.odd?
            total = e
            next e
          end
          total
        end
        r[:y].even?
      RUBY
    end

    it "binds the `next`-path rebind at every pair" do
      # `total` is `1` at `:y` at runtime; the pin answered `String`. `:x` carries its body's tail as well as its
      # `next` arm — the tail it cannot reach there is the fold's existing, sound over-approximation.
      expect(dumped_type(<<~RUBY)).to eq("{ x: 1 | 2 | String, y: 1 | 2 | String }")
        total = String.new
        dump_type({ x: 1, y: 2 }.transform_values do |e|
          if e.odd?
            total = e
            next e
          end
          total
        end)
      RUBY
    end

    it "still floors a value-pinned seed the fall-through never moves" do
      # #617's unmoved-pin floor is judged on the fall-through alone, so a pinned seed that only a `next` arm
      # rebinds is floored as before — the cheaper side of the trade in the example below.
      expect(dumped_type(<<~RUBY)).to eq("[1 | Dynamic[top], Dynamic[top]]")
        m = 0
        dump_type([1, 2].map do |e|
          if e.odd?
            m = "s"
            next e
          end
          m
        end)
      RUBY
    end

    it "keeps the unmoved-pin floor when a `next` arm moves a name the fall-through writes unthreaded" do
      # `(seen += 1) == 2` is a write the evaluator does not thread. The `next` arm moved `seen` to `0 | 100`, so a
      # converged-binding test believed it and folded `find` to `nil`: `r.succ` became `undefined method` for
      # nil and `if r` always-falsey, on a program whose `r` is `2`.
      expect(reported_rules(<<~RUBY)).to eq(["call.possible-nil-receiver"])
        seen = 0
        r = [1, 2].find do |e|
          if rand > 2.0
            seen = 100
            next false
          end
          (seen += 1) == 2
        end
        puts "found" if r
        r.succ
      RUBY
    end

    it "keeps a predicate fold whose `next` path rebinds nothing" do
      expect(dumped_type(<<~RUBY)).to eq("[2]")
        seen = 0
        dump_type([1, 2].select do |e|
          next false if e > 5
          seen += 1
          e > 1
        end)
      RUBY
    end
  end
end
