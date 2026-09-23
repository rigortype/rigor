# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/unknown_store_widening"
require "rigor/type"

# Unit-level coverage for {Rigor::Inference::UnknownStoreWidening}. The consumer — the per-element block
# fold's entry bindings — is exercised end-to-end by `spec/rigor/inference/block_return_scope_threading_spec.rb`;
# this file pins the widening each site shape produces.
RSpec.describe Rigor::Inference::UnknownStoreWidening do
  describe ".widen" do
    # Every mutation site in the block on the fixture's last statement, in source order.
    def sites_of(source)
      block = Prism.parse(source).value.statements.body.last.block
      Rigor::Source::NodeWalker.each(block.body).select do |node|
        node.is_a?(Prism::IndexOperatorWriteNode) ||
          (node.is_a?(Prism::CallNode) && Rigor::Inference::MutationWidening::SHAPE_MUTATORS.include?(node.name))
      end
    end

    let(:one_pinned_tuple) { Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of(1)) }

    let(:zero_pinned_hash) do
      Rigor::Type::Combinator.hash_shape_of({ a: Rigor::Type::Combinator.constant_of(0) })
    end

    it "erases the value pin an index compound write falsifies and adds the gradual arm" do
      widened = described_class.widen(zero_pinned_hash, sites_of("h = {}\n[1].each { |k| h[k] += 1 }\n"))
      expect(widened.describe).to eq("Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]")
    end

    it "treats a `[]=` call exactly like the index compound write" do
      widened = described_class.widen(zero_pinned_hash, sites_of("h = {}\n[1].each { |k| h[k] = 1 }\n"))
      expect(widened.describe).to eq("Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]")
    end

    it "keeps the pins an adder leaves in place and adds the gradual element" do
      widened = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a << e }\n"))
      expect(widened.describe).to eq("Array[1 | Dynamic[top]]")
    end

    # A remover that CLOSES the literal cannot keep its content as it is: the nominal it widens to cannot say a
    # slot may be missing. `{ a: 0 }` under a lone `h.delete(:a)` read `Hash[Symbol, 0]`, whose `h[:b]` answered
    # `0` where Ruby answers `nil`.
    it "gives a literal a remover closes the gradual arm" do
      widened = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a.pop }\n"))
      expect(widened.describe).to eq("Array[1 | Dynamic[top]]")
    end

    it "keeps a remover's content when the carrier is already a nominal" do
      nominal = Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.untyped])
      expect(described_class.widen(nominal, sites_of("a = []\n[1].each { |e| a.pop }\n"))).to eq(nominal)
    end

    # A remover written first closed the literal to `Array[1]`, which the adder after it then declined as a
    # precise nominal — the arm the adder stands for went missing, and `p == 2` after the loop folded.
    it "widens the same way whichever order a remover and an adder are written in" do
      remover_first = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a.pop; a.push(e) }\n"))
      adder_first = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a.push(e); a.pop }\n"))
      expect([remover_first.describe, adder_first.describe]).to eq(["Array[1 | Dynamic[top]]"] * 2)
    end

    it "gives a site whose arguments describe no stored value the gradual arm" do
      # The widening joins nothing for `map!`, so without the arm the class the block rewrites to is missing.
      widened = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a.map!(&:to_s) }\n"))
      expect(widened.describe).to eq("Array[Dynamic[top] | Integer]")
    end

    it "gives every Array member of a union seed the gradual arm" do
      # `flag ? xs : [1]` under `map!`: the precise member is declined by the widening itself, but the site
      # still rewrites whichever array the local holds, so each member takes the arm.
      union = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")]),
        one_pinned_tuple
      )
      widened = described_class.widen(union, sites_of("a = []\n[1].each { |e| a.map!(&:to_s) }\n"))
      expect(widened.describe).to eq("Array[Dynamic[top] | Integer] | Array[Dynamic[top] | String]")
    end

    it "keeps an empty-witness refinement while giving its base the gradual arm" do
      # An append cannot empty the receiver, so the rebuilt `Difference` must still remove the empty witness.
      seed = Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("String"))
      widened = described_class.widen(seed, sites_of("a = []\n[1].each { |e| a << e }\n"))
      expect(widened.describe).to eq("non-empty-array[Dynamic[top] | String]")
      expect(widened.removes_empty_witness?).to be(true)
    end

    it "leaves the binding unchanged when the carrier's table does not list the mutator" do
      widened = described_class.widen(zero_pinned_hash, sites_of("h = {}\n[1].each { |k| h.shift }\n"))
      expect(widened).to eq(zero_pinned_hash)
    end

    it "leaves a binding no site's widening applies to unchanged" do
      declared = Rigor::Type::Combinator.nominal_of("Hash", type_args: [
                                                      Rigor::Type::Combinator.nominal_of("Symbol"),
                                                      Rigor::Type::Combinator.nominal_of("Integer")
                                                    ])
      expect(described_class.widen(declared, sites_of("h = {}\n[1].each { |k| h[k] += 1 }\n"))).to eq(declared)
    end

    it "leaves the binding unchanged when there is no site" do
      expect(described_class.widen(zero_pinned_hash, [])).to eq(zero_pinned_hash)
    end
  end
end
