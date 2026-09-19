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

      it "declines for a Dynamic receiver" do
        expect(dumped_type("def f(x) = dump_type(x.tap { break \"s\" })")).not_to eq('"s"')
      end
    end
  end
end
