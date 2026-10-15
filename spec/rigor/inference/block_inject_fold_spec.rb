# frozen_string_literal: true

require "spec_helper"

# Block-form `inject` / `reduce` return-type fold.
#
# Part 1 (soundness): the RBS generic `(S) { (S, E) -> S } -> S` binds `S` from a SINGLE block pass (acc=seed,
# elem=element-join), so a multiplying accumulator over `(1..5)` typed `Integer[1..5]` against a runtime of 120 — an
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
      # Regression: this exact shape typed `Integer[1..5]` (runtime 120) — the single-pass accumulator bug. The folded
      # answer (Part 2) is the exact value; what MUST never reappear is the unsound interval.
      message = dumped_type("dump_type((1..5).inject(1) { |acc, i| acc * i })")
      expect(message).not_to include("Integer[1..5]")
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
      expect(message).not_to match(/Integer\[\d+\.\.\d+\]/)
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

  # Issue #1332 — both arms lay the #587 (b) captured-block binding, so a step reads a captured variable as an
  # earlier step may have left it. Each shape reads the capture BEFORE rebinding or mutating it, so the answer
  # depends on the previous iteration's write: Ruby gives `1` for every one, and a fold reading the entry binding
  # pinned `0` and reported the `t == 0` guard always-truthy.
  describe "a body that reads captured state an earlier step rebound or mutated" do
    def flow_diagnostics(source)
      analyze(source).diagnostics.select { |d| d.rule.to_s.start_with?("flow.") }
    end

    {
      "a rebound local" => ["n = 0", "r = a + n; n += 1; r"],
      "a rebound local under `reduce`" => ["n = 0", "r = a + n; n += 1; r", :reduce],
      "a `<<` on a captured Array" => ["log = []", "r = a + log.size; log << e; r"],
      "a rebound instance variable" => ["@n = 0", "r = a + @n; @n += 1; r"],
      "a memoizing index `||=`" => ["c = {}", "r = a + (c[:k] || 0); c[:k] ||= e; r"],
      "`push`" => ["arr = []", "r = a + arr.size; arr.push(e); r"],
      "`Hash#store`" => ["h = {}", "r = a + h.size; h.store(e, e); r"],
      "an index write" => ["h = {}", "r = a + h.size; h[e] = e; r"],
      "`String#concat`" => ["s = +''", "r = a + s.size; s.concat('z'); r"],
      "`replace`" => ["x = []", "r = a + x.size; x.replace([e]); r"],
      "a `<<` through a body-local alias" => ["log = []", "r = a + log.size; l2 = log; l2 << e; r"],
      "a self-call that mutates its argument" => [
        "def add(list, v) = list << v\nlog = []", "r = a + log.size; add(log, e); r"
      ]
    }.each do |label, (setup, body, method_name)|
      it "does not pin the result through #{label}" do
        source = "#{setup}\nt = [1, 2].#{method_name || :inject}(0) { |a, e| #{body} }\nputs 'x' if t == 0\n"
        expect(flow_diagnostics(source)).to be_empty
        expect(dumped_type("#{setup}\ndump_type([1, 2].#{method_name || :inject}(0) { |a, e| #{body} })"))
          .not_to eq("dump_type: 0")
      end
    end

    it "does not pin the no-seed form, whose first step is the second element" do
      source = "n = 0\nt = [1, 2, 3].inject { |a, e| r = a + n; n += 1; r }\nputs 'x' if t == 1\n"
      expect(flow_diagnostics(source)).to be_empty
    end

    it "still folds a body that captures nothing, with its true-positive guard" do
      expect(dumped_type("dump_type([1, 2].inject(0) { |a, e| a + e })")).to eq("dump_type: 3")
      expect(dumped_type("dump_type([1, 2].reduce(0) { |a, e| a + e })")).to eq("dump_type: 3")
      expect(flow_diagnostics("t = [1, 2].inject(0) { |a, e| a + e }\nputs 'x' if t == 3\n").map(&:rule))
        .to eq(["flow.always-truthy-condition"])
    end

    it "still folds a body that only stores into a sink it never reads" do
      expect(dumped_type("log = []\ndump_type([1, 2].inject(0) { |a, e| log << e; a + e })")).to eq("dump_type: 3")
    end

    it "still folds a body whose only write is to a block-local that shadows the capture" do
      expect(dumped_type("n = 0\ndump_type([1, 2].inject(0) { |a, e; n| n = 5; a + e })")).to eq("dump_type: 3")
    end
  end

  # Issue #1889 — the accumulator parameter holds the seed only on the first run. The statement pass and the ADR-56
  # write-back bound it to the seed on every run, so a capture assigned from it was written back as the seed: Ruby
  # leaves `m` at `1` below, Rigor kept `0` and reported the `m == 0` guard always-truthy.
  describe "a capture assigned from the accumulator" do
    def flow_diagnostics(source)
      analyze(source).diagnostics.select { |d| d.rule.to_s.start_with?("flow.") }
    end

    {
      "a seeded `inject`" => ["[1, 2].inject(0) { |a, e| m = a; a + e }", "m == 0"],
      "a seeded `reduce`" => ["[1, 2].reduce(0) { |a, e| m = a; a + e }", "m == 0"],
      "the no-seed form past the element union" => ["[1, 2, 4].inject { |a, e| m = a; a + e }", "m == 3"],
      "a capture computed from the accumulator (#1232)" => ["[1, 2].inject(0) { |a, e| m = a + e; m }", "m == 3"]
    }.each do |label, (call, guard)|
      it "does not pin the capture through #{label}" do
        expect(flow_diagnostics("m = 0\n#{call}\nputs 'x' if #{guard}\n")).to be_empty
      end
    end

    it "binds the accumulator parameter to the seed joined with the converged accumulator" do
      expect(dumped_type("[1, 2].inject(0) { |a, e| dump_type(a); a + e }")).to eq("dump_type: 0 | Integer")
      expect(dumped_type("m = 0\n[1, 2].inject(0) { |a, e| m = a; a + e }\ndump_type(m)"))
        .to eq("dump_type: 0 | Integer")
    end

    # Guards (this example and the next): the empty receiver and the element capture answered this before #1889.
    it "keeps the pre-call value when the block never runs" do
      expect(dumped_type("m = 0\n[].inject(0) { |a, e| m = a; a }\ndump_type(m)")).to start_with("dump_type: 0 |")
    end

    it "keeps the exact element union for a capture assigned from the element" do
      expect(dumped_type("m = 0\n[1, 2].inject(0) { |a, e| m = e; a + e }\ndump_type(m)"))
        .to eq("dump_type: 0 | 1 | 2")
    end

    # Guard: the call's own fold is untouched by the parameter binding.
    it "still folds the call itself to its constant" do
      expect(dumped_type("m = 0\ndump_type([1, 2].inject(0) { |a, e| m = a; a + e })")).to eq("dump_type: 3")
    end
  end
end
