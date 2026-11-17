# frozen_string_literal: true

require "spec_helper"

# ADR-116 C4 — {Rigor::Inference::Narrowing::Complements} on plain `Rigor::Type` values: no scope, no environment, no
# runner. `narrowing_spec.rb` pins the same algebra through `Narrowing.narrow_not_refinement`, `narrow_equal` and
# `narrow_falsey`; these examples call the module's entries directly, so editing `complements.rb` selects this spec by
# the mirror rule.
#
# Mutation-proved: each guard line (a `return` modifier) of `complements.rb` was blanked in turn and an example here
# failed, and so did dropping `meet.nil? ||` from `complement_integer_range`'s `unless`. One clause no input here
# distinguishes: `|| meet.is_a?(Type::Bot)` of that same `unless`, because `intersect_integer_part` answers a half, a
# range, the part itself or nil, never `Bot`. Tried: `Nominal[Integer]`, single-point meets at both bounds (they stay
# `Integer[a..a]`, not a `Constant` or `Bot`), `Constant`s on and beside each bound, and `Dynamic`, `Top`, `Tuple` and
# `Singleton` union members (which `integer_member?` keeps out of the meet). `intersect_integer_part`'s `case` has no
# `else` for the same reason: `integer_member?` admits only the three carriers it names.
RSpec.describe Rigor::Inference::Narrowing::Complements do
  let(:combinator) { Rigor::Type::Combinator }
  let(:type) { Rigor::Type }

  def const(value) = combinator.constant_of(value)
  def nominal(name) = combinator.nominal_of(name)
  def union(*members) = combinator.union(*members)
  def range(low, high) = combinator.integer_range(low, high)
  def short(type) = type.describe(:short)

  describe ".complement_difference" do
    let(:non_empty) { combinator.non_empty_string }

    it "keeps the removed constant when a member covers it, and every member disjoint from the base" do
      current = union(nominal("String"), const(nil))

      expect(short(described_class.complement_difference(current, non_empty))).to eq("\"\"?")
    end

    it "returns the removed constant alone for the base nominal" do
      expect(described_class.complement_difference(nominal("String"), non_empty)).to eq(const(""))
    end

    it "keeps a member disjoint from the base unchanged" do
      expect(described_class.complement_difference(nominal("Integer"), non_empty)).to eq(nominal("Integer"))
    end

    it "keeps the removed constant when the member is that constant" do
      expect(described_class.complement_difference(const(""), non_empty)).to eq(const(""))
    end

    it "drops a member inside the base that does not cover the removed constant, adding the constant once" do
      current = union(const("a"), const(""), nominal("Integer"))

      expect(short(described_class.complement_difference(current, non_empty))).to eq("\"\" | Integer")
    end

    it "returns the current type when nothing survives" do
      # `"a"` lies inside `String` and cannot be `""`: every member drops, and the answer is the input.
      expect(described_class.complement_difference(const("a"), non_empty)).to eq(const("a"))
    end

    it "works over non-zero-int the same way" do
      expect(described_class.complement_difference(nominal("Integer"), combinator.non_zero_int)).to eq(const(0))
    end
  end

  describe ".complement_integer_range" do
    let(:middle) { range(5, 10) }

    it "splits Integer into the two open halves" do
      expect(short(described_class.complement_integer_range(nominal("Integer"), middle)))
        .to eq("Integer[..4] | Integer[11..]")
    end

    it "keeps non-integer union members unchanged" do
      current = union(nominal("Integer"), const(nil))

      expect(short(described_class.complement_integer_range(current, middle)))
        .to eq("Integer[..4] | Integer[11..] | nil")
    end

    it "keeps a non-integer constant unchanged" do
      expect(described_class.complement_integer_range(const("s"), middle)).to eq(const("s"))
    end

    it "keeps a Top, Dynamic, Tuple and Singleton member of a union unchanged" do
      others = [combinator.top, combinator.untyped, combinator.tuple_of(nominal("Integer")),
                combinator.singleton_of("Integer")]

      others.each do |other|
        result = described_class.complement_integer_range(union(nominal("Integer"), other), middle)

        expect(result).to eq(union(range(:neg_infinity, 4), range(11, :pos_infinity), other))
      end
    end

    it "keeps a Float nominal and a Float constant unchanged" do
      expect(described_class.complement_integer_range(nominal("Float"), middle)).to eq(nominal("Float"))
      expect(described_class.complement_integer_range(const(1.5), middle)).to eq(const(1.5))
    end

    it "meets an overlapping range with each half" do
      expect(short(described_class.complement_integer_range(range(1, 20),
                                                            middle))).to eq("Integer[1..4] | Integer[11..20]")
    end

    it "meets a half-open range with the half on its side only" do
      expect(short(described_class.complement_integer_range(range(:neg_infinity, 3), middle))).to eq("Integer[..3]")
      expect(short(described_class.complement_integer_range(range(12, :pos_infinity), middle))).to eq("Integer[12..]")
    end

    it "meets an unbounded range with both halves" do
      current = range(:neg_infinity, :pos_infinity)

      expect(short(described_class.complement_integer_range(current, middle))).to eq("Integer[..4] | Integer[11..]")
    end

    it "keeps an Integer constant outside the range, with the half that covers it" do
      expect(described_class.complement_integer_range(const(3), middle)).to eq(const(3))
    end

    it "drops an Integer constant inside the range, which leaves nothing and returns the input" do
      expect(described_class.complement_integer_range(const(7), middle)).to eq(const(7))
    end

    it "returns the input when the range lies wholly inside the negated one" do
      # Every value of `Integer[6..8]` is in `Integer[5..10]`, so the complement is empty; the answer is the input.
      expect(described_class.complement_integer_range(range(6, 8), middle)).to eq(range(6, 8))
    end

    it "yields only the left half for a positive range, whose upper bound is infinite" do
      expect(short(described_class.complement_integer_range(nominal("Integer"), combinator.positive_int)))
        .to eq("non-positive-int")
    end

    it "yields only the right half for a negative range, whose lower bound is infinite" do
      expect(short(described_class.complement_integer_range(nominal("Integer"), combinator.negative_int)))
        .to eq("non-negative-int")
    end

    it "returns the input for the universal range, whose complement has no halves" do
      expect(described_class.complement_integer_range(nominal("Integer"), combinator.universal_int))
        .to eq(nominal("Integer"))
    end

    it "keeps a disjoint range as it is" do
      expect(described_class.complement_integer_range(range(1, 3), range(5, 10))).to eq(range(1, 3))
    end
  end

  describe ".complement_intersection" do
    let(:intersection) { combinator.non_empty_lowercase_string }

    it "unions each member's complement within the current type" do
      expect(short(described_class.complement_intersection(nominal("String"), intersection)))
        .to eq("\"\" | non-lowercase-string")
    end

    it "keeps a non-string member through every member's complement" do
      current = union(nominal("String"), const(nil))

      expect(short(described_class.complement_intersection(current, intersection)))
        .to eq("\"\" | nil | non-lowercase-string")
    end

    it "returns a disjoint current type unchanged" do
      expect(described_class.complement_intersection(nominal("Integer"), intersection)).to eq(nominal("Integer"))
    end
  end

  describe ".complement_refined" do
    let(:lowercase) { combinator.lowercase_string }

    it "answers the registered complement for the base nominal" do
      expect(described_class.complement_refined(nominal("String"), lowercase)).to eq(combinator.non_lowercase_string)
    end

    it "keeps a non-string union member beside the registered complement" do
      current = union(nominal("String"), const(nil))

      expect(short(described_class.complement_refined(current, lowercase))).to eq("non-lowercase-string?")
    end

    it "drops the refinement itself" do
      # `lowercase-string` is exactly the negated subset, so it drops and the answer is the input.
      expect(described_class.complement_refined(lowercase, lowercase)).to eq(lowercase)
    end

    it "keeps a part disjoint from the base" do
      expect(described_class.complement_refined(nominal("Integer"), lowercase)).to eq(nominal("Integer"))
    end

    it "builds a Difference for a part that overlaps the base but is not the base" do
      expect(short(described_class.complement_refined(const("abc"), lowercase))).to eq("\"abc\" - lowercase-string")
    end

    it "builds a Difference for the base when the predicate has no registered complement" do
      literal = combinator.refined(nominal("String"), :literal)

      expect(described_class.complement_refined(nominal("String"), literal))
        .to eq(combinator.difference(nominal("String"), literal))
    end

    it "answers the numeric pair's complement" do
      numeric = combinator.numeric_string

      expect(described_class.complement_refined(nominal("String"), numeric)).to eq(combinator.non_numeric_string)
    end
  end

  describe ".falsey_value? / .falsey_nominal?" do
    it "calls nil and false falsey, and nothing else" do
      expect([nil, false, 0, "", [], :a].map { |value| described_class.falsey_value?(value) })
        .to eq([true, true, false, false, false, false])
    end

    it "calls NilClass and FalseClass nominals falsey, and nothing else" do
      expect(%w[NilClass FalseClass TrueClass Integer].map { |name| described_class.falsey_nominal?(nominal(name)) })
        .to eq([true, true, false, false])
    end
  end

  describe ".narrow_falsey_other / .narrow_nil_other" do
    let(:bot) { combinator.bot }

    it "empties the falsey fragment of a Singleton, Tuple and HashShape" do
      carriers = [combinator.singleton_of("String"), combinator.tuple_of(nominal("Integer")),
                  combinator.hash_shape_of({ a: nominal("Integer") })]

      expect(carriers.map { |carrier| described_class.narrow_falsey_other(carrier) }).to all(eq(bot))
    end

    it "leaves Top, Dynamic and Bot as they are in the falsey fragment" do
      carriers = [combinator.top, combinator.untyped, bot]

      expect(carriers.map { |carrier| described_class.narrow_falsey_other(carrier) }).to eq(carriers)
    end

    it "narrows Top and Dynamic to nil in the nil fragment" do
      expect(described_class.narrow_nil_other(combinator.top)).to eq(const(nil))
      expect(described_class.narrow_nil_other(combinator.untyped)).to eq(const(nil))
    end

    it "keeps Bot as its own nil fragment" do
      expect(described_class.narrow_nil_other(bot)).to eq(bot)
    end

    it "empties the nil fragment of a Singleton, Tuple and HashShape" do
      carriers = [combinator.singleton_of("String"), combinator.tuple_of(nominal("Integer")),
                  combinator.hash_shape_of({ a: nominal("Integer") })]

      expect(carriers.map { |carrier| described_class.narrow_nil_other(carrier) }).to all(eq(bot))
    end
  end

  describe ".trusted_equality_literal? / .singleton_literal?" do
    it "trusts a Constant of String, Symbol, Integer, true, false or nil" do
      literals = ["a", :a, 1, true, false, nil].map { |value| const(value) }

      expect(literals.map { |literal| described_class.trusted_equality_literal?(literal) }).to all(be(true))
    end

    it "distrusts a Constant of another class and anything that is not a Constant" do
      expect(described_class.trusted_equality_literal?(const(1.5))).to be(false)
      expect(described_class.trusted_equality_literal?(const(1..2))).to be(false)
      expect(described_class.trusted_equality_literal?(nominal("Integer"))).to be(false)
    end

    it "calls true, false and nil singleton literals, and no other constant" do
      expect([true, false, nil, 1, "a", :a].map { |value| described_class.singleton_literal?(const(value)) })
        .to eq([true, true, true, false, false, false])
    end
  end

  describe ".finite_trusted_literal_domain?" do
    it "accepts Bot, a trusted Constant and a union of trusted Constants" do
      expect(described_class.finite_trusted_literal_domain?(combinator.bot)).to be(true)
      expect(described_class.finite_trusted_literal_domain?(const(1))).to be(true)
      expect(described_class.finite_trusted_literal_domain?(union(const(1), const(:a), const(nil)))).to be(true)
    end

    it "rejects an untrusted Constant, a nominal and a union holding one" do
      expect(described_class.finite_trusted_literal_domain?(const(1.5))).to be(false)
      expect(described_class.finite_trusted_literal_domain?(nominal("Integer"))).to be(false)
      expect(described_class.finite_trusted_literal_domain?(union(const(1), nominal("Integer")))).to be(false)
    end
  end

  describe ".narrow_finite_equal / .narrow_finite_not_equal" do
    let(:domain) { union(const(1), const(2), const(3)) }

    it "keeps the equal member" do
      expect(described_class.narrow_finite_equal(domain, const(2))).to eq(const(2))
    end

    it "empties the domain for a literal outside it" do
      expect(described_class.narrow_finite_equal(domain, const(9))).to eq(combinator.bot)
    end

    it "answers Bot for Bot, and for a non-finite carrier it cannot hold" do
      expect(described_class.narrow_finite_equal(combinator.bot, const(1))).to eq(combinator.bot)
      expect(described_class.narrow_finite_equal(nominal("Integer"), const(1))).to eq(combinator.bot)
    end

    it "removes the equal member for not-equal" do
      expect(described_class.narrow_finite_not_equal(domain, const(2))).to eq(union(const(1), const(3)))
    end

    it "keeps every member for a literal outside the domain" do
      expect(described_class.narrow_finite_not_equal(domain, const(9))).to eq(domain)
    end

    it "keeps a non-constant carrier for not-equal" do
      expect(described_class.narrow_finite_not_equal(nominal("Integer"), const(1))).to eq(nominal("Integer"))
    end
  end

  describe ".narrow_singleton_equal / .narrow_singleton_not_equal" do
    it "keeps the equal constant and empties a different one" do
      expect(described_class.narrow_singleton_equal(const(nil), const(nil))).to eq(const(nil))
      expect(described_class.narrow_singleton_equal(const(1), const(nil))).to eq(combinator.bot)
    end

    it "keeps the nominal of the literal's class and empties another nominal" do
      expect(described_class.narrow_singleton_equal(nominal("NilClass"), const(nil))).to eq(nominal("NilClass"))
      expect(described_class.narrow_singleton_equal(nominal("TrueClass"), const(true))).to eq(nominal("TrueClass"))
      expect(described_class.narrow_singleton_equal(nominal("FalseClass"), const(false))).to eq(nominal("FalseClass"))
      expect(described_class.narrow_singleton_equal(nominal("Integer"), const(nil))).to eq(combinator.bot)
      expect(described_class.narrow_singleton_equal(nominal("TrueClass"), const(false))).to eq(combinator.bot)
    end

    it "treats a nominal as unequal to a literal that is not true, false or nil" do
      expect(described_class.narrow_singleton_equal(nominal("Integer"), const(1))).to eq(combinator.bot)
      expect(described_class.narrow_singleton_not_equal(nominal("Integer"), const(1))).to eq(nominal("Integer"))
    end

    it "narrows each union member" do
      current = union(nominal("Integer"), const(nil), const(1))

      expect(described_class.narrow_singleton_equal(current, const(nil))).to eq(const(nil))
    end

    it "empties a Singleton, Tuple and HashShape and keeps Top, Dynamic and Bot" do
      emptied = [combinator.singleton_of("String"), combinator.tuple_of(nominal("Integer")),
                 combinator.hash_shape_of({ a: nominal("Integer") })]
      kept = [combinator.top, combinator.untyped, combinator.bot]

      expect(emptied.map do |carrier|
        described_class.narrow_singleton_equal(carrier, const(nil))
      end).to all(eq(combinator.bot))
      expect(kept.map { |carrier| described_class.narrow_singleton_equal(carrier, const(nil)) }).to eq(kept)
    end

    it "removes the equal constant and nominal for not-equal" do
      expect(described_class.narrow_singleton_not_equal(const(nil), const(nil))).to eq(combinator.bot)
      expect(described_class.narrow_singleton_not_equal(const(1), const(nil))).to eq(const(1))
      expect(described_class.narrow_singleton_not_equal(nominal("NilClass"), const(nil))).to eq(combinator.bot)
      expect(described_class.narrow_singleton_not_equal(nominal("Integer"), const(nil))).to eq(nominal("Integer"))
    end

    it "removes the equal member from a union for not-equal" do
      current = union(nominal("Integer"), const(nil))

      expect(described_class.narrow_singleton_not_equal(current, const(nil))).to eq(nominal("Integer"))
    end

    it "keeps any other carrier for not-equal" do
      other = [combinator.top, combinator.untyped, combinator.singleton_of("String")]

      expect(other.map { |carrier| described_class.narrow_singleton_not_equal(carrier, const(nil)) }).to eq(other)
    end
  end
end
