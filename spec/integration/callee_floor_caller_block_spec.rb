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
        def kpoke(acc:) = (acc[0] = "x")
        def foo(x) = x
      end
    RUBY
  end

  let(:undefined_upcase) { [[5, "call.undefined-method"]] }

  describe "silent where the block hands the captured local to the mutating callee" do
    {
      "an each block" => "[1].each { poke(acc) }",
      "a block nested in a block" => "[1].each { [2].each { poke(acc) } }",
      "a literal send hand-off" => "[1].each { send(:poke, acc) }",
      "a keyword argument" => "[1].each { kpoke(acc: acc) }",
      "a keyword shorthand" => "[1].each { kpoke(acc:) }",
      "a block on a receiver of the statement" => "[1].each { poke(acc) }.size",
      "a block on a receiver of an assigned value" => "x = [1].each { poke(acc) }.size; foo(x)",
      "a block on a receiver whose call has its own block" => "[1].each { poke(acc) }.then { 1 }",
      "a then block on a chained receiver" => "1.then { poke(acc) }.to_s",
      "a block on an argument" => "foo([1].each { poke(acc) })"
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

    # `poke` inside `instance_eval` runs on the `Obj`, whose `poke` does not mutate.
    it "a self-call in a nested block run on another object" do
      source = instance_run("[1].each { Obj.new.instance_eval { poke(acc) } }") + "class Obj\n  def poke(acc) = acc.size\nend\n"
      expect(errors(source)).to eq(undefined_upcase)
    end

    it "a lambda in the block that is never called" do
      expect(errors(instance_run("[1].each { l = -> { poke(acc) }; foo(l) }"))).to eq(undefined_upcase)
    end

    it "a Set block parameter shadowing it" do
      result = analyze(<<~RUBY)
        require "set"
        require "rigor/testing"
        include Rigor::Testing
        def addx(s) = s.add("x")
        def run
          s = Set[7]
          [Set[1]].each { |s| addx(s) }
          dump_type(s)
        end
      RUBY
      dumps = result.diagnostics.filter_map do |d|
        d.message.delete_prefix("dump_type: ") if d.message.start_with?("dump_type")
      end
      expect(dumps).to eq(["Set[7]"])
    end
  end

  # Conservative by design: Ruby leaves `acc` at `[1, 2]`, so `upcase` raises on `1`. The floor applies after the
  # block's write-back, so it forgets the rebind as well; it drops this report and adds none.
  it "floors over a rebind later in the block (gives up a true positive)" do
    expect(errors(instance_run("[1].each { poke(acc); acc = [1, 2] }"))).to eq([])
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
