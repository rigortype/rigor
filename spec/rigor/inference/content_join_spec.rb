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

    # The seams read their seed from before the mutation widening runs, so a `non-empty-array[T]`
    # refinement reaches here as itself rather than as the `Array[T]` base the widening leaves.
    it "reads a non-empty-array refinement through to its base's element type" do
      non_empty = Rigor::Type::Combinator.non_empty_array(str_type)
      expect(described_class.send(:collection_element_types, non_empty)).to eq([str_type])
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

    it "reads a non-empty-hash refinement through to its base's key and value types" do
      non_empty = Rigor::Type::Combinator.non_empty_hash(sym_type, int_type)
      keys, values = described_class.send(:hash_shape_key_values, non_empty)
      expect(keys).to eq([sym_type])
      expect(values).to eq([int_type])
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
    let(:untyped) { Rigor::Type::Combinator.untyped }

    it "unions seed and added element types" do
      seed = Rigor::Type::Combinator.tuple_of(zero)
      result = described_class.send(:join_array_content, seed, [int_type])
      expect(result.class_name).to eq("Array")
      expect(result.type_args.first).to eq(Rigor::Type::Combinator.union(zero, int_type))
    end

    # An EMPTY literal seed has no element to contribute, so the added evidence is the whole answer.
    # This is how `out = []; xs.each { out << x*2 }` reads `Array[Integer]`: the seams hand this
    # method the literal, never the `Array[untyped]` the arity-forget spells it as.
    it "lets added evidence close an empty literal seed" do
      seed = Rigor::Type::Combinator.tuple_of
      result = described_class.send(:join_array_content, seed, [int_type])
      expect(result.type_args.first).to eq(int_type)
    end

    # Issue #586 — a seed's OWN gradual arm is a statement about what the collection already holds
    # (a parameter declared `Array[untyped]`, an `Array.new`), and the added evidence says nothing
    # about that. Dropping it closed a declared `Array[untyped]` parameter to `Array[Integer]` and
    # drew `undefined method 'upcase'` on `a.first.upcase`, which the declaration licenses.
    it "keeps a seed's own Dynamic element arm next to added evidence" do
      seed = Rigor::Type::Combinator.nominal_of("Array", type_args: [untyped])
      result = described_class.send(:join_array_content, seed, [int_type])
      expect(result.type_args.first).to eq(Rigor::Type::Combinator.union(untyped, int_type))
    end

    it "keeps a Dynamic slot of a literal seed as evidence" do
      seed = Rigor::Type::Combinator.tuple_of(untyped)
      result = described_class.send(:join_array_content, seed, [int_type])
      expect(result.type_args.first).to eq(Rigor::Type::Combinator.union(untyped, int_type))
    end

    it "joins onto a non-empty-array refinement's base element type" do
      seed = Rigor::Type::Combinator.non_empty_array(str_type)
      result = described_class.send(:join_array_content, seed, [int_type])
      expect(result.type_args.first).to eq(Rigor::Type::Combinator.union(str_type, int_type))
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
    let(:untyped) { Rigor::Type::Combinator.untyped }

    it "unions seed and added key/value types" do
      seed = Rigor::Type::HashShape.new(a: int_type)
      result = described_class.send(:join_hash_content, seed, [[sym_type, str_type]])
      expect(result.class_name).to eq("Hash")
      expect(result.type_args[0]).to eq(sym_type)
      expect(result.type_args[1]).to eq(Rigor::Type::Combinator.union(int_type, str_type))
    end

    it "lets a stored pair close an empty literal seed" do
      result = described_class.send(:join_hash_content, Rigor::Type::HashShape.new, [[sym_type, str_type]])
      expect(result.type_args[0]).to eq(sym_type)
      expect(result.type_args[1]).to eq(str_type)
    end

    # Issue #586, the Hash twin: a declared `Hash[untyped, untyped]` keeps both gradual arms however
    # many pairs the body stores.
    it "keeps a seed's own Dynamic key and value arms next to a stored pair" do
      seed = Rigor::Type::Combinator.nominal_of("Hash", type_args: [untyped, untyped])
      result = described_class.send(:join_hash_content, seed, [[sym_type, str_type]])
      expect(result.type_args[0]).to eq(Rigor::Type::Combinator.union(untyped, sym_type))
      expect(result.type_args[1]).to eq(Rigor::Type::Combinator.union(untyped, str_type))
    end

    it "joins onto a non-empty-hash refinement's base key and value types" do
      seed = Rigor::Type::Combinator.non_empty_hash(sym_type, int_type)
      result = described_class.send(:join_hash_content, seed, [[sym_type, str_type]])
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

    # An empty seed has nothing to contradict, so the added evidence joins outright. This is the
    # ARRAY-side answer; the Hash side gradualizes downstream in `MutationWidening#admitted_union`,
    # because a Hash parameter is a union over keys that a read selects one of.
    it "admits everything when the seed carries no evidence" do
      expect(described_class.admissible_evidence([], [nominal("String")])).to eq([nominal("String")])
    end

    # A seed whose own slot the engine could not type cannot rule anything out either, so it admits
    # like an empty one. (Whether the RESULT stays open is the caller's decision, not this method's
    # — `MutationWidening#gradual_floor` owns it.)
    it "admits everything when the seed carries a Dynamic of its own" do
      expect(described_class.admissible_evidence([untyped], [nominal("String")]))
        .to eq([nominal("String")])
    end

    it "admits a foreign class once the seed is already gradual" do
      expect(described_class.admissible_evidence([constant(:multi), untyped], [nominal("String")]))
        .to eq([nominal("String")])
    end

    # N1 — a Union argument is judged member-by-member, not wholesale. `evidence_class` has no
    # answer for a Union, so the wholesale reading floored `String | Integer` against an Integer
    # seed even though half of it is admissible.
    it "admits a Union argument member-by-member" do
      added = Rigor::Type::Combinator.union(nominal("Integer"), nominal("String"))
      expect(described_class.admissible_evidence([constant(1)], [added]))
        .to eq([nominal("Integer"), untyped])
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
