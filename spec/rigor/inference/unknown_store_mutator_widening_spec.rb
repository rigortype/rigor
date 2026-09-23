# frozen_string_literal: true

require "spec_helper"

# A mutator whose ARGUMENTS do not describe what it stores — `map!`, `collect!`, a block-form `fill`, `flatten!`,
# `transform_values!`, `transform_keys!`, `merge!` / `update`, `Hash#replace` — rewrites the parameter it stores
# into with values nothing typed. The straight-line seam used to widen the literal shape and keep the seed's element
# types, so `a = [1]; a.map!(&:to_s)` read `Array[Integer]` and `a.first.upcase` drew a false
# `call.undefined-method`; an empty-witness refinement (`if ys.any?; ys.map!(&:to_sym)`) declined outright and kept
# `non-empty-array[String]`.
#
# Every "does not fire" example is paired with a value-preserving control (`sort!`, `reverse!`, `compact!`) in the
# same position that must still fire — without it, a seam that stopped typing the receiver at all would pass too.
RSpec.describe "unknown-store mutator widening", type: :runner do
  def diagnostics(source, sig: {})
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, prefix, sig: {})
    diagnostics(source, sig: sig).filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?(prefix)
    end
  end

  def undefined_method_rules(source) = rules(source, "call.undefined-method")

  describe "the straight-line seam on a literal Array" do
    it "gives `map!`'s rewritten element the gradual arm" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[1 | Dynamic[top]]"])
        a = [1]
        a.map!(&:to_s)
        dump_type(a)
      RUBY
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        a = [1]
        a.map!(&:to_s)
        a.first.upcase
      RUBY
    end

    # The seed's pinning survives beside the arm (see the #561 boundary below), so this pins that keeping it
    # does not bring back the stale fold issue #560 erased it for: a union carrying `Dynamic` never folds.
    it "does not fold a comparison against the rewritten element, and still folds one after `sort!`" do
      expect(rules(<<~RUBY, "flow.")).to be_empty
        a = [1]
        a.map!(&:succ)
        puts "two" if a[0] == 2
      RUBY
      expect(rules(<<~RUBY, "flow.")).to eq(["flow.always-truthy-condition"]) # the rule id names both polarities
        a = [1]
        a.sort!
        puts "two" if a[0] == 2
      RUBY
    end

    it "keeps the seed's element under a value-preserving mutator in the same position" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        a = [1]
        a.sort!
        a.first.upcase
      RUBY
    end

    it "treats `collect!` and a block-form `fill` the same way" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        c = [1]
        c.collect! { |x| x.to_s }
        c.first.upcase

        b = [1, 2]
        b.fill { |i| i.to_s }
        b.first.upcase
      RUBY
    end

    # A union of tuples dispatches quietly, so this pair compares the carriers rather than a diagnostic.
    it "gives `flatten!`'s element the gradual arm, and not `reverse!`'s" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top] | [1] | [2]]", "Array[[1] | [2]]"])
        f = [[1], [2]]
        f.flatten!
        dump_type(f)

        g = [[1], [2]]
        g.reverse!
        dump_type(g)
      RUBY
    end

    it "widens an instance variable the same way" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        class Rewriter
          def run
            @a = [1]
            @a.map!(&:to_s)
            @a.first.upcase
          end
        end
      RUBY
    end
  end

  describe "the straight-line seam on an empty-witness refinement" do
    it "gives the refinement's rewritten element the gradual arm" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        ys = gets.to_s.split(",")
        if ys.any?
          ys.map!(&:to_sym)
          ys.first.to_proc
        end
      RUBY
    end

    it "keeps the refinement's element under a value-preserving mutator" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        ys = gets.to_s.split(",")
        if ys.any?
          ys.sort!
          ys.first.to_proc
        end
      RUBY
    end
  end

  describe "the straight-line seam on a literal Hash" do
    it "gives `transform_values!`'s value side, and only it, the gradual arm" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Symbol, 1 | Dynamic[top]]"])
        h = { a: 1 }
        h.transform_values!(&:to_s)
        dump_type(h)
      RUBY
    end

    it "gives `transform_keys!`'s key side, and only it, the gradual arm" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top] | Symbol, 1]"])
        h = { a: 1 }
        h.transform_keys!(&:to_s)
        dump_type(h)
      RUBY
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        h = { a: 1 }
        h.transform_keys!(&:to_s)
        h.keys.first.bytesize
      RUBY
    end

    it "keeps the seed's key under `compact!`" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        h = { a: 1 }
        h.compact!
        h.keys.first.bytesize
      RUBY
    end

    it "gives `merge!` / `update` / `replace` both sides the gradual arm, with or without a block" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top] | Symbol, 1 | Dynamic[top]]"] * 4)
        h = { a: 1 }
        h.merge!({ a: 2 }) { |_k, o, _n| o.to_s }
        dump_type(h)

        i = { a: 1 }
        i.merge!(b: "s")
        dump_type(i)

        j = { a: 1 }
        j.update("k" => 2)
        dump_type(j)

        k = { a: 1 }
        k.replace({ "x" => "s" })
        dump_type(k)
      RUBY
    end

    # `Hash.new(0)` proves its value side, and an ADDER's re-join keeps that proof (#580's
    # `keep_precise_parameters`); a rewriter falsifies it, so the arm lands on the side it rewrites.
    it "gives a re-opened carrier's proven value side the arm under `transform_values!`" do
      expected = ["Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]", "Hash[Dynamic[top] | Symbol, Integer]"]
      expect(dumped_types(<<~RUBY)).to eq(expected)
        h = Hash.new(0)
        h[:x] += 1
        h.transform_values!(&:to_s)
        dump_type(h)

        g = Hash.new(0)
        g[:x] += 1
        g.compact!
        dump_type(g)
      RUBY
    end
  end

  describe "the block-capture seam" do
    it "gives a captured literal's rewritten element the gradual arm" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        a = [1]
        [0].each { a.map!(&:to_s) }
        a.first.upcase
      RUBY
    end

    it "keeps the captured literal's element under a value-preserving mutator" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        a = [1]
        [0].each { a.sort! }
        a.first.upcase
      RUBY
    end
  end

  # The #561 boundary. A precise nominal's element set is a claim a declaration made, so the rewrite does not
  # grow it (RBS's own `map!` is `{ (Elem) -> Elem } -> self`); what the arm adds to a literal seed must also
  # keep the seed accepted by a hand-written signature that pins it, haml's `-> Array[:multi]`.
  describe "the precise-nominal boundary" do
    it "leaves a precise nominal as it is" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[String]"])
        s = gets.to_s.split(",")
        s.map!(&:strip)
        dump_type(s)
      RUBY
    end

    it "keeps a rewritten literal accepted by a hand-written return type" do
      sig = { "temple.rbs" => "class Temple\n  def call: () -> Array[:multi]\nend\n" }
      expect(rules(<<~RUBY, "def.", sig: sig)).to be_empty
        class Temple
          def call
            temple = [:multi]
            temple.map!(&:itself)
            temple
          end
        end
      RUBY
    end

    it "still checks the return type against a seed the signature rejects" do
      sig = { "temple.rbs" => "class Temple\n  def call: () -> Array[:multi]\nend\n" }
      expect(rules(<<~RUBY, "def.", sig: sig)).to eq(["def.return-type-mismatch"])
        class Temple
          def call
            temple = [:other]
            temple
          end
        end
      RUBY
    end
  end
end
