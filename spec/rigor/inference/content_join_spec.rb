# frozen_string_literal: true

require "spec_helper"

require "rigor/inference/content_join"
require "rigor/type"

# Unit-level coverage for {Rigor::Inference::ContentJoin} — the element / key / value JOIN shared by the
# ADR-56 slice C block-capture path and the issue #560 straight-line path. Unlike the arity-forgetting
# widening in {Rigor::Inference::MutationWidening}, these compute the exact continuation
# element/key/value types, so exact-`eq` assertions on the returned carriers are load-bearing.
RSpec.describe Rigor::Inference::ContentJoin do
  describe ".collection_element_types" do
    let(:int_type) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:str_type) { Rigor::Type::Combinator.nominal_of("String") }

    it "lists a Tuple's elements in order" do
      tuple = Rigor::Type::Combinator.tuple_of(int_type, str_type)
      expect(described_class.send(:collection_element_types, tuple)).to eq([int_type, str_type])
    end

    it "returns the single type-arg of a Nominal[Array, [E]]" do
      array = Rigor::Type::Combinator.nominal_of("Array", type_args: [int_type])
      expect(described_class.send(:collection_element_types, array)).to eq([int_type])
    end

    it "returns no elements for a non-Array Nominal" do
      hash = Rigor::Type::Combinator.nominal_of("Hash", type_args: [str_type, int_type])
      expect(described_class.send(:collection_element_types, hash)).to eq([])
    end

    it "flat_maps element evidence across every Union member" do
      tuple = Rigor::Type::Combinator.tuple_of(int_type)
      array = Rigor::Type::Combinator.nominal_of("Array", type_args: [str_type])
      union = Rigor::Type::Combinator.union(tuple, array)
      # Combinator.union may reorder members, so assert set membership rather than element order.
      expect(described_class.send(:collection_element_types, union)).to contain_exactly(int_type, str_type)
    end

    it "returns no elements for a non-collection type" do
      expect(described_class.send(:collection_element_types, Rigor::Type::Combinator.constant_of(1))).to eq([])
    end
  end

  describe ".hash_shape_key_values" do
    let(:int_type) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:str_type) { Rigor::Type::Combinator.nominal_of("String") }
    let(:sym_type) { Rigor::Type::Combinator.nominal_of("Symbol") }

    it "returns the key union and the value list for a HashShape" do
      shape = Rigor::Type::HashShape.new(a: int_type, b: str_type)
      keys, values = described_class.send(:hash_shape_key_values, shape)
      expect(keys).to eq([sym_type])
      expect(values).to eq([int_type, str_type])
    end

    it "returns empty key/value lists for an empty HashShape" do
      keys, values = described_class.send(:hash_shape_key_values, Rigor::Type::HashShape.new)
      expect(keys).to eq([])
      expect(values).to eq([])
    end

    it "returns the two type-args of a Nominal[Hash, [K, V]]" do
      hash = Rigor::Type::Combinator.nominal_of("Hash", type_args: [sym_type, int_type])
      keys, values = described_class.send(:hash_shape_key_values, hash)
      expect(keys).to eq([sym_type])
      expect(values).to eq([int_type])
    end

    it "returns empty lists for a Nominal[Hash] missing a type-arg" do
      hash = Rigor::Type::Combinator.nominal_of("Hash", type_args: [sym_type])
      keys, values = described_class.send(:hash_shape_key_values, hash)
      expect(keys).to eq([])
      expect(values).to eq([])
    end

    it "returns empty lists for a non-Hash Nominal" do
      array = Rigor::Type::Combinator.nominal_of("Array", type_args: [int_type])
      keys, values = described_class.send(:hash_shape_key_values, array)
      expect(keys).to eq([])
      expect(values).to eq([])
    end

    it "returns empty lists for a non-Hash type" do
      keys, values = described_class.send(:hash_shape_key_values, Rigor::Type::Combinator.constant_of(1))
      expect(keys).to eq([])
      expect(values).to eq([])
    end

    it "concats key/value evidence across every Union member" do
      shape = Rigor::Type::HashShape.new(a: int_type)
      hash = Rigor::Type::Combinator.nominal_of("Hash", type_args: [sym_type, str_type])
      union = Rigor::Type::Combinator.union(shape, hash)
      keys, values = described_class.send(:hash_shape_key_values, union)
      # Combinator.union may reorder members, so assert set membership rather than pair order.
      expect(keys).to contain_exactly(sym_type, sym_type)
      expect(values).to contain_exactly(int_type, str_type)
    end
  end

  describe ".drop_dynamic" do
    it "removes Dynamic constituents while keeping concrete types in order" do
      int_type = Rigor::Type::Combinator.nominal_of("Integer")
      str_type = Rigor::Type::Combinator.nominal_of("String")
      dyn = Rigor::Type::Combinator.untyped

      result = described_class.send(:drop_dynamic, [int_type, dyn, str_type])
      expect(result).to eq([int_type, str_type])
    end

    it "is a no-op when there is no Dynamic constituent" do
      int_type = Rigor::Type::Combinator.nominal_of("Integer")
      expect(described_class.send(:drop_dynamic, [int_type])).to eq([int_type])
    end
  end

  describe ".array_added_elements" do
    let(:int_type) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:str_type) { Rigor::Type::Combinator.nominal_of("String") }

    it "returns no evidence when there are no arguments" do
      expect(described_class.send(:array_added_elements, :push, [])).to eq([])
    end

    it "returns every argument directly for << / push / append / prepend / unshift" do
      %i[<< push append prepend unshift].each do |meth|
        result = described_class.send(:array_added_elements, meth, [int_type, str_type])
        expect(result).to eq([int_type, str_type]), "expected #{meth} to pass args through unchanged"
      end
    end

    it "flat_maps concat's arguments through collection_element_types" do
      tuple_arg = Rigor::Type::Combinator.tuple_of(int_type, str_type)
      result = described_class.send(:array_added_elements, :concat, [tuple_arg])
      expect(result).to eq([int_type, str_type])
    end

    it "flat_maps replace's arguments through collection_element_types" do
      array_arg = Rigor::Type::Combinator.nominal_of("Array", type_args: [str_type])
      result = described_class.send(:array_added_elements, :replace, [array_arg])
      expect(result).to eq([str_type])
    end

    it "drops the leading index argument for insert" do
      result = described_class.send(:array_added_elements, :insert, [int_type, str_type])
      expect(result).to eq([str_type])
    end

    it "takes only the last argument for []=" do
      key_type = Rigor::Type::Combinator.nominal_of("Integer")
      result = described_class.send(:array_added_elements, :[]=, [key_type, str_type])
      expect(result).to eq([str_type])
    end

    it "reports the single argument for a single-value fill" do
      expect(described_class.send(:array_added_elements, :fill, [int_type])).to eq([int_type])
    end

    it "reports no evidence for a multi-argument fill" do
      expect(described_class.send(:array_added_elements, :fill, [int_type, str_type])).to eq([])
    end
  end

  describe ".join_array_content" do
    let(:int_type) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:str_type) { Rigor::Type::Combinator.nominal_of("String") }
    let(:zero) { Rigor::Type::Combinator.constant_of(0) }

    it "unions seed and added element types, dropping the empty-seed Dynamic floor" do
      seed = Rigor::Type::Combinator.tuple_of(zero)
      result = described_class.send(:join_array_content, seed, [int_type])
      expect(result.class_name).to eq("Array")
      expect(result.type_args.first).to eq(Rigor::Type::Combinator.union(zero, int_type))
    end

    it "keeps the seed element type unchanged when there is no added evidence" do
      seed = Rigor::Type::Combinator.tuple_of(zero)
      result = described_class.send(:join_array_content, seed, [])
      expect(result.type_args.first).to eq(zero)
    end

    it "falls back to the Dynamic floor for an empty seed and no added evidence" do
      seed = Rigor::Type::Combinator.tuple_of
      result = described_class.send(:join_array_content, seed, [])
      expect(result.type_args.first).to be_a(Rigor::Type::Dynamic)
    end

    it "compacts nil entries out of the added elements" do
      seed = Rigor::Type::Combinator.tuple_of
      result = described_class.send(:join_array_content, seed, [int_type, nil])
      expect(result.type_args.first).to eq(int_type)
    end

    it "produces a Nominal[Array] carrier" do
      seed = Rigor::Type::Combinator.tuple_of(zero)
      result = described_class.send(:join_array_content, seed, [int_type])
      expect(result).to be_a(Rigor::Type::Nominal)
    end
  end

  describe ".join_hash_content" do
    let(:int_type) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:str_type) { Rigor::Type::Combinator.nominal_of("String") }
    let(:sym_type) { Rigor::Type::Combinator.nominal_of("Symbol") }

    it "unions seed and added key/value types, dropping the empty-seed Dynamic floor" do
      seed = Rigor::Type::HashShape.new(a: int_type)
      result = described_class.send(:join_hash_content, seed, [[sym_type, str_type]])
      expect(result.class_name).to eq("Hash")
      expect(result.type_args[0]).to eq(sym_type)
      expect(result.type_args[1]).to eq(Rigor::Type::Combinator.union(int_type, str_type))
    end

    it "falls back to the Dynamic/Dynamic floor for an empty seed and no added pairs" do
      result = described_class.send(:join_hash_content, Rigor::Type::HashShape.new, [])
      expect(result.type_args[0]).to be_a(Rigor::Type::Dynamic)
      expect(result.type_args[1]).to be_a(Rigor::Type::Dynamic)
    end

    it "compacts nil keys and nil values out of the added pairs independently" do
      result = described_class.send(:join_hash_content, Rigor::Type::HashShape.new, [[nil, int_type], [sym_type, nil]])
      expect(result.type_args[0]).to eq(sym_type)
      expect(result.type_args[1]).to eq(int_type)
    end

    it "concats (not unions) key/value evidence across a Union seed" do
      shape_seed = Rigor::Type::HashShape.new(a: int_type)
      hash_seed = Rigor::Type::Combinator.nominal_of("Hash", type_args: [sym_type, str_type])
      union_seed = Rigor::Type::Combinator.union(shape_seed, hash_seed)
      result = described_class.send(:join_hash_content, union_seed, [])
      expect(result.type_args[0]).to eq(sym_type)
      expect(result.type_args[1]).to eq(Rigor::Type::Combinator.union(int_type, str_type))
    end
  end

  # Issue #560 — the straight-line join's FP gate. Growing a carrier's element union can break a
  # HAND-WRITTEN signature (haml's `temple = [:multi]; temple << [:static, s]` against
  # `-> Array[:multi]`), so added evidence is admitted per member against the class set the seed
  # already carries, and a member the seed does not admit takes the gradual floor instead.
  describe ".admissible_evidence" do
    let(:untyped) { Rigor::Type::Combinator.untyped }

    def constant(value)
      Rigor::Type::Combinator.constant_of(value)
    end

    def nominal(name)
      Rigor::Type::Combinator.nominal_of(name)
    end

    it "admits a member whose class the seed already carries" do
      expect(described_class.admissible_evidence([constant(1)], [nominal("Integer")]))
        .to eq([nominal("Integer")])
    end

    it "floors a member whose class the seed does not carry" do
      expect(described_class.admissible_evidence([constant(:multi)], [nominal("String")]))
        .to eq([untyped])
    end

    # An empty seed has nothing to contradict, so nothing is floored — this is where the precision
    # goes (`stack = []; stack[top] = cs`).
    it "admits everything when the seed carries no evidence" do
      expect(described_class.admissible_evidence([], [nominal("String")])).to eq([nominal("String")])
    end

    # The seed comes from the pre-state LITERAL, and that is what separates these two: `[]` reads as
    # no members at all, while `[x]` on an untyped `x` reads as one Dynamic member that really does
    # say "this slot is unknown". Only the first may let `join_array_content`'s floor-dropping narrow
    # the carrier to the added class; the second keeps its own gradual member.
    it "keeps a gradual member when the seed carries a Dynamic of its own" do
      expect(described_class.admissible_evidence([untyped], [nominal("String")]))
        .to eq([nominal("String"), untyped])
    end

    # A gradual seed admits a foreign class precisely — a union that already carries `Dynamic[top]`
    # accepts against any declared element type, so the signature gate has nothing left to protect.
    it "admits a foreign class precisely once the seed is already gradual" do
      expect(described_class.admissible_evidence([constant(:multi), untyped], [nominal("String")]))
        .to eq([nominal("String"), untyped])
    end

    it "reads a Union seed's members individually" do
      seed = [Rigor::Type::Combinator.union(constant(:a), nominal("Integer"))]
      expect(described_class.admissible_evidence(seed, [nominal("Integer"), nominal("String")]))
        .to eq([nominal("Integer"), untyped])
    end

    # A carrier whose class cannot be named cannot be SHOWN compatible, so it floors. The Tuple case
    # is the haml one: an appended `[:static, …]` is an Array, and a Symbol seed does not admit it.
    it "names Tuple and HashShape by their runtime class" do
      expect(described_class.evidence_class(Rigor::Type::Combinator.tuple_of)).to eq("Array")
      expect(described_class.evidence_class(Rigor::Type::HashShape.new)).to eq("Hash")
      expect(described_class.evidence_class(Rigor::Type::Combinator.untyped)).to be_nil
    end
  end
end
