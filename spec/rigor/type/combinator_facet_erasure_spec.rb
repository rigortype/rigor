# frozen_string_literal: true

require "spec_helper"

# ADR-130 WD1 — `Combinator.union` dedups members modulo facet erasure. The facet that erases is the `Rigor::Plugin`
# interface carrier (`Type::Interface`); most examples drive the merge through a stub facet that the erasure hook
# (`erased_facet?`) is stubbed to accept, so they pin the merge apart from the carrier. Each nested example is the
# round-3 review shape: a join whose arms master's dedup collapses must collapse the same way when one arm carries the
# facet.

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
  },
  Rigor::Type::Interface => ->(fill) { Rigor::Type::Interface.new("Rigor::Plugin::_Each", [fill.call(:type_args)]) }
}.freeze

# One instance per carrier that holds no type.
ERASURE_LEAVES = [
  Rigor::Type::Combinator.top, Rigor::Type::Combinator.bot, Rigor::Type::Combinator.constant_of(1),
  Rigor::Type::Combinator.integer_range(1, 2), Rigor::Type::Combinator.float_range(0.0, 1.0),
  Rigor::Type::Combinator.singleton_of("String"), Rigor::Type::Combinator.data_class_of(members: [:x]),
  Rigor::Type::Combinator.struct_class_of(members: [:x])
].freeze

# The instance variables of `type` that hold a type, or an Array or Hash of types, by reflection: the slots
# `TYPE_CHILDREN` must list, whatever a sample names.
def erasure_type_slots(type)
  holds_type = ->(value) { ERASURE_CARRIERS.any? { |carrier| value.is_a?(carrier) } }
  type.instance_variables.filter_map do |ivar|
    value = type.instance_variable_get(ivar)
    values = case value
             when Array then value
             when Hash then value.values
             else [value]
             end
    ivar.to_s.delete_prefix("@").to_sym if values.any?(&holds_type)
  end
end

RSpec.describe Rigor::Type::Combinator do
  describe "union dedup modulo facet erasure (ADR-130 WD1)" do
    let(:c) { described_class }
    let(:untyped) { c.untyped }
    let(:integer) { c.nominal_of("Integer") }
    let(:facet_a) { c.dynamic(ErasureStubFacet.new("_A")) }
    let(:facet_b) { c.dynamic(ErasureStubFacet.new("_B")) }

    def array_of(element) = c.nominal_of("Array", type_args: [element])

    context "with the Rigor::Plugin interface carrier" do
      let(:scope_value) { c.dynamic(Rigor::Type::Interface.new("Rigor::Plugin::_Scope")) }
      let(:each_value) { c.dynamic(Rigor::Type::Interface.new("Rigor::Plugin::_Each", [integer])) }

      it "reads an interface value as untyped, and its bare facet as no Dynamic" do
        expect(c.untyped?(scope_value)).to be(true)
        expect(c.untyped?(each_value)).to be(true)
        expect(c.untyped?(scope_value.static_facet)).to be(false)
      end

      it "merges two interface values, or one with Dynamic[top], into Dynamic[top]" do
        expect(c.union(scope_value, each_value)).to equal(untyped)
        expect(c.union(scope_value, untyped)).to equal(untyped)
        expect(c.union(c.tuple_of(scope_value), c.tuple_of(untyped))).to eq(c.tuple_of(untyped))
      end

      it "keeps the facet on an interface value nothing else matches" do
        string = c.nominal_of("String")

        expect(c.union(scope_value, string).members).to contain_exactly(scope_value, string)
      end
    end

    context "when only the carrier erases" do
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
      it "lists every carrier, and has an instance of each" do
        expect(described_class::TYPE_CHILDREN.keys).to match_array(ERASURE_CARRIERS)
        expect(ERASURE_SAMPLES.keys + ERASURE_LEAVES.map(&:class)).to match_array(ERASURE_CARRIERS)
      end

      it "lists exactly the type-holding slots reflection finds on each carrier" do
        plain = ->(_) { described_class.untyped }
        instances = ERASURE_LEAVES + ERASURE_SAMPLES.values.map { |sample| sample.call(plain) }

        instances.each do |instance|
          expect(erasure_type_slots(instance))
            .to match_array(described_class::TYPE_CHILDREN.fetch(instance.class)), instance.class.name
        end
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
