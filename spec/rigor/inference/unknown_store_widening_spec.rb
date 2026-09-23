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

    # The exception is for the site that closes a literal only: a refinement is no literal, so a remover keeps
    # its element types exactly and adds no arm.
    it "keeps a remover's content when the carrier is no literal" do
      refined = Rigor::Type::Combinator.difference(
        Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("Integer")]),
        Rigor::Type::Tuple.new([])
      )
      widened = described_class.widen(refined, sites_of("a = []\n[1].each { |e| a.pop }\n"))
      expect(widened.describe).to eq("Array[Integer]")
    end

    # A remover written first closed the literal to `Array[1]`, which the adder after it then declined as a
    # precise nominal — the arm the adder stands for went missing, and `p == 2` after the loop folded.
    it "widens the same way whichever order a remover and an adder are written in" do
      remover_first = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a.pop; a.push(e) }\n"))
      adder_first = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a.push(e); a.pop }\n"))
      expect([remover_first.describe, adder_first.describe]).to eq(["Array[1 | Dynamic[top]]"] * 2)
    end

    it "gives a site whose arguments describe no stored value the gradual arm" do
      # The widening joins nothing for `map!`; the element it rewrites is gradual, as the straight-line seam answers.
      widened = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a.map!(&:to_s) }\n"))
      expect(widened.describe).to eq("Array[Dynamic[top]]")
    end

    it "gives every Array member of a union seed the gradual arm" do
      # `flag ? xs : [1]` under `map!`: the precise member is declined by the widening itself, but the site
      # still rewrites whichever array the local holds, so each member takes the arm.
      union = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")]),
        one_pinned_tuple
      )
      widened = described_class.widen(union, sites_of("a = []\n[1].each { |e| a.map!(&:to_s) }\n"))
      expect(widened.describe).to eq("Array[Dynamic[top] | String] | Array[Dynamic[top]]")
    end

    it "keeps an empty-witness refinement while giving its base the gradual arm" do
      # An append cannot empty the receiver, so the rebuilt `Difference` must still remove the empty witness.
      seed = Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("String"))
      widened = described_class.widen(seed, sites_of("a = []\n[1].each { |e| a << e }\n"))
      expect(widened.describe).to eq("non-empty-array[Dynamic[top] | String]")
      expect(widened.removes_empty_witness?).to be(true)
    end

    # `map!` cannot empty the receiver but rewrites every element, so the straight-line widening keeps the witness
    # and replaces the base's element (`RewriteMutation`). It used to decline these, answering the pre-state, and a
    # declined site left the entry refinement's element standing over what the rewrite stored.
    describe "an empty-witness refinement under a rewrite" do
      let(:non_empty_strings) { Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("String")) }

      it "gives a class-changing site the gradual arm and keeps the witness" do
        widened = described_class.widen(non_empty_strings, sites_of("a = []\n[1].each { |e| a.map!(&:to_sym) }\n"))
        expect(widened.describe).to eq("non-empty-array[Dynamic[top]]")
        expect(widened.removes_empty_witness?).to be(true)
      end

      it "gives a Hash refinement a value-rewriting site the gradual arm" do
        seed = Rigor::Type::Combinator.non_empty_hash(
          Rigor::Type::Combinator.nominal_of("String"), Rigor::Type::Combinator.nominal_of("String")
        )
        widened = described_class.widen(seed, sites_of("h = {}\n[1].each { |e| h.transform_values!(&:to_sym) }\n"))
        expect(widened.describe).to eq("non-empty-hash[Dynamic[top] | String, Dynamic[top]]")
      end

      it "gives the refinement member of a union the arm and keeps the other members" do
        seed = Rigor::Type::Combinator.union(non_empty_strings, Rigor::Type::Combinator.constant_of(nil))
        widened = described_class.widen(seed, sites_of("a = []\n[1].each { |e| a.map!(&:to_sym) }\n"))
        expect(widened).to eq(
          Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.untyped),
            Rigor::Type::Combinator.constant_of(nil)
          )
        )
      end

      it "gives a precise member of the same union the arm too, as when another member widens" do
        precise = Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("Integer")])
        seed = Rigor::Type::Combinator.union(precise, non_empty_strings)
        widened = described_class.widen(seed, sites_of("a = []\n[1].each { |e| a.map!(&:to_sym) }\n"))
        expect(widened.describe).to eq("Array[Dynamic[top] | Integer] | non-empty-array[Dynamic[top]]")
      end

      it "leaves the refinement unchanged under an adder called with no argument" do
        expect(described_class.widen(non_empty_strings, sites_of("a = []\n[1].each { |e| a.push }\n")))
          .to eq(non_empty_strings)
      end

      it "gives a Hash refinement a merging site with an argument the arm" do
        seed = Rigor::Type::Combinator.non_empty_hash(
          Rigor::Type::Combinator.nominal_of("String"), Rigor::Type::Combinator.nominal_of("String")
        )
        widened = described_class.widen(seed, sites_of("h = {}\n[1].each { |e| h.merge!(e) }\n"))
        expect(widened.describe).to eq("non-empty-hash[Dynamic[top] | String, Dynamic[top] | String]")
      end

      it "leaves the refinement unchanged under a site that only reorders" do
        expect(described_class.widen(non_empty_strings, sites_of("a = []\n[1].each { |e| a.sort! }\n")))
          .to eq(non_empty_strings)
      end

      it "leaves the refinement unchanged under a name its base's table does not list" do
        expect(described_class.widen(non_empty_strings, sites_of("a = []\n[1].each { |e| a.store(e, e) }\n")))
          .to eq(non_empty_strings)
      end

      it "leaves a precise nominal on its own unchanged under the same site" do
        precise = Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")])
        expect(described_class.widen(precise, sites_of("a = []\n[1].each { |e| a.map!(&:to_sym) }\n"))).to eq(precise)
      end
    end

    # `Hash#shift` removes a pair as `delete` does; before it was listed as a Hash mutator the widening declined it
    # and the site left the literal as it was.
    it "gives a literal Hash a `shift` closes the gradual arm, as `delete` does" do
      shifted = described_class.widen(zero_pinned_hash, sites_of("h = {}\n[1].each { |k| h.shift }\n"))
      deleted = described_class.widen(zero_pinned_hash, sites_of("h = {}\n[1].each { |k| h.delete(k) }\n"))
      expect(shifted.describe).to eq("Hash[Dynamic[top] | Symbol, 0 | Dynamic[top]]")
      expect(shifted).to eq(deleted)
    end

    it "leaves the binding unchanged when the carrier's table does not list the mutator" do
      # `store` is a Hash mutator only, so an Array literal's table does not list it.
      widened = described_class.widen(one_pinned_tuple, sites_of("a = []\n[1].each { |e| a.store(e, e) }\n"))
      expect(widened).to eq(one_pinned_tuple)
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

    describe "a site on an element read" do
      let(:nested_tuple) do
        Rigor::Type::Combinator.tuple_of(
          Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of(1)),
          Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of(2))
        )
      end

      it "widens the element the path selects and keeps its siblings" do
        widened = described_class.widen(nested_tuple, sites_of("a = []\n[1].each { |e| a[0] << e }\n"))
        expect(widened.describe).to eq("[Array[1 | Dynamic[top]], [2]]")
      end

      it "gives the element the gradual arm a class-changing site needs" do
        widened = described_class.widen(nested_tuple, sites_of("a = []\n[1].each { |e| a.last.map!(&:to_s) }\n"))
        expect(widened.describe).to eq("[[1], Array[Dynamic[top]]]")
      end

      it "declines a path the straight-line widening cannot follow" do
        # A `HashShape` slot: `ElementReadWidening` walks tuples only, on straight-line code too.
        seed = Rigor::Type::Combinator.hash_shape_of({ a: Rigor::Type::Combinator.tuple_of })
        expect(described_class.widen(seed, sites_of("h = {}\n[1].each { |e| h[:a] << e }\n"))).to equal(seed)
      end
    end

    describe "a callee store" do
      let(:store) do
        call = Prism.parse("add(a)").value.statements.body.first
        [described_class::CalleeStore.new(call, call.arguments.arguments)]
      end

      it "floors each collection member of a union and keeps the others" do
        seed = Rigor::Type::Combinator.union(one_pinned_tuple, Rigor::Type::Combinator.constant_of(nil))
        expect(described_class.widen(seed, store).describe).to eq("Array[Dynamic[top]]?")
      end

      it "floors a hash, a precise nominal, a refinement's collection base and a string to their bare carriers" do
        seeds = [
          zero_pinned_hash,
          Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")]),
          Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("Integer")),
          Rigor::Type::Combinator.constant_of("ab")
        ]
        expect(seeds.map { |seed| described_class.widen(seed, store).describe })
          .to eq(["Hash[Dynamic[top], Dynamic[top]]", "Array[Dynamic[top]]", "Array[Dynamic[top]]", "String"])
      end

      it "floors every refined form of a string to String" do
        seeds = [
          Rigor::Type::Combinator.non_empty_string,
          Rigor::Type::Combinator.decimal_int_string,
          Rigor::Type::Combinator.non_empty_uppercase_string
        ]
        expect(seeds.map { |seed| described_class.widen(seed, store).describe }).to eq(["String"] * 3)
      end

      it "leaves a binding that holds no collection unchanged" do
        non_zero = Rigor::Type::Combinator.difference(
          Rigor::Type::Combinator.nominal_of("Integer"), Rigor::Type::Combinator.constant_of(0)
        )
        seeds = [Rigor::Type::Combinator.constant_of(3), non_zero]
        expect(seeds.map { |seed| described_class.widen(seed, store) }).to eq(seeds)
      end
    end
  end
end
