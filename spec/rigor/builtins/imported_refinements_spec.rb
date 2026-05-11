# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Builtins::ImportedRefinements do
  describe ".lookup" do
    it "resolves the point-removal refinements to their Difference shape" do
      expect(described_class.lookup("non-empty-string"))
        .to eq(Rigor::Type::Combinator.non_empty_string)
      expect(described_class.lookup("non-zero-int"))
        .to eq(Rigor::Type::Combinator.non_zero_int)
      expect(described_class.lookup("non-empty-array"))
        .to eq(Rigor::Type::Combinator.non_empty_array)
      expect(described_class.lookup("non-empty-hash"))
        .to eq(Rigor::Type::Combinator.non_empty_hash)
    end

    it "resolves the IntegerRange-backed refinements" do
      expect(described_class.lookup("positive-int"))
        .to eq(Rigor::Type::Combinator.positive_int)
      expect(described_class.lookup("non-negative-int"))
        .to eq(Rigor::Type::Combinator.non_negative_int)
      expect(described_class.lookup("negative-int"))
        .to eq(Rigor::Type::Combinator.negative_int)
      expect(described_class.lookup("non-positive-int"))
        .to eq(Rigor::Type::Combinator.non_positive_int)
    end

    it "resolves the predicate-subset refinements to their Refined shape" do
      expect(described_class.lookup("lowercase-string"))
        .to eq(Rigor::Type::Combinator.lowercase_string)
      expect(described_class.lookup("uppercase-string"))
        .to eq(Rigor::Type::Combinator.uppercase_string)
      expect(described_class.lookup("numeric-string"))
        .to eq(Rigor::Type::Combinator.numeric_string)
    end

    it "resolves the base-N int-string predicate refinements" do
      expect(described_class.lookup("decimal-int-string"))
        .to eq(Rigor::Type::Combinator.decimal_int_string)
      expect(described_class.lookup("octal-int-string"))
        .to eq(Rigor::Type::Combinator.octal_int_string)
      expect(described_class.lookup("hex-int-string"))
        .to eq(Rigor::Type::Combinator.hex_int_string)
    end

    it "resolves composite Intersection-backed refinements" do
      expect(described_class.lookup("non-empty-lowercase-string"))
        .to eq(Rigor::Type::Combinator.non_empty_lowercase_string)
      expect(described_class.lookup("non-empty-uppercase-string"))
        .to eq(Rigor::Type::Combinator.non_empty_uppercase_string)
    end

    it "returns nil for an unknown name" do
      expect(described_class.lookup("frobinator-string")).to be_nil
      expect(described_class.lookup("")).to be_nil
    end

    it "accepts symbols as names" do
      expect(described_class.lookup(:"non-empty-string"))
        .to eq(Rigor::Type::Combinator.non_empty_string)
    end
  end

  describe ".known? / .known_names" do
    it "answers .known? truthfully for both bare and parameterised names" do
      expect(described_class.known?("non-empty-string")).to be(true)
      expect(described_class.known?("non-empty-array")).to be(true) # bare alias too
      expect(described_class.known?("int")).to be(true) # parameterised-only
      expect(described_class.known?("frobinator-string")).to be(false)
    end

    it "lists every catalogued name" do
      expect(described_class.known_names).to include(
        "non-empty-string", "non-zero-int", "non-empty-array",
        "non-empty-hash", "positive-int", "non-negative-int",
        "negative-int", "non-positive-int",
        "lowercase-string", "uppercase-string", "numeric-string",
        "decimal-int-string", "octal-int-string", "hex-int-string",
        "non-empty-lowercase-string", "non-empty-uppercase-string",
        "int"
      )
    end
  end

  describe ".parse" do
    it "resolves bare kebab-case names just like .lookup" do
      expect(described_class.parse("non-empty-string"))
        .to eq(Rigor::Type::Combinator.non_empty_string)
      expect(described_class.parse("lowercase-string"))
        .to eq(Rigor::Type::Combinator.lowercase_string)
    end

    it "tolerates leading and trailing whitespace" do
      expect(described_class.parse("  non-empty-string  "))
        .to eq(Rigor::Type::Combinator.non_empty_string)
    end

    it "parses non-empty-array[T] with an RBS class type-arg" do
      expect(described_class.parse("non-empty-array[Integer]"))
        .to eq(Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("Integer")))
    end

    it "parses non-empty-array[T] with a refinement type-arg" do
      expect(described_class.parse("non-empty-array[non-empty-string]"))
        .to eq(Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.non_empty_string))
    end

    it "parses non-empty-hash[K, V] with two type-args" do
      expect(described_class.parse("non-empty-hash[Symbol, Integer]"))
        .to eq(Rigor::Type::Combinator.non_empty_hash(
                 Rigor::Type::Combinator.nominal_of("Symbol"),
                 Rigor::Type::Combinator.nominal_of("Integer")
               ))
    end

    it "tolerates whitespace inside bracketed lists" do
      expect(described_class.parse("non-empty-hash[ Symbol , Integer ]"))
        .to eq(Rigor::Type::Combinator.non_empty_hash(
                 Rigor::Type::Combinator.nominal_of("Symbol"),
                 Rigor::Type::Combinator.nominal_of("Integer")
               ))
    end

    it "parses int<min, max> with signed integer bounds" do
      expect(described_class.parse("int<5, 10>"))
        .to eq(Rigor::Type::Combinator.integer_range(5, 10))
      expect(described_class.parse("int<-3, 7>"))
        .to eq(Rigor::Type::Combinator.integer_range(-3, 7))
    end

    it "returns nil for arity mismatches in parameterised forms" do
      expect(described_class.parse("non-empty-array[Integer, String]")).to be_nil
      expect(described_class.parse("non-empty-hash[Symbol]")).to be_nil
      expect(described_class.parse("int<5>")).to be_nil
    end

    it "returns nil for unknown head names even when bracketed" do
      expect(described_class.parse("frobinator[Integer]")).to be_nil
      expect(described_class.parse("uint<0, 10>")).to be_nil
    end

    it "returns nil for malformed payloads" do
      expect(described_class.parse("non-empty-array[")).to be_nil
      expect(described_class.parse("int<5, 10")).to be_nil
      expect(described_class.parse("non-empty-array[Integer")).to be_nil
      expect(described_class.parse("non-empty-array[Integer]extra")).to be_nil
      expect(described_class.parse("")).to be_nil
    end

    describe "type-function payloads (v0.0.7)" do
      it "parses key_of[Hash[Symbol, Integer]] to Symbol" do
        expect(described_class.parse("key_of[Hash[Symbol, Integer]]"))
          .to eq(Rigor::Type::Combinator.nominal_of("Symbol"))
      end

      it "parses value_of[Hash[Symbol, Integer]] to Integer" do
        expect(described_class.parse("value_of[Hash[Symbol, Integer]]"))
          .to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end

      it "parses key_of[Array[String]] to non-negative-int" do
        expect(described_class.parse("key_of[Array[String]]"))
          .to eq(Rigor::Type::Combinator.non_negative_int)
      end

      it "parses value_of[Array[String]] to String" do
        expect(described_class.parse("value_of[Array[String]]"))
          .to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "parses key_of[Hash] (no element types) to untyped" do
        expect(described_class.parse("key_of[Hash]"))
          .to eq(Rigor::Type::Combinator.untyped)
      end

      it "rejects key_of arity mismatch" do
        expect(described_class.parse("key_of[Hash, Symbol]")).to be_nil
        expect(described_class.parse("key_of[]")).to be_nil
      end

      describe "T[K] indexed-access (v0.0.7)" do # rubocop:disable RSpec/NestedGroups
        it "parses Hash[Symbol, Integer][Symbol] to Integer" do
          expect(described_class.parse("Hash[Symbol, Integer][Symbol]"))
            .to eq(Rigor::Type::Combinator.nominal_of("Integer"))
        end

        it "parses Array[String][Integer] to String" do
          expect(described_class.parse("Array[String][Integer]"))
            .to eq(Rigor::Type::Combinator.nominal_of("String"))
        end

        it "parses key_of[Hash[Symbol, Integer]][Symbol] (chained)" do
          # key_of[Hash[Symbol, Integer]] = Symbol; Symbol[…] is Top
          # because Symbol is not an indexable shape. The chain still
          # parses without error.
          result = described_class.parse("key_of[Hash[Symbol, Integer]][Symbol]")
          expect(result).to be_a(Rigor::Type::Top)
        end

        it "rejects multi-arg index forms" do
          expect(described_class.parse("Hash[Symbol, Integer][Symbol, Integer]")).to be_nil
        end
      end

      describe "int_mask / int_mask_of" do # rubocop:disable RSpec/NestedGroups
        it "parses int_mask[1, 2] to the closure {0, 1, 2, 3}" do
          result = described_class.parse("int_mask[1, 2]")
          expect(result).to be_a(Rigor::Type::Union)
          expect(result.members.map(&:value).sort).to eq([0, 1, 2, 3])
        end

        it "parses int_mask[1, 2, 4] to the closure {0..7}" do
          result = described_class.parse("int_mask[1, 2, 4]")
          expect(result).to be_a(Rigor::Type::Union)
          expect(result.members.map(&:value).sort).to eq([0, 1, 2, 3, 4, 5, 6, 7])
        end

        it "parses int_mask[1, 4] to the non-contiguous closure {0, 1, 4, 5}" do
          result = described_class.parse("int_mask[1, 4]")
          expect(result.members.map(&:value).sort).to eq([0, 1, 4, 5])
        end

        it "declines int_mask with non-integer args" do
          expect(described_class.parse("int_mask[Symbol, Integer]")).to be_nil
        end

        it "declines int_mask with negative flags" do
          expect(described_class.parse("int_mask[-1, 2]")).to be_nil
        end

        it "parses int_mask_of[Constant union]" do
          # int_mask_of expects a single type arg; the parser
          # accepts the resolved type. We use raw Combinator
          # construction here because the parser grammar does
          # not have a direct surface for ad-hoc Constant
          # unions yet.
          flags = Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.constant_of(1),
            Rigor::Type::Combinator.constant_of(2)
          )
          expect(Rigor::Type::Combinator.int_mask_of(flags).members.map(&:value).sort)
            .to eq([0, 1, 2, 3])
        end
      end
    end

    describe "shape projection (ADR-13 slice 4)" do
      it "resolves pick_of[Foo, ...] when Foo names a Nominal carrier" do
        # `Foo` resolves to Nominal[Foo]; pick_of on a non-HashShape
        # returns the input unchanged (lossy degradation).
        result = described_class.parse("pick_of[Foo, NameKey]")
        expect(result).to eq(Rigor::Type::Combinator.nominal_of("Foo"))
      end

      it "rejects pick_of arity mismatch" do
        expect(described_class.parse("pick_of[Foo]")).to be_nil
        expect(described_class.parse("pick_of[Foo, A, B]")).to be_nil
      end

      it "rejects omit_of arity mismatch" do
        expect(described_class.parse("omit_of[Foo]")).to be_nil
      end

      it "resolves partial_of[T] / required_of[T] / readonly_of[T] for Nominal inputs (no-op degrade)" do
        foo = Rigor::Type::Combinator.nominal_of("Foo")
        expect(described_class.parse("partial_of[Foo]")).to eq(foo)
        expect(described_class.parse("required_of[Foo]")).to eq(foo)
        expect(described_class.parse("readonly_of[Foo]")).to eq(foo)
      end

      it "rejects partial_of / required_of / readonly_of with arity mismatches" do
        expect(described_class.parse("partial_of[A, B]")).to be_nil
        expect(described_class.parse("required_of[A, B]")).to be_nil
        expect(described_class.parse("readonly_of[A, B]")).to be_nil
      end
    end

    describe "shape projection — Tuple (ADR-13 slice 5)" do
      it "evaluates pick_of of a built-up Tuple via Tuple-shaped K argument" do
        # Construct Tuple[String, Integer] inline through an
        # auxiliary plugin path is heavy; instead, walk through
        # Combinator directly to confirm the parser-builder
        # pipeline isn't a bottleneck. The tuple_of binding is
        # tested at the Combinator layer.
        tuple = Rigor::Type::Combinator.tuple_of(
          Rigor::Type::Combinator.nominal_of("String"),
          Rigor::Type::Combinator.nominal_of("Integer")
        )
        result = Rigor::Type::Combinator.pick_of(tuple, Rigor::Type::Combinator.constant_of(0))
        expect(result).to eq(Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String")))
      end
    end

    describe "plugin TypeNodeResolver chain integration (ADR-13 slice 3)" do
      def make_resolver(&block)
        Class.new(Rigor::Plugin::TypeNodeResolver) do
          define_method(:resolve) do |node, scope|
            block&.call(node, scope)
          end
        end.new
      end

      def make_scope(*resolvers, class_context: nil)
        chain = Rigor::TypeNode::ResolverChain.new(resolvers)
        Rigor::TypeNode::NameScope.new(resolver: chain, class_context: class_context)
      end

      it "consults the chain after the bare-name built-in registry misses" do
        replacement = Rigor::Type::Combinator.nominal_of("String")
        resolver = make_resolver do |node, _scope|
          next unless node.is_a?(Rigor::TypeNode::Identifier) && node.name == "my-custom-name"

          replacement
        end
        scope = make_scope(resolver)
        expect(described_class.parse("my-custom-name", name_scope: scope)).to eq(replacement)
      end

      it "does NOT consult the chain when the built-in registry resolves the name" do
        called = false
        resolver = make_resolver do |_node, _scope|
          called = true
          Rigor::Type::Combinator.nominal_of("String")
        end
        scope = make_scope(resolver)
        # `non-empty-string` is a built-in; the chain MUST NOT see it.
        described_class.parse("non-empty-string", name_scope: scope)
        expect(called).to be(false)
      end

      it "consults the chain for class-shaped Generic before the Nominal fallback" do
        seen = nil
        resolver = make_resolver do |node, _scope|
          seen = node if node.is_a?(Rigor::TypeNode::Generic) && node.head == "Pick"
          # Resolver still declines so the Nominal fallback runs and the
          # parse remains valid.
          nil
        end
        scope = make_scope(resolver)
        # Parse to ensure the chain DID see the Pick node before fallback.
        described_class.parse("Pick[Address]", name_scope: scope)
        expect(seen).to be_a(Rigor::TypeNode::Generic)
        expect(seen.head).to eq("Pick")
        expect(seen.args.first.name).to eq("Address")
      end

      it "lets the chain override the Nominal fallback for class-shaped names" do
        replacement_carrier = Rigor::Type::Combinator.untyped
        resolver = make_resolver do |node, _scope|
          next unless node.is_a?(Rigor::TypeNode::Generic) && node.head == "Pick"

          replacement_carrier
        end
        scope = make_scope(resolver)
        expect(described_class.parse("Pick[Address, String]", name_scope: scope)).to eq(replacement_carrier)
      end

      it "consults plugin resolvers in registration order; first non-nil wins" do
        replacement = Rigor::Type::Combinator.nominal_of("String")
        first  = make_resolver { |_node, _scope| nil }
        second = make_resolver { |_node, _scope| replacement }
        third  = make_resolver { |_node, _scope| raise "must not be called" }
        scope = make_scope(first, second, third)
        expect(described_class.parse("my-name", name_scope: scope)).to eq(replacement)
      end

      it "falls back to nil when the chain declines and no built-in / RBS path matches" do
        scope = make_scope(make_resolver { |_node, _scope| nil })
        expect(described_class.parse("genuinely-unknown-name", name_scope: scope)).to be_nil
      end

      it "preserves slice-1 / slice-2 behaviour when no NameScope is supplied" do
        # Bare names that miss the built-in registry return nil (parser
        # fail-soft); class-shaped names fall back to Nominal.
        expect(described_class.parse("my-custom-name")).to be_nil
        expected = Rigor::Type::Combinator.nominal_of(
          "Pick",
          type_args: [Rigor::Type::Combinator.nominal_of("Address")]
        )
        expect(described_class.parse("Pick[Address]")).to eq(expected)
      end
    end
  end
end
