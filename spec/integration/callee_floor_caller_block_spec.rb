# frozen_string_literal: true

# Issue #2397 — the callee mutation floor ran on a self-call at statement level, but not when the call sat inside a
# non-escaping block of the caller that captures the argument: `acc = [7, 9]; [1].each { poke(acc) }` kept `acc` at its
# literal, so `acc[0].upcase` reported `undefined method 'upcase' for 7` where Ruby prints `"X"`
# (`def poke(acc) = (acc[0] = "x")`).
#
# Ruby witnesses (Ruby 4.0): the `each`, `send` and singleton rows print `"X"`; `poke(acc.dup)` and a call whose `acc`
# is a block parameter or block-local leave the outer `acc[0]` at `7`, so `upcase` raises NoMethodError.
require "spec_helper"

RSpec.describe "a self-call in a caller's block floors the captured argument its callee mutates (#2397)",
               type: :runner do
  def errors(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map { |d| [d.line, d.qualified_rule] }
  end

  # `run` at lines 2-6, `acc[0].upcase` on line 5.
  def instance_run(call)
    <<~RUBY
      class Mut
        def run
          acc = [7, 9]
          #{call}
          acc[0].upcase
        end

        def poke(acc) = (acc[0] = "x")
      end
    RUBY
  end

  let(:undefined_upcase) { [[5, "call.undefined-method"]] }

  describe "silent where the block hands the captured local to the mutating callee" do
    {
      "an each block" => "[1].each { poke(acc) }",
      "a block nested in a block" => "[1].each { [2].each { poke(acc) } }",
      "a literal send hand-off" => "[1].each { send(:poke, acc) }"
    }.each do |label, call|
      it label do
        expect(errors(instance_run(call))).to eq([])
      end
    end

    # Conservative by design: Ruby never runs this block, so `upcase` raises on `7`. A block that may run counts, as
    # it does on the escaping path; the floor only forgets the literal, so it drops this report and adds none.
    it "a block that may run zero times (gives up a true positive)" do
      expect(errors(instance_run("0.times { poke(acc) }"))).to eq([])
    end

    it "a singleton caller's block calling a singleton callee" do
      expect(errors(<<~RUBY)).to eq([])
        class Mut
          def self.run
            acc = [7, 9]
            [1].each { send(:poke, acc) }
            [1].each { poke(acc) }
            acc[0].upcase
          end

          def self.poke(acc) = (acc[0] = "x")
        end
      RUBY
    end
  end

  describe "keeps the outer local where the block does not pass it" do
    {
      "a copy" => "[1].map { poke(acc.dup) }",
      "a block parameter shadowing it" => "[[1]].each { |acc| poke(acc) }",
      "a nested block's parameter shadowing it" => "[1].each { [[1]].each { |acc| poke(acc) } }",
      "a block-local shadowing it" => "[1].each { |i; acc| acc = [i]; poke(acc) }"
    }.each do |label, call|
      it label do
        expect(errors(instance_run(call))).to eq(undefined_upcase)
      end
    end
  end

  # The block-site floor answers what the statement-level floor answers for the same callee.
  it "binds the argument as a statement-level call would" do
    dumps = ["poke(acc)", "[1].each { poke(acc) }"].map do |call|
      result = analyze(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def poke(acc) = (acc[0] = "x")
        def run
          acc = [7, 9]
          #{call}
          dump_type(acc)
        end
      RUBY
      result.diagnostics.filter_map { |d| d.message.delete_prefix("dump_type: ") if d.message.start_with?("dump_type") }
    end
    expect(dumps).to eq([["Array[Dynamic[top]]"], ["Array[Dynamic[top]]"]])
  end
end
