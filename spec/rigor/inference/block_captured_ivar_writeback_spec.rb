# frozen_string_literal: true

require "spec_helper"

# ADR-56's captured-variable continuation, extended to instance variables. A block shares its caller's
# `self`, so an ivar it rebinds outlives the call exactly as a captured local does; before this the
# continuation after the call read the ivar's PRE-call binding on both paths:
#
# - a `:non_escaping` block (`[1, 2].each { @n += 1 }`) went through `write_back_block_captures`, whose
#   `BodyFixpoint` covered locals only, and
# - an `:escaping` / `:unknown` one (`items.each { … }` over an untyped `items`, a lambda literal) went
#   through `drop_captured_narrowing`, which dropped only locals to `Dynamic[top]`.
#
# `@count = 0; items.each { @count += 1 }; puts "empty" if @count == 0` therefore fired
# `flow.always-truthy-condition` on correct code. Every widening below is paired with a control that must
# stay exact, so a fix that widens too much goes red as surely as one that widens too little.
#
# The engine's own `assert.type-mismatch` rule is the type channel: an empty mismatch list means the
# engine answered exactly the asserted type. `assert_type` is itself an implicit-self call, which joins
# every ivar with its class seed on the way out (the intervening-call invalidation), so a method that
# asserts on more than one binding copies each ivar into a local before the first assertion.
RSpec.describe "instance variables a block rebinds, in the call's continuation (ADR-56)" do
  include RunnerHelpers

  def diagnostics_for(source, rule)
    analyze(source).diagnostics.select { |d| d.rule == rule }
  end

  def expect_types(body)
    source = "require \"rigor/testing\"\ninclude Rigor::Testing\n\n#{body}"
    expect(diagnostics_for(source, "assert.type-mismatch").map(&:message)).to be_empty
  end

  def always_truthy_lines(source)
    diagnostics_for(source, "flow.always-truthy-condition").map(&:line)
  end

  describe "the counter idiom" do
    it "does not fold a counter an unknown block bumps, and still folds one it leaves alone" do
      # `items` is an untyped parameter, so `items.each` classifies `:unknown` — the drop path.
      source = <<~RUBY
        class Tally
          def run(items)
            @count = 0
            items.each { @count += 1 }
            puts "empty" if @count == 0
          end

          def untouched(items)
            @other = 0
            items.each { |item| item }
            puts "never" if @other == 0
          end
        end
      RUBY

      expect(always_truthy_lines(source)).to eq([11])
    end

    it "does not fold a counter a non-escaping block bumps, and still folds one it leaves alone" do
      # A Tuple receiver classifies `each` as `:non_escaping` — the write-back path.
      source = <<~RUBY
        class Tally
          def run
            @count = 0
            [1, 2, 3].each { @count += 1 }
            puts "empty" if @count == 0
          end

          def untouched
            @other = 0
            [1, 2, 3].each { |item| item }
            puts "never" if @other == 0
          end
        end
      RUBY

      expect(always_truthy_lines(source)).to eq([11])
    end
  end

  describe "a non-escaping block: the write-back joins through the fixpoint" do
    it "widens accumulators, keeps a distinct-constant rebind's constituents, and keeps `||=`'s pre-call nil" do
      expect_types(<<~RUBY)
        class Accumulators
          def counter
            @count = 0
            [1, 2, 3].each { @count += 1 }
            assert_type("Integer", @count)
          end

          def power
            @power = 1
            1.upto(6) { @power *= 2 }
            assert_type("Integer", @power)
          end

          def flag
            @flag = 1
            [1].each { @flag = 99 }
            assert_type("1 | 99", @flag)
          end

          def memo
            @memo = nil
            [1].each { @memo ||= 5 }
            assert_type("5?", @memo)
          end
        end
      RUBY
    end

    it "counts a multi-assign target and a write in a nested block" do
      expect_types(<<~RUBY)
        class Shapes
          def swap
            @left = 1
            @right = 2
            [1].each { @left, @right = @right, @left }
            left = @left
            right = @right
            assert_type("1 | 2", left)
            assert_type("1 | 2", right)
          end

          # The inner call's own write-back widens first, so the outer fixpoint converges before its
          # final-pass widening and keeps the seed's `0` — the answer the local spelling gets.
          def nested
            @deep = 0
            deep = 0
            [1].each { [2].each { @deep += 1 } }
            [1].each { [2].each { deep += 1 } }
            ivar = @deep
            assert_type("0 | Integer", ivar)
            assert_type("0 | Integer", deep)
          end
        end
      RUBY
    end

    it "floors a compounding ivar to Dynamic[top] at the cap" do
      expect_types(<<~RUBY)
        class Compounding
          def grow
            @grow = 1
            [1].each { @grow = [@grow] }
            assert_type("Dynamic[top]", @grow)
          end
        end
      RUBY
    end

    it "runs locals and ivars through one fixpoint, so a local read from a rebound ivar widens too" do
      expect_types(<<~RUBY)
        class Joint
          def run
            @n = 0
            last = 0
            [1, 2].each do
              last = @n
              @n += 1
            end
            n = @n
            assert_type("Integer", last)
            assert_type("Integer", n)
          end
        end
      RUBY
    end

    it "keeps the exact binding of an ivar the block does not rebind" do
      expect_types(<<~RUBY)
        class Untouched
          def run
            @kept = 7
            @read = 7
            [1].each { |z| z.to_s }
            [1].each { |z| z + @read }
            kept = @kept
            read = @read
            assert_type("7", kept)
            assert_type("7", read)
          end
        end
      RUBY
    end

    it "keeps an ivar and a local of the same bare name apart" do
      expect_types(<<~RUBY)
        class SameName
          def ivar_rebound
            t = 5
            @t = 0
            [1].each { @t += 1 }
            ivar = @t
            assert_type("5", t)
            assert_type("Integer", ivar)
          end

          def local_rebound
            u = 0
            @u = 5
            [1].each { u += 1 }
            ivar = @u
            assert_type("Integer", u)
            assert_type("5", ivar)
          end
        end
      RUBY
    end
  end

  describe "an escaping or unknown block: the ivar's narrowing is dropped" do
    it "drops an ivar a stored callback or a lambda literal rebinds" do
      expect_types(<<~RUBY)
        class Callbacks
          def on_click(button)
            @clicked = false
            button.on_click { @clicked = true }
            assert_type("Dynamic[top]", @clicked)
          end

          def arrow
            @hit = false
            -> { @hit = true }
            assert_type("Dynamic[top]", @hit)
          end

          def thread
            @done = false
            Thread.new { @done = true }
            assert_type("Dynamic[top]", @done)
          end
        end
      RUBY
    end

    it "keeps the exact binding of an ivar the escaping block only reads" do
      expect_types(<<~RUBY)
        class ReadOnly
          def on_click(button)
            @seen = false
            button.on_click { puts @seen }
            assert_type("false", @seen)
          end
        end
      RUBY
    end

    it "no longer folds a flag a callback sets, and still folds one it leaves alone" do
      source = <<~RUBY
        class Button
          def run(button)
            @clicked = false
            button.on_click { @clicked = true }
            button.click
            puts "clicked" if @clicked
          end

          def untouched(button)
            @other = false
            button.on_click { |event| event }
            button.click
            puts "never" if @other
          end
        end
      RUBY

      expect(always_truthy_lines(source)).to eq([13])
    end
  end
end
