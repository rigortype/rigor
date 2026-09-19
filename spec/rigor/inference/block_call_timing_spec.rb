# frozen_string_literal: true

require "spec_helper"

# Issue #1095 — a catalogued exactly-once immediate yielder (`tap` / `then` / `yield_self`) whose block can
# never complete normally never reaches its own return, so the call is its `break` arms alone.
#
# Every example that moves is paired with a neighbour that must NOT: a block that can complete, a callee that
# may skip its block, a block-pass the analysis cannot see into, and a receiver whose `tap` is not Kernel's.
RSpec.describe Rigor::Inference::BlockCallTiming do
  describe ".exactly_once_owner?" do
    it "catalogues Kernel's tap, then and yield_self" do
      %i[tap then yield_self].each do |name|
        expect(described_class.exactly_once_owner?("::Kernel", name)).to be(true)
      end
    end

    it "does not catalogue an Object-owned declaration or another Kernel method" do
      # `Object` is where an override written over Kernel's lands, so its declaration proves nothing.
      expect(described_class.exactly_once_owner?("Object", :tap)).to be(false)
      expect(described_class.exactly_once_owner?("Kernel", :loop)).to be(false)
    end
  end

  describe "the call's type", type: :runner do
    def dumped_type(source, sig: {})
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
      dumps = result.diagnostics.filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end
      dumps.first
    end

    let(:ints) { "ints = [1, 2].map { |x| x + 1 }\nflag = [true, false].sample\n" }

    describe "a block that never completes normally" do
      it "types an always-breaking tap as the break arm alone" do
        expect(dumped_type("#{ints}dump_type(ints.tap { break \"s\" })")).to eq('"s"')
      end

      it "keeps the receiver when the break is conditional" do
        expect(dumped_type("#{ints}dump_type(ints.tap { break \"s\" if flag })")).to eq('"s" | Array[Integer]')
      end

      it "types an always-raising tap as bot" do
        expect(dumped_type("#{ints}dump_type(ints.tap { raise \"x\" })")).to eq("bot")
      end

      it "keeps the receiver when the block only sometimes raises" do
        expect(dumped_type("#{ints}dump_type(ints.tap { raise \"x\" if flag })")).to eq("Array[Integer]")
      end

      it "unions only the break arms when the other paths raise" do
        expect(dumped_type(<<~RUBY)).to eq('"a"')
          #{ints}dump_type(ints.tap { if flag then break "a" else raise "b" end })
        RUBY
      end

      it "types a bare break as nil" do
        expect(dumped_type("#{ints}dump_type(ints.tap { break })")).to eq("nil")
      end

      it "types yield_self and then the same way, as they already were" do
        expect(dumped_type("dump_type(1.yield_self { break \"s\" })")).to eq('"s"')
        expect(dumped_type("dump_type(1.then { raise \"x\" })")).to eq("bot")
      end

      it "applies to numbered-parameter and `it` blocks" do
        expect(dumped_type("#{ints}dump_type(ints.tap { _1; break \"n\" })")).to eq('"n"')
        expect(dumped_type("#{ints}dump_type(ints.tap { it; break \"i\" })")).to eq('"i"')
      end

      it "applies to a receiver-less tap on a plain class" do
        expect(dumped_type(<<~RUBY)).to eq('"r"')
          class Plain
            def go = tap { break "r" }
          end
          dump_type(Plain.new.go)
        RUBY
      end

      it "applies to a union receiver when every member reaches Kernel#tap" do
        expect(dumped_type("dump_type(([1, nil].sample).tap { break 1 })")).to eq("1")
      end
    end

    describe "blocks that complete normally" do
      it "keeps the receiver past a `next`, which completes the block" do
        expect(dumped_type("#{ints}dump_type(ints.tap { next \"s\" })")).to eq("Array[Integer]")
      end

      it "keeps the receiver when a `next` arm sits beside a raise" do
        expect(dumped_type("#{ints}dump_type(ints.tap { next 1 if flag; raise \"y\" })")).to eq("Array[Integer]")
      end

      it "keeps the receiver when the break belongs to a nested block" do
        expect(dumped_type("#{ints}dump_type(ints.tap { [1].each { break 3 } })")).to eq("Array[Integer]")
      end

      it "keeps the receiver when a rescue lets the block complete" do
        expect(dumped_type(<<~RUBY)).to eq("Array[Integer]")
          #{ints}dump_type(ints.tap do
            raise "x"
          rescue StandardError
            nil
          end)
        RUBY
      end
    end

    # Review of #1095: the block-return pass's `bot` is not proof on its own — a body ending in a call whose RBS
    # merely declares `-> bot` (`Kernel#loop`) can still complete. A syntactic walk must agree.
    describe "the syntactic proof ANDed with the block-return pass" do
      def tap_type(body, prelude: "")
        dumped_type("#{ints}#{prelude}dump_type(ints.tap do\n#{body}\nend)")
      end

      {
        "raise" => 'raise "x"',
        "fail" => 'fail "x"',
        "Kernel.raise" => 'Kernel.raise "x"',
        "::Kernel.raise" => '::Kernel.raise "x"',
        "exit" => "exit 1",
        "abort" => 'abort "x"',
        "throw" => "throw :done",
        "redo" => "redo",
        "begin/rescue/retry" => "begin\n  raise \"x\"\nrescue StandardError\n  retry\nend",
        "a ternary whose arms both raise" => 'flag ? raise("a") : raise("b")',
        "an if whose arms both raise" => "if flag\n  raise \"a\"\nelse\n  fail \"b\"\nend",
        "raise under an ensure" => "begin\n  raise \"x\"\nensure\n  puts 1\nend"
      }.each do |label, body|
        it "types #{label} as bot" do
          expect(tap_type(body)).to eq("bot")
        end
      end

      it "types a block-level return as bot" do
        expect(dumped_type(<<~RUBY)).to eq("bot")
          def run
            xs = [1, 2].map { |x| x + 1 }
            dump_type(xs.tap { return 1 })
          end
        RUBY
      end

      # The syntactic walk accepts both shapes, but the block-return pass does not type them `bot` (it did not
      # on the first head of this change either), and both proofs must hold. Conservative, not wrong: the
      # answer is master's. Flip these to `bot` when the block-return pass learns `self.raise` and a raise
      # inside an element position.
      it "keeps the receiver for self.raise and a raise inside an array literal, as master does" do
        expect(tap_type('self.raise "x"')).to eq("Array[Integer]")
        expect(tap_type('[raise("x")]')).to eq("Array[Integer]")
      end

      {
        "loop { break }" => "loop { break }",
        "loop { e.next }" => "loop { e.next }",
        "while + break" => "while flag\n  break\nend",
        "until + break" => "until flag\n  break\nend",
        "begin/rescue" => "begin\n  raise \"x\"\nrescue StandardError\n  nil\nend",
        "a rescue modifier" => 'raise("x") rescue nil',
        "catch/throw" => "catch(:done) { throw :done }",
        "a conditional raise" => 'raise "x" if flag',
        "a raise under && " => 'flag && raise("x")',
        "a nested block's break" => "[1].each { break 3 }",
        "0.times { raise }" => '0.times { raise "x" }'
      }.each do |label, body|
        it "keeps the receiver for #{label}" do
          expect(tap_type(body, prelude: "e = [1, 2].each\n")).to eq("Array[Integer]")
        end
      end

      it "keeps the receiver for a user-level method named raise at the top level" do
        expect(tap_type('raise "x"', prelude: "def raise(*) = nil\n")).to eq("Array[Integer]")
      end
    end

    # Re-review of #1095: the block-return pass types a self-call to a project-overridden `raise` / `exit` as
    # Kernel's `bot` too, so only the syntactic walk can see the override — and any project definition of the
    # name declines it.
    describe "project overrides of the non-returning names" do
      let(:cli) do
        <<~RUBY
          module SoftExit
            def exit(*) = nil
          end

          class Cli
            include SoftExit

            def raise(*) = :swallowed
            def abort(*) = nil
            def self.exit(*) = nil
            def flag = [true, false].sample

            def self.go = dump_type([1, 2].tap { exit })

            def via_raise
              ints = [2, 3].map { |x| x + 1 }
              dump_type(ints.tap { raise "x" })
            end

            def via_exit
              ints = [2, 3].map { |x| x + 1 }
              dump_type(ints.tap { exit })
            end

            def via_abort
              ints = [2, 3].map { |x| x + 1 }
              dump_type(ints.tap { abort })
            end

            def via_self_raise
              ints = [2, 3].map { |x| x + 1 }
              dump_type(ints.tap { self.raise "x" })
            end

            def via_fail
              ints = [2, 3].map { |x| x + 1 }
              dump_type(ints.tap { fail "x" })
            end

            def symptom
              ints = [2, 3].map { |x| x + 1 }
              s = flag ? ints.tap { raise "boom" } : "str"
              s.push(1) if s.respond_to?(:push)
            end
          end

          class Sub < Cli
            def go2
              ints = [2, 3].map { |x| x + 1 }
              dump_type(ints.tap { raise "x" })
            end
          end
        RUBY
      end

      let(:result) { analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{cli})) }

      # The dumps in source order: `self.go`, `via_raise`, `via_exit`, `via_abort`, `via_self_raise`,
      # `via_fail`, `Sub#go2`.
      def dumps
        result.diagnostics.select { |d| d.message.start_with?("dump_type") }.sort_by(&:line)
              .map { |d| d.message.delete_prefix("dump_type: ") }
      end

      it "keeps the receiver for an overridden raise, exit, abort and self.raise" do
        expect(dumps[1..4]).to eq(["Array[Integer]"] * 4)
      end

      it "keeps the receiver on the singleton side and in an inheriting subclass" do
        expect(dumps.first).not_to eq("bot")
        expect(dumps.last).to eq("Array[Integer]")
      end

      it "still types the un-overridden fail as bot" do
        expect(dumps[5]).to eq("bot")
      end

      it "fires no undefined method on the ternary's other arm" do
        expect(result.diagnostics.map(&:rule)).not_to include("call.undefined-method")
      end
    end

    # Re-review of #1095: `Scope#discovered_methods` withholds a plain `def` from ANOTHER file, so an override
    # of a non-returning name on a cross-file superclass slipped through. Two files are the whole point here.
    describe "a cross-file override of a non-returning name" do
      def cross_file_dumps(base)
        caller_source = <<~RUBY
          require "rigor/testing"
          include Rigor::Testing

          class B < A
            def go
              dump_type([1, 2].map { |x| x + 1 }.tap { abort })
            end

            def self.cgo
              dump_type([1, 2].map { |x| x + 1 }.tap { exit! })
            end

            def positive
              dump_type([1, 2].map { |x| x + 1 }.tap { fail "x" })
            end

            def symptom(flag)
              s = flag ? [1, 2].tap { abort } : "str"
              s.push(1) if s.respond_to?(:push)
            end
          end
        RUBY
        result = analyze(files: { "a.rb" => base, "b.rb" => caller_source })
        dumps = result.diagnostics.select { |d| d.message.start_with?("dump_type") }.sort_by(&:line)
        [dumps.map { |d| d.message.delete_prefix("dump_type: ") }, result.diagnostics.map(&:rule)]
      end

      let(:base_overrides) do
        <<~RUBY
          class A
            def abort(*) = nil
            def self.exit!(*) = nil
          end
        RUBY
      end

      it "keeps the receiver for an instance-side and a singleton-side override in another file" do
        dumps, rules = cross_file_dumps(base_overrides)
        expect(dumps[0..1]).to eq(["Array[Integer]"] * 2)
        expect(rules).not_to include("call.undefined-method")
      end

      it "still types the un-overridden fail beside them as bot" do
        dumps, = cross_file_dumps(base_overrides)
        expect(dumps[2]).to eq("bot")
      end

      it "types abort and exit! as bot when the other file overrides nothing" do
        dumps, = cross_file_dumps("class A\n  def unrelated = 1\nend\n")
        expect(dumps[0..1]).to eq(%w[bot bot])
      end
    end

    describe "the review's `loop` repros produce no diagnostic" do
      def diagnostics_for(source)
        analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics
      end

      let(:drainer) do
        <<~RUBY
          class Drainer
            def initialize = (@e = [1, 2].each)
            def flag = [true, false].sample
            def optional
              u = flag ? [].tap { |a| loop { a << @e.next } } : nil
              u.push(2) if u
            end
            def either
              s = flag ? [].tap { |a| loop { a << @e.next } } : "str"
              s.push(1) if s.respond_to?(:push)
            end
          end
        RUBY
      end

      it "fires no always-falsey condition and no undefined method on the drained-enumerator tap" do
        rules = diagnostics_for(drainer).map(&:rule)
        expect(rules & %w[flow.always-truthy-condition call.undefined-method]).to be_empty
      end

      it "still fires on the positive neighbour whose tap block really always raises" do
        # The same shape with `raise` in place of the drain: the tap IS bot there, so the condition is
        # provably falsey and the flow rule is right to say so.
        source = drainer.sub("[].tap { |a| loop { a << @e.next } } : nil", '[].tap { |_a| raise "x" } : nil')
        expect(diagnostics_for(source).map(&:rule)).to include("flow.always-truthy-condition")
      end

      it "keeps a rescue-modifier nil only possible, not definite" do
        messages = diagnostics_for(<<~RUBY).map(&:message)
          def run
            e = [1].each
            t = [].tap { |a| loop { a << e.next } } rescue nil
            t.size
          end
        RUBY
        expect(messages.grep(/for nil/)).to be_empty
      end
    end

    describe "callees without the summary" do
      it "keeps each's receiver beside an unconditional break" do
        # `each` may never yield on an empty receiver, so its normal return stays reachable.
        expect(dumped_type("#{ints}dump_type(ints.each { break \"s\" })")).to eq('"s" | Array[Integer]')
      end

      it "keeps each_with_object's memo beside an unconditional break" do
        expect(dumped_type("#{ints}dump_type(ints.each_with_object([]) { break \"s\" })")).not_to eq('"s"')
      end
    end

    describe "block-passes" do
      it "keeps today's answer for a proc block-pass, which cannot be proven to break" do
        expect(dumped_type("#{ints}blk = proc { break 1 }\ndump_type(ints.tap(&blk))")).to eq("Array[Integer]")
      end

      it "keeps today's answer for a symbol block-pass" do
        expect(dumped_type("#{ints}dump_type(ints.tap(&:freeze))")).to eq("Array[Integer]")
      end
    end

    describe "receivers whose method is not Kernel's" do
      it "declines for a class that defines its own tap" do
        # The override may return without yielding; the positive neighbour is the Plain example above.
        expect(dumped_type(<<~RUBY)).to eq('"s" | Mine')
          class Mine
            def tap
              :never
            end
          end
          dump_type(Mine.new.tap { break "s" })
        RUBY
      end

      it "declines for a subclass inheriting a project override" do
        expect(dumped_type(<<~RUBY)).to eq('"s" | Kid')
          class Base
            def tap = :never
          end
          class Kid < Base; end
          dump_type(Kid.new.tap { break "s" })
        RUBY
      end

      it "declines for a class whose project RBS declares its own tap" do
        sig = { "sigd.rbs" => "class Sigd\n  def tap: () { (self) -> void } -> self\nend\n" }
        expect(dumped_type(<<~RUBY, sig: sig)).to eq('"s" | Sigd')
          class Sigd; end
          dump_type(Sigd.new.tap { break "s" })
        RUBY
      end

      it "applies to a project-RBS class that inherits Kernel's tap" do
        sig = { "sigd.rbs" => "class Sigd\n  def size: () -> Integer\nend\n" }
        expect(dumped_type(<<~RUBY, sig: sig)).to eq('"s"')
          class Sigd; end
          dump_type(Sigd.new.tap { break "s" })
        RUBY
      end

      it "declines everywhere once the project monkey-patches Object#tap" do
        expect(dumped_type(<<~RUBY)).to eq('"s" | Array[Integer]')
          class Object
            def tap = :patched
          end
          #{ints}dump_type(ints.tap { break "s" })
        RUBY
      end

      it "applies to a core class object's inherited tap" do
        expect(dumped_type("dump_type(String.tap { break \"s\" })")).to eq('"s"')
      end

      it "declines for a class object whose signature declares its own singleton tap" do
        sig = { "sigd.rbs" => "class Sigd\n  def self.tap: () { (singleton(Sigd)) -> void } -> singleton(Sigd)\nend\n" }
        expect(dumped_type(<<~RUBY, sig: sig)).not_to eq('"s"')
          class Sigd; end
          dump_type(Sigd.tap { break "s" })
        RUBY
      end

      it "declines for a project class object no signature describes" do
        # Its singleton ancestry (superclass chain, `extend`s) is not resolved here, so the union stays.
        expect(dumped_type(<<~RUBY)).to eq('"s" | singleton(Plain)')
          class Plain; end
          dump_type(Plain.tap { break "s" })
        RUBY
      end

      it "declines for a project class whose superclass no signature describes" do
        # The unresolvable ancestor may define `tap`; uncertainty keeps the union.
        expect(dumped_type(<<~RUBY)).to eq('"s" | Rec')
          class Rec < SomeGem::Base; end
          dump_type(Rec.new.tap { break "s" })
        RUBY
      end

      it "applies to a project class whose external ancestors are RBS-known" do
        expect(dumped_type(<<~RUBY)).to eq('"s"')
          class Err < StandardError
            include Comparable
          end
          dump_type(Err.new.tap { break "s" })
        RUBY
      end

      it "declines once the project reopens a core mixin with its own tap" do
        expect(dumped_type(<<~RUBY)).to eq('"s" | Array[Integer]')
          module Enumerable
            def tap = :x
          end
          #{ints}dump_type(ints.tap { break "s" })
        RUBY
      end

      %w[Module Class].each do |root|
        it "declines for a class object once the project patches #{root}#tap" do
          expect(dumped_type(<<~RUBY)).not_to eq('"s"')
            class #{root}
              def tap = :x
            end
            dump_type(String.tap { break "s" })
          RUBY
        end
      end

      it "declines for a Dynamic receiver" do
        expect(dumped_type("def f(x) = dump_type(x.tap { break \"s\" })")).not_to eq('"s"')
      end
    end
  end
end
