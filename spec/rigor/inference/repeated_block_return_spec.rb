# frozen_string_literal: true

require "spec_helper"

# Issue #2123 — a `return` inside a block exits the enclosing method, and the method's inferred return type MUST join
# it whenever the analysis reaches it. A block its call may run more than once reaches some `return`s only on a later
# run, after a captured local it rebinds has moved: every statement pass entered at a binding the first runs hold (the
# ADR-56 write-back's capped fixpoint widens its last assumption without running a pass from it), so the `return` was
# never reached, `within?` inferred `true`, and a caller's `if` on it was reported always falsey on correct code.
RSpec.describe "Return arms of a repeating block", type: :runner do
  def dumped_type(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    dumps = result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
    dumps.first
  end

  def diagnostic_rules(source)
    analyze(source).diagnostics.map(&:rule)
  end

  it "joins the return arm into the method's type over an untyped receiver" do
    expect(dumped_type(<<~RUBY)).to eq("bool")
      def within?(items)
        seen = 0
        items.each { return false if (seen += 1) > 3 }
        true
      end
      def probe(items) = within?(items)
      dump_type(probe(ARGV))
    RUBY
  end

  it "does not report the caller's condition on correct code (the issue's reproducer)" do
    expect(diagnostic_rules(<<~RUBY)).not_to include("flow.always-truthy-condition")
      def within?(items)
        seen = 0
        items.each { return false if (seen += 1) > 3 }
        true
      end

      def over?(items) = !within?(items)

      def use(items)
        return :big if over?(items)
        :small
      end
    RUBY
  end

  # The write-back's fixpoint passes enter at `0`, `0 | 1` and `0 | 1 | 2`; only the capped widening reaches `> 3`.
  it "joins an arm only the capped write-back binding reaches, over a typed receiver" do
    expect(dumped_type(<<~RUBY)).to eq("bool")
      def within?
        seen = 0
        [1, 2, 3, 4, 5].each { return false if (seen += 1) > 3 }
        true
      end
      dump_type(within?)
    RUBY
  end

  {
    "times" => "5.times { return :ret if (n += 1) > 5 }",
    "Kernel#loop" => "loop { return :ret if (n += 1) > 5 }"
  }.each do |label, block|
    it "joins the arm of #{label}" do
      expect(dumped_type("def m\n  n = 0\n  #{block}\n  :fall\nend\ndump_type(m)")).to eq(":fall | :ret")
    end
  end

  # A guard: the passes over the nested block already reached this arm before the fix.
  it "joins the arm of a nested block" do
    expect(dumped_type(<<~RUBY)).to eq(":fall | :ret")
      def m
        n = 0
        ARGV.each { [1, 2].each { return :ret if (n += 1) > 5 } }
        :fall
      end
      dump_type(m)
    RUBY
  end

  it "joins a bare return as nil" do
    expect(dumped_type(<<~RUBY)).to eq(":fall?")
      def m
        n = 0
        ARGV.each { return if (n += 1) > 5 }
        :fall
      end
      dump_type(m)
    RUBY
  end

  it "joins the arm a rebound instance variable reaches" do
    expect(dumped_type(<<~RUBY)).to eq(":fall | :ret")
      class C
        def m
          @n = 0
          ARGV.each { return :ret if (@n += 1) > 5 }
          :fall
        end
      end
      dump_type(C.new.m)
    RUBY
  end

  # Guards: barriers and once-run blocks keep the answer they had.
  {
    "a lambda" => "ARGV.each { -> { return :ret if (n += 1) > 5 }.call }",
    "a define_method block" => "self.class.define_method(:zz) { return :ret if (n += 1) > 5 }",
    "a block run once" => "1.then { return :ret if (n += 1) > 5 }",
    "a break" => "ARGV.each { break :ret if (n += 1) > 5 }"
  }.each do |label, block|
    it "does not join an arm under #{label}" do
      expect(dumped_type("def m\n  n = 0\n  #{block}\n  :fall\nend\ndump_type(m)")).to eq(":fall")
    end
  end
end
