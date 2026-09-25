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
  def diagnostics(source, sig = {})
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # The flow folds and the call errors a stale `nil` read produces; the harness's own `include` / `dump_type`
  # draw `call.unresolved-toplevel`, which says nothing about the read.
  def rules(source, sig: {})
    diagnostics(source, sig).filter_map do |diagnostic|
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

    # A `Union` receiver's `[]` reads each member through its RBS projection rather than the shape tier. A reopened
    # member's projection carries a `Dynamic[top]` arm, so a missing key does not read as the known values alone.
    it "widens every HashShape member of a Union" do
      reopened = ["{ a: 1, ... } | { b: 2, ... }", "1 | 2 | Dynamic[top]"]
      expect(dumped_types(<<~RUBY)).to eq([*reopened, "{ a: 1 } | { b: 2 }"])
        def defaulted(flag)
          u = flag ? { a: 1 } : { b: 2 }
          u.default = 0
          dump_type(u)
          dump_type(u[:c])
        end

        def kept(flag)
          u = flag ? { a: 1 } : { b: 2 }
          u.fetch(:a, 0)
          dump_type(u)
        end
      RUBY
      expect(rules(<<~RUBY)).to be_empty
        def defaulted(flag)
          u = flag ? { a: 1 } : { b: 2 }
          u.default = 0
          puts "zero" if u[:c] == 0
        end
      RUBY
    end

    it "joins a conditional `default=` with the branch that skipped it" do
      expect(dumped_types(<<~RUBY)).to eq(["{ a: 1 } | { a: 1, ... }", "1 | Dynamic[top]"])
        def maybe(flag)
          h = { a: 1 }
          h.default = 0 if flag
          dump_type(h)
          dump_type(h[:b])
        end
      RUBY
      expect(rules(<<~RUBY)).to be_empty
        def maybe(flag)
          h = { a: 1 }
          h.default = 0 if flag
          puts "zero" if h[:b] == 0
          puts "one" if h[:b] == 1
        end
      RUBY
    end

    it "reads a non-literal key through the reopened shape's projection" do
      expect(dumped_types(<<~RUBY)).to eq(["1 | Dynamic[top]"])
        def defaulted(k)
          counts = { a: 1 }
          counts.default = 0
          dump_type(counts[k])
        end
      RUBY
      expect(rules(<<~RUBY)).to be_empty
        def defaulted(k)
          counts = { a: 1 }
          counts.default = 0
          puts "zero" if counts[k] == 0
        end
      RUBY
      expect(rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        def plain(k)
          counts = { a: 1 }
          puts "zero" if counts[k] == 0
        end
      RUBY
    end

    it "carries a default a loop body sets past the loop" do
      expect(rules(<<~RUBY)).to be_empty
        def defaulted
          h = { a: 1 }
          i = 0
          while i < 3
            h.default = 0
            i += 1
          end
          puts "zero" if h[:b] == 0
        end
      RUBY
      expect(rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        def plain
          h = { a: 1 }
          i = 0
          while i < 3
            h.fetch(:a)
            i += 1
          end
          puts "zero" if h[:b] == 0
        end
      RUBY
    end

    it "reopens under an attribute compound write and a multi-assign target" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Dynamic[top] Dynamic[top] nil])
        a = { a: 1 }
        a.default ||= 0
        dump_type(a[:b])

        m = { a: 1 }
        m.default, _x = 0, 1
        dump_type(m[:b])

        c = { a: 1 }
        _y = c.default || 0
        dump_type(c[:b])
      RUBY
    end

    it "drops a recorded read of the receiver when it is given a default" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top] | Integer", "Dynamic[top] | Integer", "1"])
        s = {}
        s[:k] ||= 1
        s.default = 0
        dump_type(s[:k])

        c = {}
        c[:k] ||= 1
        c.default ||= 0
        dump_type(c[:k])

        t = {}
        t[:k] ||= 1
        t.default
        dump_type(t[:k])
      RUBY
    end
  end

  # The reopened shape is open. A closed RBS record rejected every open source, so a literal that was only given a
  # default drew a mismatch although its key set is exactly the record's (#1281). A closed record now answers `maybe`
  # for an open source whose known keys are the record's, and `maybe` never reports. A missing key, a known extra key
  # and a value mismatch still answer `no`.
  describe "a closed record parameter" do
    let(:sig) do
      {
        "taker.rbs" => <<~RBS
          class Taker
            def self.take: ({ a: Integer }) -> void
            def self.take_hash: (Hash[Symbol, Integer]) -> void
            def self.make: () -> { a: Integer }
            def self.pick: ({ a: Integer }) -> Integer
                         | (Hash[Symbol, untyped]) -> String
          end
        RBS
      }
    end

    def take(body)
      "class Taker\n  def self.take(_h) = nil\n  def self.take_hash(_h) = nil\nend\n#{body}"
    end

    def mismatches(source)
      diagnostics(source, sig).map { |diagnostic| diagnostic.rule.to_s }.grep(/mismatch/)
    end

    it "accepts the reopened shape" do
      expect(rules(take("h = { a: 1 }\nh.default = 0\nTaker.take(h)"), sig: sig)).to be_empty
    end

    it "accepts the closed literal, and a Hash parameter accepts the reopened shape" do
      expect(rules(take("h = { a: 1 }\nh.fetch(:a)\nTaker.take(h)"), sig: sig)).to be_empty
      expect(rules(take("h = { a: 1 }\nh.default = 0\nTaker.take_hash(h)"), sig: sig)).to be_empty
    end

    it "accepts the reopened shape as a record return" do
      expect(mismatches(<<~RUBY)).to be_empty
        class Taker
          def self.make
            h = { a: 1 }
            h.default = 0
            h
          end
        end
      RUBY
    end

    it "still rejects a reopened shape missing a required key, holding a known extra key, or a mismatched value" do
      expect(rules(take("h = {}\nh.default = 0\nTaker.take(h)"), sig: sig)).to eq(["call.argument-type-mismatch"])
      expect(rules(take("h = { a: 1, b: 2 }\nh.default = 0\nTaker.take(h)"), sig: sig))
        .to eq(["call.argument-type-mismatch"])
      expect(rules(take("h = { a: \"x\" }\nh.default = 0\nTaker.take(h)"), sig: sig))
        .to eq(["call.argument-type-mismatch"])
      expect(mismatches(<<~RUBY)).to eq(["def.return-type-mismatch"])
        class Taker
          def self.make
            h = {}
            h.default = 0
            h
          end
        end
      RUBY
    end

    # The loss #1281 accepts: a default proc that stores the key it is asked for really adds `:b`, which the record
    # forbids. The open shape cannot tell that proc from one that only answers, so both now answer `maybe`.
    it "accepts a hash whose default proc stored a key the record forbids" do
      expect(rules(take(<<~RUBY), sig: sig)).to be_empty
        h = { a: 1 }
        h.default_proc = proc { |hash, key| hash[key] = 0 }
        h[:b]
        Taker.take(h)
      RUBY
    end

    # The record's `maybe` is no evidence for its overload, so the strict pass takes the `Hash[Symbol, untyped]`
    # overload that answers yes rather than the record listed first. The closed literal is the control.
    it "does not let a record overload listed first win the reopened shape by position" do
      expect(rules(<<~RUBY, sig: sig)).to eq(["call.undefined-method"])
        class Taker
          def self.pick(_h) = nil
        end
        h = { a: 1 }
        h.default = 0
        Taker.pick(h).upcase
        Taker.pick({ a: 1 }).upcase
      RUBY
    end
  end

  describe "`compare_by_identity`" do
    it "drops the shape of a String-keyed hash, whose literal key no longer finds its pair" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[String, Dynamic[top] | Integer]", "Dynamic[top] | Integer"])
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

    it "does not lose a default the program gives the hash after the switch" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top] | Integer", "Dynamic[top] | Integer"])
        s = { "k" => 1 }
        s.compare_by_identity
        s.default = "x"
        dump_type(s["zz"])

        class Keyed
          def initialize = @h = { "k" => 1 }
          def identify = @h.compare_by_identity
          def give = @h.default = "x"
          def peek = dump_type(@h["zz"])
        end
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

  # ADR-56 slice C: the content a block stores into a captured collection, into an `each_with_object` memo, or a
  # `while` / `until` body into a local, is joined onto a seed read before the body's mutations widened it. The seed
  # must still see the default.
  describe "the content joins" do
    it "reopens the seed of a captured hash the block both gives a default and stores into" do
      expect(rules(<<~RUBY)).to be_empty
        b = { a: 1 }
        [1].each { b.default = 0; b[:c] = 2 }
        puts "zero" if b[:zz] == 0
      RUBY
      expect(rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        c = { a: 1 }
        [1].each { c[:c] = 2 }
        puts "zero" if c[:zz] == 0
      RUBY
    end

    it "reopens the seed of a hash an `until` body both gives a default and stores into" do
      expect(rules(<<~RUBY)).to be_empty
        def defaulted(i)
          u = { a: 1 }
          until i.zero?
            u.default = 0
            u[:c] = 2
            i -= 1
          end
          puts "zero" if u[:zz] == 0
        end
      RUBY
    end

    it "reopens the seed of a hash a `while` body both gives a default and stores into" do
      expect(rules(<<~RUBY)).to be_empty
        def defaulted
          h = { a: 1 }
          i = 0
          while i < 2
            h.default = 0
            h[:c] = 2
            i += 1
          end
          puts "zero" if h[:zz] == 0
        end
      RUBY
      expect(rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        def plain
          h = { a: 1 }
          i = 0
          while i < 2
            h[:c] = 2
            i += 1
          end
          puts "zero" if h[:zz] == 0
        end
      RUBY
    end

    it "reopens an each_with_object memo the block gives a default" do
      expect(rules(<<~RUBY)).to be_empty
        r = %w[a b].each_with_object({}) { |w, acc| acc.default = 0; acc[w] = 1 }
        puts "zero" if r["zz"] == 0
      RUBY
      expect(rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        r = %w[a b].each_with_object({}) { |w, acc| acc[w] = 1 }
        puts "zero" if r["zz"] == 0
      RUBY
    end

    it "does not read a missing key as the stored values when the default was set before the block" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top] | true", "true"])
        flags = { debug: true }
        flags.default = false
        %w[a b].each { |w| flags[w.to_sym] = true }
        dump_type(flags[:verbose])

        plain = { debug: true }
        %w[a b].each { |w| plain[w.to_sym] = true }
        dump_type(plain[:verbose])
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
