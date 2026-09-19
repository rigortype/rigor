# frozen_string_literal: true

require "spec_helper"

# Issue #1107 — `Kernel#loop` is declared `() { () -> void } -> bot`, but it rescues a `StopIteration` its block
# raises and returns that exception's `result`. The enumerator-draining idiom `loop { out << e.next }` therefore
# returns normally, and trusting the `bot` made correct code report an always-falsey condition or an undefined
# method on the surviving arm of a ternary. The normal return is `untyped` (`StopIteration#result`'s declared
# type) unless the body provably cannot raise, and every widening example is paired with one that keeps `bot`.
RSpec.describe "Kernel#loop completion on StopIteration", type: :runner do
  def dumped_type(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    dumps = result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
    dumps.first
  end

  def diagnostic_rules(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics.map(&:rule)
  end

  let(:drain) { "e = [1, 2].each\n" }

  describe "a body that may raise StopIteration" do
    it "types the enumerator-draining loop as untyped, not bot" do
      expect(dumped_type("#{drain}dump_type(loop { e.next })")).to eq("Dynamic[top]")
    end

    it "keeps the break arm beside the StopIteration exit" do
      expect(dumped_type(<<~RUBY)).to eq('"hit" | Dynamic[top]')
        #{drain}dump_type(loop { break "hit" if e.next == 2 })
      RUBY
    end

    it "widens the Kernel. and self. spellings and a block-pass" do
      expect(dumped_type("#{drain}dump_type(Kernel.loop { e.next })")).to eq("Dynamic[top]")
      expect(dumped_type("#{drain}dump_type(self.loop { e.next })")).to eq("Dynamic[top]")
      expect(dumped_type("blk = proc { 1 }\ndump_type(loop(&blk))")).to eq("Dynamic[top]")
    end

    it "does not type a method whose body ends in the loop as bot" do
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
        def drain_all(e)
          loop { e.next }
        end
        #{drain}dump_type(drain_all(e))
      RUBY
    end

    # Conservative, not wrong: `raise "x"` is a call, and the walk does not tell it from
    # `raise StopIteration`, which really does end the loop with `nil`.
    it "widens a body that only raises, since the raise could be a StopIteration" do
      expect(dumped_type('dump_type(loop { raise "x" })')).to eq("Dynamic[top]")
    end
  end

  describe "a body that provably cannot raise" do
    {
      "an empty body" => "loop {}",
      "a bare next" => "loop { next }",
      "locals and literals only" => "loop { x = 1; x = [x, :s] }"
    }.each do |label, call|
      it "keeps bot for #{label}" do
        expect(dumped_type("dump_type(#{call})")).to eq("bot")
      end
    end

    it "keeps a call-free break arm exact (#853)" do
      expect(dumped_type("dump_type(loop { break 5 })")).to eq("5")
      expect(dumped_type("flag = true\ndump_type(loop { break 1 if flag; break \"s\" })")).to eq('"s" | 1')
    end
  end

  describe "other methods named loop" do
    it "keeps the declared bot of a loop called on an explicit receiver" do
      expect(dumped_type(<<~RUBY)).to eq("bot")
        class Spinner
          def loop = raise("never returns")
        end
        #{drain}dump_type(Spinner.new.loop { e.next })
      RUBY
    end

    it "leaves the blockless loop an Enumerator" do
      expect(dumped_type("dump_type(loop)")).to start_with("Enumerator[")
    end
  end

  describe "the issue's repros" do
    let(:source) do
      <<~RUBY
        class Drainer
          def initialize = (@e = [1, 2].each)
          def flag = [true, false].sample
          def optional
            u = flag ? [].then { |a| loop { a << @e.next } } : nil
            u.push(2) if u
          end
          def either
            s = flag ? [].then { |a| loop { a << @e.next } } : "str"
            s.push(1) if s.respond_to?(:push)
          end
        end
      RUBY
    end

    it "fires no always-falsey condition and no undefined method through then" do
      expect(diagnostic_rules(source) & %w[flow.always-truthy-condition call.undefined-method]).to be_empty
    end

    it "still fires on the positive neighbour whose loop body cannot raise" do
      # `loop {}` really never returns, so the `then` IS bot and the condition is provably falsey.
      neighbour = source.sub("[].then { |a| loop { a << @e.next } } : nil", "[].then { |_a| loop {} } : nil")
      expect(diagnostic_rules(neighbour)).to include("flow.always-truthy-condition")
    end
  end
end
