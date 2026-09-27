# frozen_string_literal: true

require "spec_helper"

# Issue #1468 — Ruby evaluates the arguments and block of `recv&.m(…)` only once `recv` is non-nil, so a read of
# `recv` inside them must not report `call.possible-nil-receiver`. Pinned at the diagnostic level, like
# `safe_nav_chain_narrowing_spec.rb`, because the contract is the absence of that false positive. Each silent
# shape is paired with one that must keep firing: the narrowing is of the receiver alone, holds only inside the
# call's operands, and stops where the operands rebind the receiver.
RSpec.describe "safe-navigation argument narrowing (#1468)" do
  def nil_receiver_lines(body)
    source = <<~RUBY
      class Box
        def initialize(v)
          @v = v
        end

        def run(value)
          @v = value
        end

        def two(value)
          yield value
        end
      end

      def f(c, a)
      #{body.gsub(/^/, '  ')}
      end
    RUBY
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
    diagnostics = guarded_run_source(runner, source: source, path: "mem.rb").diagnostics
    body_offset = source.lines.index { |line| line.start_with?("def f") } + 2
    # A receiver read as `nil` alone reports `call.undefined-method` rather than the union's rule.
    rules = %w[call.possible-nil-receiver call.undefined-method]
    diagnostics.select { |d| rules.include?(d.rule) }.map { |d| d.line - body_offset }
  end

  describe "must narrow" do
    it "reads the receiver non-nil in the arguments and the block" do
      expect(nil_receiver_lines(<<~RUBY)).to be_empty
        b = c ? Box.new(a) : nil
        b&.two(b.run(1)) { b.run(2) }
      RUBY
    end

    it "narrows a call in a value position" do
      expect(nil_receiver_lines(<<~RUBY)).to be_empty
        s = c ? "s" : nil
        puts(s&.concat(s.upcase))
        [s&.index(s.upcase, s.size), s&.each_char { s.size }]
      RUBY
    end

    it "narrows through the `&.` links of a chain" do
      expect(nil_receiver_lines(<<~RUBY)).to be_empty
        s = c ? "s" : nil
        s&.index(s.upcase)&.clamp(s.size, s.size)
      RUBY
    end

    it "reads a later argument from an earlier argument's write" do
      expect(nil_receiver_lines(<<~RUBY)).to be_empty
        s = c ? "s" : nil
        s&.insert(n = s.size, s.upcase * n)
      RUBY
    end
  end

  describe "must keep firing" do
    it "reports a different nilable local in the arguments" do
      expect(nil_receiver_lines(<<~RUBY)).to eq([2])
        s = c ? "s" : nil
        t = c ? nil : "t"
        s&.concat(t.upcase)
      RUBY
    end

    it "reports the receiver after the call" do
      expect(nil_receiver_lines(<<~RUBY)).to eq([2])
        s = c ? "s" : nil
        s&.concat(s.upcase)
        s.upcase
      RUBY
    end

    it "reports the receiver an earlier argument rebound" do
      expect(nil_receiver_lines(<<~RUBY)).to eq([1, 2])
        b = c ? Box.new(a) : nil
        b&.two(b = nil, b.run(1))
        b&.two(b = nil) { b.run(2) }
      RUBY
    end

    # A `return` or `yield` operand is not threaded by the evaluator, so only the scope index reads these.
    it "reports the receiver an earlier argument rebound under `return` and `yield`" do
      expect(nil_receiver_lines(<<~RUBY)).to eq([2, 3])
        s = c ? "s" : nil
        t = c ? "t" : nil
        yield s&.concat((s = nil).to_s, s.upcase)
        return t&.concat((t = nil).to_s, t.upcase)
      RUBY
    end

    it "reports the receiver a chain link's arguments rebound" do
      expect(nil_receiver_lines(<<~RUBY)).to eq([1])
        s = c ? "s" : nil
        s&.concat(s = nil)&.concat(s.upcase)
      RUBY
    end

    # The block may run again after the write: `each` reaches `x.size` a second time with `x` nil.
    it "reports the receiver a repeating block rebinds" do
      expect(nil_receiver_lines(<<~RUBY)).to eq([2, 3])
        x = c ? [a] : nil
        y = c ? [a] : nil
        x&.each { x.size; x = nil }
        puts(y&.each { y.size; y = nil })
      RUBY
    end
  end
end
