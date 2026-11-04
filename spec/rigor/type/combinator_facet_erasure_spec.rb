# frozen_string_literal: true

require "spec_helper"

# ADR-130 WD1 — `Combinator.union` dedups members modulo facet erasure. No facet erases until slice 1b adds the
# `Rigor::Plugin` interface carrier, so the merge is the identity today; these examples drive it through a stub facet
# that the erasure hook (`erased_facet?`) is stubbed to accept. Each nested example is the round-3 review shape: a join
# whose arms master's dedup collapses must collapse the same way when one arm carries the facet.

# A facet the engine has no carrier for: a value type that renders, compares and hashes.
ErasureStubFacet = Data.define(:name) do
  def describe(_verbosity = :short) = "Rigor::Plugin::#{name}"
end

RSpec.describe Rigor::Type::Combinator do
  describe "union dedup modulo facet erasure (ADR-130 WD1)" do
    let(:c) { described_class }
    let(:untyped) { c.untyped }
    let(:integer) { c.nominal_of("Integer") }
    let(:facet_a) { c.dynamic(ErasureStubFacet.new("_A")) }
    let(:facet_b) { c.dynamic(ErasureStubFacet.new("_B")) }

    def array_of(element) = c.nominal_of("Array", type_args: [element])

    context "when no facet erases (today)" do
      it "reads a stub-facet Dynamic as typed and keeps it beside Dynamic[top]" do
        expect(c.untyped?(facet_a)).to be(false)
        expect(c.union(facet_a, untyped).members).to contain_exactly(facet_a, untyped)
      end

      # The hot path: every join scans its members, and a join with no facet must not pay an allocation for it.
      it "scans facet-free members without allocating" do
        shape = c.hash_shape_of({ k: integer, s: c.nominal_of("String"), u: untyped })
        members = [c.tuple_of(integer, untyped), shape, array_of(c.union(integer, untyped)), c.dynamic(integer)]
        c.send(:merge_erased_members, members)

        # Reading the counter itself allocates; an empty window measures that floor.
        before = GC.stat(:total_allocated_objects)
        floor = GC.stat(:total_allocated_objects) - before
        before = GC.stat(:total_allocated_objects)
        result = c.send(:merge_erased_members, members)
        allocated = GC.stat(:total_allocated_objects) - before - floor

        expect(result).to equal(members)
        expect(allocated).to eq(0)
      end
    end

    context "when the hook erases the stub facet" do
      before do
        allow(described_class).to receive(:erased_facet?).and_wrap_original do |original, facet|
          facet.is_a?(ErasureStubFacet) || original.call(facet)
        end
      end

      it "reads the facet as untyped through the same hook" do
        expect(c.untyped?(facet_a)).to be(true)
        expect(c.untyped?(c.dynamic(integer))).to be(false)
      end

      it "merges a facet member with Dynamic[top] into Dynamic[top]" do
        expect(c.union(facet_a, untyped)).to equal(untyped)
      end

      it "merges two different facets into Dynamic[top]" do
        expect(c.union(facet_a, facet_b)).to equal(untyped)
      end

      it "keeps the facet on a member nothing else matches" do
        string = c.nominal_of("String")

        expect(c.union(facet_a, string).members).to contain_exactly(facet_a, string)
        expect(c.union(c.tuple_of(facet_a), c.tuple_of(untyped, integer)).members)
          .to contain_exactly(c.tuple_of(facet_a), c.tuple_of(untyped, integer))
      end

      it "merges inside a Tuple element" do
        expect(c.union(c.tuple_of(facet_a), c.tuple_of(untyped))).to eq(c.tuple_of(untyped))
      end

      it "merges inside a HashShape value and keeps the shape's key policy" do
        left = c.hash_shape_of({ k: facet_a, z: integer }, optional_keys: [:z], read_only_keys: [:k])
        right = c.hash_shape_of({ k: untyped, z: integer }, optional_keys: [:z], read_only_keys: [:k])

        expect(c.union(left, right)).to eq(right)
      end

      it "merges inside a Nominal type argument" do
        expect(c.union(array_of(facet_a), array_of(untyped))).to eq(array_of(untyped))
      end

      it "merges inside a nested union" do
        expect(c.union(array_of(c.union(facet_a, integer)), array_of(c.union(untyped, integer))))
          .to eq(array_of(c.union(untyped, integer)))
      end

      it "merges inside a Dynamic's own facet" do
        expect(c.union(c.dynamic(c.tuple_of(facet_a)), c.dynamic(c.tuple_of(untyped))))
          .to eq(c.dynamic(c.tuple_of(untyped)))
      end

      it "merges through several carriers at once" do
        deep = ->(leaf) { c.tuple_of(c.hash_shape_of({ k: array_of(leaf) })) }

        expect(c.union(deep.call(facet_a), deep.call(facet_b))).to eq(deep.call(untyped))
      end
    end
  end
end
