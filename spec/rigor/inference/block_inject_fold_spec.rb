# frozen_string_literal: true

require "spec_helper"

# Block-form `inject` / `reduce` return-type fold.
#
# Part 1 (soundness): the RBS generic `(S) { (S, E) -> S } -> S` binds `S` from a SINGLE block pass (acc=seed,
# elem=element-join), so a multiplying accumulator over `(1..5)` typed `int<1, 5>` against a runtime of 120 — an
# interval the runtime escapes. The accumulator now reaches a capped fixpoint, converging to the nominal carrier.
#
# Part 2 (precision): a fully-constant finite receiver threads the running constant through per-element block evaluation
# to the exact folded value.
RSpec.describe "block-form inject/reduce fold", type: :runner do
  def dumped_type(source)
    result = analyze(<<~RUBY)
      require "rigor/testing"
      include Rigor::Testing
      #{source}
    RUBY
    result.diagnostics.find { |d| d.message.start_with?("dump_type") }&.message
  end

  describe "Part 1 — soundness (no value-bounded interval the runtime escapes)" do
    it "the multiplying accumulator over a constant range never types a value interval" do
      # Regression: this exact shape typed `int<1, 5>` (runtime 120) — the single-pass accumulator bug. The folded
      # answer (Part 2) is the exact value; what MUST never reappear is the unsound interval.
      message = dumped_type("dump_type((1..5).inject(1) { |acc, i| acc * i })")
      expect(message).not_to include("int<1, 5>")
      expect(message).to include("120")
    end

    it "the no-seed summing accumulator over a constant Tuple never types the element union" do
      # Regression: this typed `1 | 2 | 3` (runtime 6) — out of the set.
      message = dumped_type("dump_type([1, 2, 3].inject { |a, b| a + b })")
      expect(message).not_to include("1 | 2 | 3")
      expect(message).to include("6")
    end

    it "an unknown-receiver multiply converges to the nominal carrier, not an interval" do
      message = dumped_type(<<~RUBY)
        m = rand(100)
        dump_type((1..m).inject(1) { |acc, i| acc * i })
      RUBY
      expect(message).to include("Integer")
      expect(message).not_to match(/int<\d+, \d+>/)
    end

    it "an unknown-receiver no-seed sum converges to the element carrier" do
      message = dumped_type(<<~RUBY)
        arr = [rand, rand]
        dump_type(arr.inject { |a, b| a + b })
      RUBY
      expect(message).to include("Float")
    end
  end

  describe "Part 2 — constant accumulator threading" do
    it "folds a seeded constant-range factorial to its exact value" do
      message = dumped_type("dump_type((1..5).inject(1) { |acc, i| acc * i })")
      expect(message).to include("120")
    end

    it "folds a no-seed constant-Tuple sum to its exact value" do
      message = dumped_type("dump_type([1, 2, 3].inject { |a, b| a + b })")
      expect(message).to include("6")
    end

    it "folds the factorial-def chain through per-call adoption" do
      message = dumped_type(<<~RUBY)
        def block_factorial(n) = (1..n).inject(1) { |acc, i| acc * i }
        dump_type(block_factorial(5))
      RUBY
      expect(message).to include("120")
    end
  end

  describe "declines (fall through to the sound nominal fixpoint)" do
    it "declines the size cap fast — a million-element range never enumerates" do
      message = dumped_type("dump_type((1..1_000_000).inject(0) { |acc, i| acc + i })")
      expect(message).to include("Integer")
    end

    it "declines the magnitude cap — a ~296-bit bignum factorial" do
      message = dumped_type("dump_type((1..64).inject(1) { |acc, i| acc * i })")
      expect(message).to include("Integer")
      expect(message).not_to match(/\d{20,}/)
    end
  end

  describe "captured-local write-back still runs for a fold that also mutates" do
    it "keeps the accumulator fold AND writes the mutated capture back" do
      result = analyze(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        sink = []
        total = [1, 2, 3].inject(0) { |acc, x| sink << x; acc + x }
        dump_type(total)
        dump_type(sink)
      RUBY
      messages = result.diagnostics.select { |d| d.message.start_with?("dump_type") }.map(&:message)
      expect(messages[0]).to include("6")
      # Write-back: `sink` carries the appended element types, proving the ADR-56 statement-level write-back ran despite
      # this fold answering the call's return type.
      expect(messages[1]).to include("Array")
      expect(messages[1]).to match(/1.*2.*3/)
    end
  end
end
