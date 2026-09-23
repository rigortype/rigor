# frozen_string_literal: true

require "spec_helper"

# `Hash#shift` removes a pair, but `MutationWidening::HASH_MUTATORS` did not list it: the name reached
# `SHAPE_MUTATORS` only through `ARRAY_MUTATORS`, so every seam that widens a `HashShape` through the Hash table
# declined it and the literal shape outlived the removal. `k = { a: 1 }; k.shift` kept `{ a: 1 }` for a hash that is
# empty at runtime, and `k.size == 1` folded always-truthy on correct code.
#
# Every example is paired with a control that makes a non-mutating call in the same position, and that control must
# keep the literal — without it, a seam that stopped folding altogether would pass the `shift` half too.
RSpec.describe "Hash#shift mutation widening", type: :runner do
  def diagnostics(source, sig)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig).diagnostics
  end

  def dumped_types(source, sig: {})
    diagnostics(source, sig).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def flow_rules(source, sig: {})
    diagnostics(source, sig).filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.")
    end
  end

  describe "the straight-line seam" do
    it "widens a local HashShape that `shift` empties" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Symbol, 1]"])
        k = { a: 1 }
        k.shift
        dump_type(k)
      RUBY
      expect(flow_rules(<<~RUBY)).to be_empty
        k = { a: 1 }
        k.shift
        puts "one" if k.size == 1
      RUBY
    end

    it "keeps the literal, and the genuine fold, under a non-mutating call" do
      expect(dumped_types(<<~RUBY)).to eq(["{ a: 1 }"])
        k = { a: 1 }
        k.fetch(:a)
        dump_type(k)
      RUBY
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        k = { a: 1 }
        k.fetch(:a)
        puts "one" if k.size == 1
      RUBY
    end

    it "widens an instance variable's HashShape that `shift` empties" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Symbol, 1]", "{ a: 1 }"])
        class Queueish
          def drained
            @h = { a: 1 }
            @h.shift
            dump_type(@h)
          end

          def kept
            @h = { a: 1 }
            @h.fetch(:a)
            dump_type(@h)
          end
        end
      RUBY
    end

    it "widens the HashShape member of a Union alongside the Tuple member" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[1] | Hash[Symbol, 1]", "[1] | { a: 1 }"])
        def drained(flag)
          u = flag ? { a: 1 } : [1]
          u.shift
          dump_type(u)
        end

        def kept(flag)
          u = flag ? { a: 1 } : [1]
          u.first
          dump_type(u)
        end
      RUBY
    end
  end

  # ADR-56 slice A: a captured outer local mutated inside a block widens in the outer scope after the call.
  describe "the block-capture seam" do
    it "widens a captured HashShape the block shifts, and keeps one the block only reads" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Symbol, 1 | 2]", "{ a: 1, b: 2 }"])
        b = { a: 1, b: 2 }
        [1].each { b.shift }
        dump_type(b)

        c = { a: 1, b: 2 }
        [1].each { c.fetch(:a) }
        dump_type(c)
      RUBY
    end
  end

  # ADR-58: a literal ivar seed is widened at every method entry when some method in the class mutates the ivar.
  describe "the class-level ivar census" do
    it "widens an ivar seed another method shifts, and keeps one another method only reads" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top], Dynamic[top]]", "{ a: 1 }"])
        class Drained
          def initialize = @h = { a: 1 }
          def drop = @h.shift
          def peek = dump_type(@h)
        end

        class Kept
          def initialize = @h = { a: 1 }
          def read = @h.fetch(:a)
          def peek = dump_type(@h)
        end
      RUBY
    end
  end

  # The per-element Tuple fold types every position from one entry scope; a captured literal the body mutates in
  # place is widened for an unknown store first (`UnknownStoreWidening`), or every position reads the entry size.
  describe "the per-element block fold" do
    it "does not pin the entry size of a captured HashShape the body shifts" do
      expect(dumped_types(<<~RUBY)).to eq(["[non-negative-int, non-negative-int]"])
        s = { a: 1, b: 2 }
        dump_type([1, 2].map { |i| v = s.size; s.shift; v })
      RUBY
    end

    it "keeps the entry size of a captured HashShape the body only reads" do
      expect(dumped_types(<<~RUBY)).to eq(["[2, 2]"])
        s = { a: 1, b: 2 }
        dump_type([1, 2].map { |i| v = s.size; s.fetch(:a); v })
      RUBY
    end
  end

  # Issue #936: an empty-witness refinement keeps its witness only under a mutator that cannot empty the receiver.
  describe "the non-empty-hash refinement" do
    let(:sig) do
      {
        "catalog.rbs" => <<~RBS
          class Catalog
            %a{rigor:v1:return: non-empty-hash[Symbol, Integer]}
            def attributes: () -> Hash[Symbol, Integer]
          end
        RBS
      }
    end

    # The class is declared in RBS alone: the refinement comes from the `%a{}` return override, and a Ruby body
    # returning a literal would only add an unrelated diagnostic to the list these examples compare exactly.
    def catalog(body)
      "h = Catalog.new.attributes\n#{body}"
    end

    it "retracts the witness under `shift`" do
      expect(dumped_types(catalog("h.shift\ndump_type(h)"), sig: sig)).to eq(["Hash[Symbol, Integer]"])
      expect(flow_rules(catalog(%(h.shift\nputs "none" if h.size == 0)), sig: sig)).to be_empty
    end

    it "keeps the witness under a non-mutating call" do
      expect(dumped_types(catalog("h.fetch(:name)\ndump_type(h)"), sig: sig))
        .to eq(["non-empty-hash[Symbol, Integer]"])
      expect(flow_rules(catalog(%(h.fetch(:name)\nputs "none" if h.size == 0)), sig: sig))
        .to eq(["flow.always-truthy-condition"])
    end
  end
end
