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

# Every concrete type carrier.
ERASURE_CARRIERS = Rigor::Type.constants.map { |name| Rigor::Type.const_get(name) }
                              .select { |k| k.is_a?(Class) && k.method_defined?(:erase_to_rbs) }.freeze

# One instance per type-holding carrier. `fill.call(slot)` answers the type for each type slot, named by the reader
# `TYPE_CHILDREN` lists for it, so a slot the table misses is one the sample asks for and the table does not name.
ERASURE_SAMPLES = {
  Rigor::Type::Dynamic => lambda { |fill|
    Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.tuple_of(fill.call(:static_facet)))
  },
  Rigor::Type::Nominal => ->(fill) { Rigor::Type::Combinator.nominal_of("Array", type_args: [fill.call(:type_args)]) },
  Rigor::Type::Tuple => ->(fill) { Rigor::Type::Combinator.tuple_of(fill.call(:elements)) },
  Rigor::Type::HashShape => ->(fill) { Rigor::Type::Combinator.hash_shape_of({ k: fill.call(:pairs) }) },
  Rigor::Type::Union => lambda { |fill|
    Rigor::Type::Combinator.union(fill.call(:members), Rigor::Type::Combinator.nominal_of("Integer"))
  },
  Rigor::Type::Intersection => lambda { |fill|
    Rigor::Type::Combinator.intersection(Rigor::Type::Combinator.tuple_of(fill.call(:members)),
                                         Rigor::Type::Combinator.nominal_of("Comparable"))
  },
  Rigor::Type::Difference => lambda { |fill|
    Rigor::Type::Difference.new(Rigor::Type::Combinator.tuple_of(fill.call(:base)),
                                Rigor::Type::Combinator.tuple_of(fill.call(:removed)))
  },
  Rigor::Type::Refined => lambda { |fill|
    Rigor::Type::Refined.new(Rigor::Type::Combinator.tuple_of(fill.call(:base)), :lowercase)
  },
  Rigor::Type::Maybe => ->(fill) { Rigor::Type::Combinator.maybe_of(fill.call(:value_type)) },
  Rigor::Type::Result => ->(fill) { Rigor::Type::Combinator.result_of(fill.call(:ok_type), fill.call(:err_type)) },
  Rigor::Type::App => ->(fill) { Rigor::Type::App.new(:"probe::box", [fill.call(:args)], bound: fill.call(:bound)) },
  Rigor::Type::BoundMethod => ->(fill) { Rigor::Type::Combinator.bound_method_of(fill.call(:receiver_type), :call) },
  Rigor::Type::DataInstance => lambda { |fill|
    Rigor::Type::Combinator.data_instance_of(members: { x: fill.call(:members) })
  },
  Rigor::Type::StructInstance => lambda { |fill|
    Rigor::Type::Combinator.struct_instance_of(members: { x: fill.call(:members) })
  }
}.freeze

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
        members = [c.tuple_of(integer, untyped), shape, array_of(c.union(integer, untyped)), c.dynamic(integer),
                   c.non_empty_array(untyped), c.data_instance_of(members: { x: untyped }), c.maybe_of(integer)]
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

      # Member order reads the erased forms: a facet does not move its member ahead of one master sorts first.
      it "orders a facet member where its erased form sorts" do
        string = c.dynamic(c.nominal_of("String"))

        expect(c.union(facet_a, string).members).to eq([string, facet_a])
        expect(c.union(string, facet_a).members).to eq([string, facet_a])
      end

      # Absorption reads the erased forms: an arm master absorbs is absorbed with a facet in it too.
      it "absorbs a Tuple arm whose erased form another arm contains" do
        wider = c.tuple_of(c.union(untyped, integer))

        expect(c.union(c.tuple_of(facet_a), wider)).to eq(wider)
      end

      it "absorbs a HashShape arm whose erased form another arm contains" do
        wider = c.hash_shape_of({ k: c.union(untyped, integer) })

        expect(c.union(c.hash_shape_of({ k: facet_a }), wider)).to eq(wider)
      end

      it "absorbs an arm whose erased element union another arm's lists" do
        wider = c.tuple_of(c.union(untyped, integer, c.nominal_of("String")))

        expect(c.union(c.tuple_of(c.union(facet_a, integer)), wider)).to eq(wider)
      end
    end

    # Every carrier that holds a type is walked: a new carrier fails here until `TYPE_CHILDREN` lists its type slots,
    # and a listed carrier fails when erasure leaves the facet in any slot its sample fills.
    describe "erasure coverage of every carrier" do
      it "lists every carrier, and samples every one that holds a type" do
        expect(described_class::TYPE_CHILDREN.keys).to match_array(ERASURE_CARRIERS)
        holders = described_class::TYPE_CHILDREN.reject { |_, readers| readers.empty? }.keys
        expect(ERASURE_SAMPLES.keys).to match_array(holders)
      end

      ERASURE_SAMPLES.each do |carrier, sample|
        it "finds and erases the facet in each type slot of #{carrier.name.split('::').last}" do
          allow(described_class).to receive(:erased_facet?).and_wrap_original do |original, facet|
            facet.is_a?(ErasureStubFacet) || original.call(facet)
          end
          untyped = described_class.untyped
          slots = []
          plain = sample.call(lambda { |slot|
            slots << slot
            untyped
          })

          expect(slots.uniq).to match_array(described_class::TYPE_CHILDREN.fetch(carrier))
          slots.uniq.each do |slot|
            carried = sample.call(->(at) { at == slot ? described_class.dynamic(ErasureStubFacet.new("_A")) : untyped })

            expect(carried).to be_a(carrier)
            expect(described_class.send(:facet_bearing?, carried)).to be(true), slot.to_s
            expect(described_class.send(:erase_facets, carried)).to eq(plain), slot.to_s
          end
        end
      end
    end
  end
end
