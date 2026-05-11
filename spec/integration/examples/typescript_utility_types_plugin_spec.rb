# frozen_string_literal: true

# Integration spec for `examples/rigor-typescript-utility-types/`.
# Covers ADR-13's intended end-to-end flow: an RBS::Extended
# payload using TypeScript-canonical spellings (`Pick`, `Omit`,
# `Partial`, `Required`, `Readonly`) reaches the parser, the
# plugin chain resolves it through the recursive Resolver, and
# the result is the same Type carrier the canonical core
# spellings (`pick_of`, etc.) would produce.

require "spec_helper"

TYPESCRIPT_UTILITY_TYPES_PLUGIN_LIB =
  File.expand_path("../../../examples/rigor-typescript-utility-types/lib", __dir__)
$LOAD_PATH.unshift(TYPESCRIPT_UTILITY_TYPES_PLUGIN_LIB) unless $LOAD_PATH.include?(TYPESCRIPT_UTILITY_TYPES_PLUGIN_LIB)
require "rigor-typescript-utility-types"

RSpec.describe "examples/rigor-typescript-utility-types" do # rubocop:disable RSpec/DescribeClass
  let(:plugin_class) { Rigor::Plugin::TypescriptUtilityTypes }

  let(:name_scope) do
    chain = Rigor::TypeNode::ResolverChain.new(plugin_class.manifest.type_node_resolvers)
    Rigor::TypeNode::NameScope.new(resolver: chain)
  end

  def parse(payload)
    Rigor::Builtins::ImportedRefinements.parse(payload, name_scope: name_scope)
  end

  describe "Pick<T, K>" do
    it "fires the Pick resolver and returns the lossy-degraded result for Nominal inputs" do
      # `Address` resolves to Nominal[Address] (no shape
      # evidence); `NameKey` resolves to Nominal[NameKey] (not
      # a Constant<Symbol|String> or Union of such), so pick_of
      # degrades to "input unchanged" per ADR-13 phase A. The
      # observable difference from "chain declined → Nominal
      # fallback" is the ABSENCE of `Pick` in the result.
      expect(parse("Pick[Address, NameKey]")).to eq(Rigor::Type::Combinator.nominal_of("Address"))
    end

    it "falls back to Nominal[Pick, …] when the resolver declines on arity mismatch" do
      # 1-arg / 3-arg Pick: plugin returns nil → parser's RBS
      # fallback builds Nominal[Pick, …].
      expected_one = Rigor::Type::Combinator.nominal_of("Pick", type_args: [Rigor::Type::Combinator.nominal_of("Address")])
      expect(parse("Pick[Address]")).to eq(expected_one)
    end
  end

  describe "Omit<T, K>" do
    it "fires the Omit resolver and returns the lossy-degraded result for Nominal inputs" do
      expect(parse("Omit[Address, SecretKey]")).to eq(Rigor::Type::Combinator.nominal_of("Address"))
    end
  end

  describe "Partial<T> / Required<T> / Readonly<T> (single-arg utilities)" do
    it "resolves Partial through partial_of" do
      expect(parse("Partial[Address]")).to eq(Rigor::Type::Combinator.nominal_of("Address"))
    end

    it "resolves Required through required_of" do
      expect(parse("Required[Address]")).to eq(Rigor::Type::Combinator.nominal_of("Address"))
    end

    it "resolves Readonly through readonly_of" do
      expect(parse("Readonly[Address]")).to eq(Rigor::Type::Combinator.nominal_of("Address"))
    end

    it "falls back to Nominal when arity is wrong (resolver declines)" do
      expected = Rigor::Type::Combinator.nominal_of(
        "Partial",
        type_args: [Rigor::Type::Combinator.nominal_of("A"), Rigor::Type::Combinator.nominal_of("B")]
      )
      expect(parse("Partial[A, B]")).to eq(expected)
    end
  end

  describe "unmapped TypeScript utility names degrade to Nominal" do
    it "Parameters<F> falls through the chain to Nominal[Parameters, [F]]" do
      expected = Rigor::Type::Combinator.nominal_of(
        "Parameters",
        type_args: [Rigor::Type::Combinator.nominal_of("Foo")]
      )
      expect(parse("Parameters[Foo]")).to eq(expected)
    end

    it "ReturnType<F> falls through to Nominal[ReturnType, [F]]" do
      expected = Rigor::Type::Combinator.nominal_of(
        "ReturnType",
        type_args: [Rigor::Type::Combinator.nominal_of("Foo")]
      )
      expect(parse("ReturnType[Foo]")).to eq(expected)
    end
  end

  describe "recursive resolution via scope.resolver.resolve" do
    it "Pick<Address, non-empty-string> resolves the K arg through the built-in registry" do
      # Pick<X, K> where K is a refinement name — the K arg
      # resolves through built-in registry, not through the
      # chain. The plugin returns pick_of(Nominal[Address],
      # non-empty-string refinement carrier).
      result = parse("Pick[Address, non-empty-string]")
      expected = Rigor::Type::Combinator.pick_of(
        Rigor::Type::Combinator.nominal_of("Address"),
        Rigor::Type::Combinator.non_empty_string
      )
      expect(result).to eq(expected)
    end
  end

  describe "resolver-level semantics (synthetic AST + scope)" do
    # The RBS::Extended payload grammar doesn't yet accept Symbol /
    # String literal tokens (`:name` / `"name"`), so end-to-end
    # parsing of Pick<HashShape, :a | :b> isn't reachable through
    # `ImportedRefinements.parse` yet. To prove the plugin's
    # resolvers produce the right pick_of / partial_of / etc. on
    # actual shape inputs, we invoke the resolver directly with a
    # synthetic AST and a `NameScope` whose `resolver:` is a
    # hand-rolled stub that knows how to map specific identifiers
    # to the shape carriers under test.

    let(:string_t)  { Rigor::Type::Combinator.nominal_of("String") }
    let(:integer_t) { Rigor::Type::Combinator.nominal_of("Integer") }

    let(:hash_shape) do
      Rigor::Type::Combinator.hash_shape_of(
        { name: string_t, age: integer_t, email: string_t },
        required_keys: %i[name age],
        optional_keys: %i[email]
      )
    end

    def build_scope(name_to_type)
      stub_resolver = Class.new(Rigor::Plugin::TypeNodeResolver) do
        define_method(:resolve) do |node, _scope|
          name_to_type[node.name] if node.is_a?(Rigor::TypeNode::Identifier)
        end
      end.new
      Rigor::TypeNode::NameScope.new(resolver: stub_resolver)
    end

    it "Partial<Address> resolves to a fully-optional HashShape" do
      partial = plugin_class::Resolvers::Partial.new
      node = Rigor::TypeNode::Generic.new(
        head: "Partial",
        args: [Rigor::TypeNode::Identifier.new(name: "Address")]
      )
      result = partial.resolve(node, build_scope("Address" => hash_shape))
      expect(result.required_keys).to eq([])
      expect(result.optional_keys.sort).to eq(%i[age email name])
      # Value types unchanged per ADR-13 § "Required-ness flips"
      expect(result.pairs).to eq(name: string_t, age: integer_t, email: string_t)
    end

    it "Required<Address> resolves to a fully-required HashShape" do
      required = plugin_class::Resolvers::Required.new
      node = Rigor::TypeNode::Generic.new(
        head: "Required",
        args: [Rigor::TypeNode::Identifier.new(name: "Address")]
      )
      result = required.resolve(node, build_scope("Address" => hash_shape))
      expect(result.required_keys.sort).to eq(%i[age email name])
      expect(result.optional_keys).to eq([])
    end

    it "Readonly<Address> marks every entry read-only" do
      readonly = plugin_class::Resolvers::Readonly.new
      node = Rigor::TypeNode::Generic.new(
        head: "Readonly",
        args: [Rigor::TypeNode::Identifier.new(name: "Address")]
      )
      result = readonly.resolve(node, build_scope("Address" => hash_shape))
      expect(result.read_only_keys.sort).to eq(%i[age email name])
    end

    it "Pick<Address, KeysProxy> degrades to the source HashShape when KeysProxy isn't a literal-key set" do
      pick = plugin_class::Resolvers::Pick.new
      node = Rigor::TypeNode::Generic.new(
        head: "Pick",
        args: [
          Rigor::TypeNode::Identifier.new(name: "Address"),
          Rigor::TypeNode::Identifier.new(name: "KeysProxy")
        ]
      )
      result = pick.resolve(node, build_scope(
                                    "Address" => hash_shape,
                                    "KeysProxy" => Rigor::Type::Combinator.nominal_of("KeysProxy")
                                  ))
      # K isn't a Constant<Symbol> / Union[Constant<Symbol>, …],
      # so pick_of degrades to "input unchanged" — but the plugin
      # DID fire (the result is the HashShape, not a Nominal[Pick, …]
      # fallback).
      expect(result).to eq(hash_shape)
    end
  end
end
