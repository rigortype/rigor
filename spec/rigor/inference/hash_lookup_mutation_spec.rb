# frozen_string_literal: true

require "spec_helper"

# `Hash#default=` / `Hash#default_proc=` / `Hash#compare_by_identity` leave the pair set alone but change what a read
# of it answers, and a literal `HashShape` kept its closed shape through all three. `counts = { a: 1 }; counts.default
# = 0` kept reading `counts[:b]` as `nil`, so `counts[:b] + 1` drew an error-level `call.undefined-method` where Ruby
# prints 1, and `counts[:b] == 0` folded always-falsey.
#
# Every example is paired with a control that makes a non-mutating call in the same position, and that control must
# keep the closed literal's `nil` for a missing key — without it, a seam that stopped answering `nil` altogether would
# pass the mutating half too.
RSpec.describe "Hash lookup mutation widening", type: :runner do
  def diagnostics(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # The flow folds and the call errors a stale `nil` read produces; the harness's own `include` / `dump_type`
  # draw `call.unresolved-toplevel`, which says nothing about the read.
  def rules(source)
    diagnostics(source).filter_map do |diagnostic|
      rule = diagnostic.rule.to_s
      rule if rule.start_with?("flow.", "call.") && rule != "call.unresolved-toplevel"
    end
  end

  describe "the straight-line seam" do
    it "answers untyped for a missing key after `default=`, and keeps the present key's value" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]", "1", "1", "Dynamic[top]", "[1, Dynamic[top]]"])
        counts = { a: 1 }
        counts.default = 0
        dump_type(counts[:b])
        dump_type(counts[:a])
        dump_type(counts.fetch(:a))
        dump_type(counts.dig(:b))
        dump_type(counts.values_at(:a, :b))
      RUBY
      expect(rules(<<~RUBY)).to be_empty
        counts = { a: 1 }
        counts.default = 0
        puts counts[:b] + 1
        puts "zero" if counts[:b] == 0
      RUBY
    end

    it "answers untyped for a missing key after `default_proc=`" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Dynamic[top] 1])
        h = { a: 1 }
        h.default_proc = proc { |_h, _k| 5 }
        dump_type(h[:b])
        dump_type(h[:a])
      RUBY
      expect(rules(<<~RUBY)).to be_empty
        h = { a: 1 }
        h.default_proc = proc { |_h, _k| 5 }
        puts h[:b] + 1
      RUBY
    end

    it "opens an empty literal, the common spelling of a counter" do
      expect(dumped_types(<<~RUBY)).to eq(["{ ... }", "Dynamic[top]", "{}", "nil"])
        counts = {}
        counts.default = 0
        dump_type(counts)
        dump_type(counts[:x])

        plain = {}
        plain.fetch(:x, 0)
        dump_type(plain)
        dump_type(plain[:x])
      RUBY
      expect(rules(<<~RUBY)).to be_empty
        counts = {}
        counts.default = 0
        %w[a b a].each { |w| counts[w] += 1 }
        puts counts["a"] + 1
      RUBY
    end

    it "reads `default` as untyped once it is set, and as nil on the closed literal" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Dynamic[top] nil])
        counts = { a: 1 }
        counts.default = 0
        dump_type(counts.default)

        plain = { a: 1 }
        dump_type(plain.default)
      RUBY
    end

    it "does not pin a missing key to a known value once a later mutation drops the shape" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top], Dynamic[top]]", "Hash[Symbol, 1]"])
        counts = { a: 1 }
        counts.default = 0
        counts.delete(:a)
        dump_type(counts)

        plain = { a: 1 }
        plain.delete(:a)
        dump_type(plain)
      RUBY
    end

    it "keeps the closed literal, and the genuine fold, under a non-mutating call" do
      expect(dumped_types(<<~RUBY)).to eq(%w[nil 1])
        counts = { a: 1 }
        counts.default
        dump_type(counts[:b])
        dump_type(counts[:a])
      RUBY
      expect(rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        counts = { a: 1 }
        counts.fetch(:a)
        puts "zero" if counts[:b] == 0
      RUBY
    end

    it "does not fold the size of a hash whose default proc can store" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Integer 1])
        h = { a: 1 }
        h.default_proc = proc { |hash, key| hash[key] = 5 }
        h[:b]
        dump_type(h.size)

        k = { a: 1 }
        k[:b]
        dump_type(k.size)
      RUBY
    end

    it "widens an instance variable's HashShape the same method gives a default" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Dynamic[top] nil])
        class Tally
          def defaulted
            @h = { a: 1 }
            @h.default = 0
            dump_type(@h[:b])
          end

          def kept
            @h = { a: 1 }
            @h.fetch(:a)
            dump_type(@h[:b])
          end
        end
      RUBY
    end

    it "widens every HashShape member of a Union" do
      expect(dumped_types(<<~RUBY)).to eq(["{ a: 1, ... } | { b: 2, ... }", "{ a: 1 } | { b: 2 }"])
        def defaulted(flag)
          u = flag ? { a: 1 } : { b: 2 }
          u.default = 0
          dump_type(u)
        end

        def kept(flag)
          u = flag ? { a: 1 } : { b: 2 }
          u.fetch(:a, 0)
          dump_type(u)
        end
      RUBY
    end

    # A `Union` receiver's `[]` reads through the RBS projection of each member, not through the shape tier, so the
    # join is asserted on the binding and on the read's diagnostics rather than on the read's type.
    it "joins a conditional `default=` with the branch that skipped it" do
      expect(dumped_types(<<~RUBY)).to eq(["{ a: 1 } | { a: 1, ... }"])
        def maybe(flag)
          h = { a: 1 }
          h.default = 0 if flag
          dump_type(h)
        end
      RUBY
      expect(rules(<<~RUBY)).to be_empty
        def maybe(flag)
          h = { a: 1 }
          h.default = 0 if flag
          h[:b] + 1
        end
      RUBY
    end
  end

  describe "`compare_by_identity`" do
    it "drops the shape of a String-keyed hash, whose literal key no longer finds its pair" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[String, Integer]", "Integer"])
        s = { "k" => 1 }
        s.compare_by_identity
        dump_type(s)
        dump_type(s["k"])
      RUBY
      expect(rules(<<~RUBY)).to be_empty
        s = { "k" => 1 }
        s.compare_by_identity
        puts "one" if s["k"] == 1
      RUBY
    end

    it "keeps the shape of a hash whose every key is an identity-stable literal" do
      expect(dumped_types(<<~RUBY)).to eq(["{ a: 1, 2 => 3, nil => 4 }", "1", "nil"])
        t = { a: 1, 2 => 3, nil => 4 }
        t.compare_by_identity
        dump_type(t)
        dump_type(t[:a])
        dump_type(t[:b])
      RUBY
    end

    it "drops a recorded read of the receiver, whose key may no longer find its pair" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top] | Integer", "1"])
        s = {}
        s["k"] ||= 1
        s.compare_by_identity
        dump_type(s["k"])

        t = {}
        t["k"] ||= 1
        t.compare_by_identity?
        dump_type(t["k"])
      RUBY
    end

    it "keeps the String-keyed literal under a non-mutating call" do
      expect(dumped_types(<<~RUBY)).to eq(["{ \"k\": 1 }", "1"])
        s = { "k" => 1 }
        s.compare_by_identity?
        dump_type(s)
        dump_type(s["k"])
      RUBY
    end
  end

  # ADR-56 slice A: a captured outer local mutated inside a block widens in the outer scope after the call.
  describe "the block-capture seam" do
    it "widens a captured HashShape the block gives a default, and keeps one the block only reads" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Dynamic[top] nil])
        b = { a: 1 }
        [1].each { b.default = 0 }
        dump_type(b[:z])

        c = { a: 1 }
        [1].each { c.fetch(:a) }
        dump_type(c[:z])
      RUBY
    end
  end

  # ADR-58: a literal ivar seed is widened at every method entry when some method in the class mutates the ivar.
  describe "the class-level ivar census" do
    it "widens an ivar seed another method gives a default, and keeps one another method only reads" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Dynamic[top] 1 nil])
        class Defaulted
          def initialize
            @h = { a: 1 }
            @h.default = 0
          end

          def peek
            dump_type(@h[:b])
            dump_type(@h[:a])
          end
        end

        class Kept
          def initialize = @h = { a: 1 }
          def read = @h.fetch(:a)
          def peek = dump_type(@h[:b])
        end
      RUBY
    end
  end

  # The per-element Tuple fold types every position from one entry scope; a captured literal the body mutates in
  # place is widened for that mutation first (`UnknownStoreWidening`), or every position reads the entry shape.
  describe "the per-element block fold" do
    it "does not pin a missing key's nil once the body gives the captured hash a default" do
      expect(dumped_types(<<~RUBY)).to eq(["[Dynamic[top], Dynamic[top]]"])
        h = { a: 1 }
        dump_type([1, 2].map { |i| v = h[:b]; h.default = i; v })
      RUBY
    end

    it "keeps the missing key's nil when the body only reads the captured hash" do
      expect(dumped_types(<<~RUBY)).to eq(["[nil, nil]"])
        h = { a: 1 }
        dump_type([1, 2].map { |i| v = h[:b]; h.fetch(:a); v })
      RUBY
    end
  end
end
