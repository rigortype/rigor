# frozen_string_literal: true

require "spec_helper"

# A local that a `while` / `until` / `for` body rebinds on a path that leaves the iteration through `next`, or the
# loop through `break` — the loop siblings of `block_jump_captured_rebind_spec.rb`.
#
# Every reader of a loop body read its FALL-THROUGH scope alone: the single pass `eval_loop` joins with the pre-loop
# scope, each pass of ADR-56 slice B's rebind fixpoint, and `eval_for`'s only pass. A branch that ends in a jump is
# dropped from the fall-through (`eval_if` carries the other arm forward), so `if i.odd?; w = i; next; end` added
# nothing and `w` kept its pre-loop `String` although at runtime it is `3`. A `next` returns to the predicate, so its
# scope is one of the iteration's exits and feeds the next iteration.
#
# A `break` leaves the loop, so its scope feeds the continuation only. Its arms were read from the FIRST body pass,
# which runs before any loop-carried rebind has moved, so a `break` whose branch is dead there — `break(flag = true)
# if i == 2` while `i` is still `1` — was never reached and `flag` stayed `false`. The arms now come from a pass
# that ran from the fixpoint's converged binding.
#
# Every widening example is paired with a control: a fall-through rebind still widens, a `next` that rebinds nothing
# leaves the binding exact, and a jump belonging to a nested construct is not the loop's.
RSpec.describe "rebinds on a loop's jump paths", type: :runner do
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

  describe "a `next` path" do
    it "joins a `while` body's `next`-path rebind into the continuation" do
      # THE REPORTED PROBE. Before the fix `w` read `String` and `w.even?` was `undefined method` on a program whose
      # `w` is `3`. The zero-iteration path keeps the `String` arm.
      expect(dumped_type(<<~RUBY)).to eq("Integer | String")
        w = String.new
        i = 0
        while i < 3
          i += 1
          if i.odd?
            w = i
            next
          end
        end
        dump_type(w)
      RUBY
    end

    it "no longer reports the method the stale binding lacked" do
      expect(reported_rules(<<~RUBY)).not_to include("call.undefined-method")
        w = String.new
        i = 0
        while i < 3
          i += 1
          if i.odd?
            w = i
            next
          end
        end
        w.even?
      RUBY
    end

    it "feeds a `next`-path rebind into the next iteration" do
      # The fixpoint's own passes read the `next` exit, so the body sees `w` as the previous iteration left it. The
      # check path records the fixpoint's last pass, whose entry is the assumption before the cap widens it.
      expect(dumped_type(<<~RUBY)).to eq('"s" | 1 | 2')
        w = "s"
        i = 0
        while i < 3
          i += 1
          dump_type(w)
          if i.odd?
            w = i
            next
          end
        end
      RUBY
    end

    it "joins an `until` body's `next`-path rebind" do
      expect(dumped_type(<<~RUBY)).to eq("Integer | String")
        w = String.new
        i = 0
        until i >= 3
          i += 1
          if i.odd?
            w = i
            next
          end
        end
        dump_type(w)
      RUBY
    end

    it "joins a `for` body's `next`-path rebind" do
      expect(dumped_type(<<~RUBY)).to eq("1 | 2 | 3 | String")
        w = String.new
        for i in [1, 2, 3]
          if i.odd?
            w = i
            next
          end
        end
        dump_type(w)
      RUBY
    end

    it "joins a flag a `rescue` arm sets before `next` in a `for` body" do
      # Before the fix `failed` read `false` and `if failed` folded always-falsey.
      expect(reported_rules(<<~RUBY)).to be_empty
        failed = false
        for s in ["1", "x"]
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

    it "joins a rebind inside the `next`'s own argument" do
      expect(dumped_type(<<~RUBY)).to eq("Integer | Symbol")
        n = 0
        i = 0
        while i < 2
          i += 1
          next(n = :odd) if i.odd?
        end
        dump_type(n)
      RUBY
    end

    it "joins an instance variable a `next` path rebinds" do
      # The fixpoint tracks locals only; an ivar reaches the continuation through the single body pass, which now
      # joins its `next` exit too.
      expect(dumped_type(<<~RUBY)).to eq("1 | String")
        class LoopJumpIvar
          def run
            @w = String.new
            i = 0
            while i < 3
              i += 1
              if i.odd?
                @w = i
                next
              end
            end
            dump_type(@w)
          end
        end
      RUBY
    end

    it "nil-injects a local first bound on a `next` path" do
      # The zero-iteration and fall-through paths leave `v` unbound, which reads `nil`; before the fix the `next`
      # path's binding was dropped and `v` read `nil` alone.
      expect(dumped_type(<<~RUBY)).to eq("Integer?")
        i = 0
        while i < 3
          i += 1
          if i.odd?
            v = i
            next
          end
        end
        dump_type(v)
      RUBY
    end

    it "carries a `next` scope through an enclosing `ensure`" do
      # The `ensure` runs before the `next` leaves, so `buf` is never `nil` after the loop; read at the jump, the
      # `nil` arm would draw `possible nil receiver` on correct code.
      expect(dumped_type(<<~RUBY)).to eq('"init" | "reset"')
        buf = +"init"
        while gets
          begin
            buf = nil
            next if rand > 0.5
          ensure
            buf = +"reset"
          end
        end
        dump_type(buf)
      RUBY
    end

    it "still widens a fall-through rebind in a body that also has a `next`" do
      # The control: the fall-through was always modelled, and the `next` arm (which rebinds nothing) adds only the
      # running assumption back.
      expect(dumped_type(<<~RUBY)).to eq("Integer | String")
        n = 0
        i = 0
        while i < 2
          i += 1
          next if i.odd?
          n = "s"
        end
        dump_type(n)
      RUBY
    end

    it "keeps the exact binding when a `next` rebinds nothing" do
      expect(dumped_types(<<~RUBY)).to eq(["0", "Integer[3..]"])
        n = 0
        i = 0
        while i < 3
          i += 1
          next if i.odd?
          puts i
        end
        dump_type(n)
        dump_type(i)
      RUBY
    end

    it "still narrows the continuation on the predicate's exit edge" do
      # A `next` returns to the predicate, so the loop still exits only when `i < 3` is false.
      expect(dumped_type(<<~RUBY)).to eq("Integer[3..]")
        i = 0
        while i < 3
          i += 1
          next if i.odd?
        end
        dump_type(i)
      RUBY
    end

    it "does not take a nested block's `next` for the loop's" do
      # The inner `next` ends an invocation of the block; the loop body rebinds `n` to `:sym` after the call, so
      # `"s"` never reaches the loop's continuation.
      expect(dumped_type(<<~RUBY)).to eq("Integer | Symbol")
        n = 0
        i = 0
        while i < 2
          i += 1
          next if i > 5
          [1, 2].each do |b|
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

    it "does not take a lambda literal's `next` for the loop's" do
      # A `->` body is evaluated under the loop's collection, so its `next` reaches the loop's sink and must be
      # dropped by node identity.
      expect(dumped_type(<<~RUBY)).to eq("Integer | Symbol")
        n = 0
        i = 0
        while i < 2
          i += 1
          next if i > 5
          f = -> { n = "s"; next }
          n = :sym
        end
        dump_type(n)
      RUBY
    end

    it "does not take a nested loop's `next` for the outer loop's" do
      expect(dumped_type(<<~RUBY)).to eq("Integer | Symbol")
        n = 0
        i = 0
        while i < 2
          i += 1
          next if i > 5
          j = 0
          while j < 2
            j += 1
            if j == 1
              n = "s"
              next
            end
          end
          n = :sym
        end
        dump_type(n)
      RUBY
    end
  end

  describe "a `break` path" do
    it "joins a `break` its first pass cannot reach" do
      # THE REPORTED PROBE. `i == 2` is `false` while `i` is still `1`, so the first pass never reached the `break`
      # and `flag` read `false`.
      expect(dumped_type(<<~RUBY)).to eq("bool")
        flag = false
        i = 0
        while i < 5
          i += 1
          break(flag = true) if i == 2
        end
        dump_type(flag)
      RUBY
    end

    it "no longer folds the condition the lost `break` binding decided" do
      expect(reported_rules(<<~RUBY)).to be_empty
        flag = false
        i = 0
        while i < 5
          i += 1
          break(flag = true) if i == 2
        end
        puts "hit" if flag
      RUBY
    end

    it "joins a `break` only a stabilised fixpoint's later pass reaches" do
      # `seen` is `false` on the first pass and `bool` from the second on, where the fixpoint stabilises; that pass
      # ran from the converged binding and reaches the `break`, so its arms are the converged ones.
      expect(dumped_type(<<~RUBY)).to eq(":second?")
        found = nil
        seen = false
        while gets
          if seen
            found = :second
            break
          end
          seen = true
        end
        dump_type(found)
      RUBY
    end

    it "reads a capped fixpoint's `break` arms from its converged binding" do
      # `i` is still moving when the cap widens it to `Integer`, so no pass ran from the converged binding and one
      # more (unrecorded) pass reads the arm: `found` is any `i`, never only the last pass's `1 | 2 | 3`.
      expect(dumped_type(<<~RUBY)).to eq("Integer?")
        found = nil
        i = 0
        while gets
          i += 1
          if rand > 0.5
            found = i
            break
          end
        end
        dump_type(found)
      RUBY
    end

    it "narrows a `break` arm by the guard a stabilised fixpoint reaches it through" do
      # `i > 1` narrows the fall-through back to `1`, so `i` settles on `0 | 1` and the arm the settled pass reaches
      # is exactly the runtime `2`.
      expect(dumped_type(<<~RUBY)).to eq("2?")
        found = nil
        i = 0
        while i < 5
          i += 1
          if i > 1
            found = i
            break
          end
        end
        dump_type(found)
      RUBY
    end

    it "reads a `break` arm through the predicate's loop-entry edge" do
      # The body of a pre-tested loop only runs with `line` truthy. The old first pass read the arm from the
      # un-narrowed post-predicate scope, so `found` carried `nil` and `found.upcase` drew `possible nil receiver`.
      expect(reported_rules(<<~RUBY)).to be_empty
        found = ""
        line = gets
        while line
          found = line
          break
        end
        found.upcase
      RUBY
    end

    it "joins a `break` a `begin … end while` body takes on its first iteration" do
      # The first iteration runs before `state != :idle` is tested, so every fixpoint pass (entered through the
      # predicate's truthy edge) finds `state == :idle` false. Read from the converged pass alone, `done` stayed
      # `false` and `if done` folded always-falsey; at runtime the method answers `:finished`.
      expect(dumped_type(<<~RUBY)).to eq("bool")
        def finish
          state = :idle
          done = false
          begin
            if state == :idle
              done = true
              break
            end
            state = :busy
          end while state != :idle
          dump_type(done)
        end
      RUBY
    end

    it "no longer folds the condition a first-iteration `break` of a `begin … end until` decides" do
      expect(reported_rules(<<~RUBY)).to be_empty
        def finish
          state = :idle
          done = false
          begin
            if state == :idle
              done = true
              break
            end
            state = :busy
          end until state == :idle
          return :finished if done

          :pending
        end
      RUBY
    end

    it "does not take a nested block's `break` for the loop's" do
      # The inner `break` ends the `each` call; the loop body rebinds `n` to `:sym` after it.
      expect(dumped_type(<<~RUBY)).to eq("Integer | Symbol")
        n = 0
        i = 0
        while i < 2
          i += 1
          break if i > 5
          [1, 2].each do |b|
            if b.even?
              n = "s"
              break
            end
          end
          n = :sym
        end
        dump_type(n)
      RUBY
    end

    it "does not take a lambda literal's `break` for the loop's" do
      expect(dumped_type(<<~RUBY)).to eq("Integer | Symbol")
        n = 0
        i = 0
        while i < 2
          i += 1
          break if i > 5
          f = -> { n = "s"; break }
          n = :sym
        end
        dump_type(n)
      RUBY
    end

    it "does not feed a `break` binding into another iteration" do
      # `acc` enters every iteration as `0`: the `break` arm's `"s"` leaves the loop and reaches only the
      # continuation.
      expect(dumped_type(<<~RUBY)).to eq("0")
        acc = 0
        i = 0
        while i < 3
          i += 1
          dump_type(acc)
          if i > 1
            acc = "s"
            break
          end
        end
      RUBY
    end

    it "carries a `break` scope through an enclosing `ensure`" do
      expect(dumped_type(<<~RUBY)).to eq(":done | :idle")
        state = :idle
        i = 0
        while i < 3
          i += 1
          begin
            state = 1
            break if i > 1
          ensure
            state = :done
          end
        end
        dump_type(state)
      RUBY
    end

    it "keeps reporting inside the loop what the fixpoint's own passes see" do
      # A capped fixpoint reads its `break` arms from one more pass, which must not overwrite the per-node scope
      # index: re-recorded from the floored `x`, the real `undefined method 'upcase'` vanished.
      expect(reported_rules(<<~RUBY)).to include("call.undefined-method")
        x = 1
        i = 0
        while i < 3
          i += 1
          x.upcase
          x = [x]
          break if i > 1
        end
      RUBY
    end

    it "keeps the fixpoint's floor rather than joining a `break` arm into it" do
      # `x = [x]` never converges, so the fixpoint floors `x` to `Dynamic[top]`; a precise arm unioned into the floor
      # would read as partial knowledge the analysis does not have.
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
        x = 1
        i = 0
        while i < 3
          i += 1
          x = [x]
          if i > 1
            x = "s"
            break
          end
        end
        dump_type(x)
      RUBY
    end
  end
end
