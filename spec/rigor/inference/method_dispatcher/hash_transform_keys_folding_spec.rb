# frozen_string_literal: true

require "spec_helper"

# Every decline is paired with a neighbouring call that still answers, because a construction mistake in a
# decline-only example also yields nil.
RSpec.describe Rigor::Inference::MethodDispatcher::HashTransformKeysFolding do
  def constant(value) = Rigor::Type::Combinator.constant_of(value)
  def nominal(name) = Rigor::Type::Combinator.nominal_of(name)
  def hash_of(key, value) = Rigor::Type::Combinator.nominal_of("Hash", type_args: [key, value])
  def shape(pairs, **) = Rigor::Type::Combinator.hash_shape_of(pairs, **)
  def union(*members) = Rigor::Type::Combinator.union(*members)
  def untyped = Rigor::Type::Combinator.untyped

  def call_node(source) = Prism.parse(source).value.statements.body.first

  def dispatch(receiver:, args:, block_type: nil, method_name: :transform_keys, call_node: nil)
    described_class.try_dispatch(
      cc(receiver: receiver, method_name: method_name, args: args, block_type: block_type, call_node: call_node)
    )
  end

  let(:pair_shape) { shape({ a: constant(1), b: constant(2) }) }
  let(:rename_a) { shape({ a: constant(:z) }) }

  describe ".try_dispatch" do
    it "joins the mapping's values with the block's return type" do
      expect(dispatch(receiver: pair_shape, args: [rename_a], block_type: nominal("String")))
        .to eq(hash_of(union(nominal("String"), constant(:z)), union(constant(1), constant(2))))
    end

    it "joins the mapping's values with the receiver's keys when there is no block" do
      expect(dispatch(receiver: pair_shape, args: [rename_a]))
        .to eq(hash_of(union(constant(:a), constant(:b), constant(:z)), union(constant(1), constant(2))))
    end

    it "reads a Hash nominal receiver and mapping through their type arguments" do
      result = dispatch(receiver: hash_of(nominal("Symbol"), nominal("Integer")),
                        args: [hash_of(nominal("Symbol"), nominal("String"))], block_type: nominal("Integer"))
      expect(result).to eq(hash_of(union(nominal("Integer"), nominal("String")), nominal("Integer")))
    end

    it "reads non-empty-hash through its base" do
      receiver = Rigor::Type::Combinator.non_empty_hash(nominal("Symbol"), nominal("Integer"))
      expect(dispatch(receiver: receiver, args: [rename_a]))
        .to eq(hash_of(union(nominal("Symbol"), constant(:z)), nominal("Integer")))
    end

    it "answers a union receiver member by member" do
      receiver = union(shape({ a: constant(1) }), hash_of(nominal("String"), nominal("Float")))
      expect(dispatch(receiver: receiver, args: [rename_a])).to eq(
        union(hash_of(union(constant(:a), constant(:z)), constant(1)),
              hash_of(union(nominal("String"), constant(:z)), nominal("Float")))
      )
    end

    it "joins the values of every member of a union mapping" do
      mapping = union(rename_a, shape({ b: constant(:y) }))
      expect(dispatch(receiver: pair_shape, args: [mapping], block_type: nominal("String")))
        .to eq(hash_of(union(nominal("String"), constant(:z), constant(:y)), union(constant(1), constant(2))))
    end

    it "reads a non-empty-hash mapping through its base" do
      mapping = Rigor::Type::Combinator.non_empty_hash(nominal("Symbol"), nominal("String"))
      expect(dispatch(receiver: pair_shape, args: [mapping], block_type: nominal("Integer")))
        .to eq(hash_of(union(nominal("Integer"), nominal("String")), union(constant(1), constant(2))))
    end

    it "treats &nil as no block" do
      node = call_node("h.transform_keys(m, &nil)")
      expect(dispatch(receiver: pair_shape, args: [rename_a], block_type: untyped, call_node: node))
        .to eq(hash_of(union(constant(:a), constant(:b), constant(:z)), union(constant(1), constant(2))))
    end

    describe "an argument it cannot read" do
      it "adds a Dynamic[top] key arm for a mapping whose value type is unknown" do
        # A generic that is not `Hash` keeps its second type argument to itself: `Pair[String, Integer]`'s
        # `Integer` says nothing about what `to_hash` would hand back.
        pair = Rigor::Type::Combinator.nominal_of("Pair", type_args: [nominal("String"), nominal("Integer")])
        [untyped, nominal("Hash"), nominal("Object"), nominal("ActiveSupport::HashWithIndifferentAccess"), pair,
         union(rename_a, constant(nil))].each do |mapping|
          result = dispatch(receiver: pair_shape, args: [mapping], block_type: nominal("String"))
          expect(result.type_args.first.members).to include(untyped), "for #{mapping.describe}"
          expect(result.type_args.last).to eq(union(constant(1), constant(2)))
        end
      end

      # The engine records no aliasing, so `m = {}; m.tap { |x| x[:a] = :z }` still reads `{}`.
      it "adds a Dynamic[top] key arm for an empty mapping, not a bot one" do
        expect(dispatch(receiver: pair_shape, args: [shape({})], block_type: nominal("String")))
          .to eq(hash_of(union(nominal("String"), untyped), union(constant(1), constant(2))))
      end

      # `{ **o, b: :y }` types as `Hash[:b, :y]`: the literal's type leaves the splatted entries out.
      it "adds a Dynamic[top] key arm for a mapping literal with a **splat entry" do
        ["h.transform_keys(**o, b: :y)", "h.transform_keys({ **o, b: :y })",
         "h.send(:transform_keys, { **o, b: :y })", "h.public_send(:transform_keys, **o, b: :y)"].each do |source|
          result = dispatch(receiver: pair_shape, args: [shape({ b: constant(:y) })], call_node: call_node(source))
          expect(result).to eq(hash_of(union(constant(:a), constant(:b), constant(:y), untyped),
                                       union(constant(1), constant(2)))), "for #{source}"
        end
        expect(dispatch(receiver: pair_shape, args: [shape({ b: constant(:y) })],
                        call_node: call_node("h.transform_keys(b: :y)")))
          .to eq(hash_of(union(constant(:a), constant(:b), constant(:y)), union(constant(1), constant(2))))
      end

      # A splat may expand to no argument (the block form) or to one mapping: `Dynamic[top]` covers both.
      it "adds a Dynamic[top] key arm for an unknown argument count with a block" do
        ["h.transform_keys(*xs) { |k| k.to_s }", "h.transform_keys(**o) { |k| k.to_s }"].each do |source|
          result = dispatch(receiver: pair_shape, args: [], block_type: nominal("String"), call_node: call_node(source))
          expect(result).to eq(hash_of(union(nominal("String"), untyped), union(constant(1), constant(2)))),
                            "for #{source}"
        end
      end

      it "adds a Dynamic[top] arm for an open mapping's unlisted entries" do
        mapping = shape({ a: constant(:z) }, extra_keys: :open)
        expect(dispatch(receiver: pair_shape, args: [mapping], block_type: nominal("String")))
          .to eq(hash_of(union(nominal("String"), constant(:z), untyped), union(constant(1), constant(2))))
      end

      it "adds a Dynamic[top] arm to an open receiver's keys and values" do
        receiver = shape({ a: constant(1) }, extra_keys: :open)
        expect(dispatch(receiver: receiver, args: [rename_a]))
          .to eq(hash_of(union(constant(:a), untyped, constant(:z)), union(constant(1), untyped)))
      end

      it "adds a Dynamic[top] key arm for a block the block pass left untyped" do
        node = call_node("h.transform_keys(m, &blk)")
        expect(dispatch(receiver: pair_shape, args: [rename_a], call_node: node))
          .to eq(hash_of(union(untyped, constant(:z)), union(constant(1), constant(2))))
      end

      it "reads a raw Hash receiver's keys and values as unknown" do
        expect(dispatch(receiver: nominal("Hash"), args: [rename_a]))
          .to eq(hash_of(union(untyped, constant(:z)), untyped))
      end
    end

    describe "declines" do
      it "for any method but transform_keys" do
        %i[transform_keys! transform_values merge].each do |name|
          expect(dispatch(receiver: pair_shape, args: [rename_a], method_name: name)).to be_nil
        end
      end

      it "without exactly one positional argument" do
        expect(dispatch(receiver: pair_shape, args: [], block_type: nominal("String"))).to be_nil
        expect(dispatch(receiver: pair_shape, args: [rename_a, rename_a])).to be_nil
      end

      # With no block, an argument list that may pass nothing may be the `Enumerator` form.
      it "for an unknown argument count with no block, but not for a plain one" do
        forwarded = call_node("def f(...) = h.transform_keys(...)").body.body.first
        anonymous = call_node("def f(**) = h.transform_keys(**)").body.body.first
        [call_node("h.transform_keys(*m)"), call_node("h.transform_keys(**o)"), forwarded, anonymous].each do |node|
          expect(dispatch(receiver: pair_shape, args: [rename_a], call_node: node)).to be_nil, "for #{node.slice}"
        end
        expect(dispatch(receiver: pair_shape, args: [rename_a], call_node: call_node("h.transform_keys(m)")))
          .not_to be_nil
      end

      it "for a receiver that is not a Hash carrier" do
        [nominal("ActiveSupport::HashWithIndifferentAccess"), nominal("Array"), untyped,
         Rigor::Type::Combinator.dynamic(hash_of(nominal("Symbol"), nominal("Integer"))),
         Rigor::Type::Combinator.tuple_of(constant(1))].each do |receiver|
          expect(dispatch(receiver: receiver, args: [rename_a])).to be_nil, "for #{receiver.describe}"
        end
      end

      it "for an empty closed shape, whose answer is `{}` whatever the mapping says" do
        expect(dispatch(receiver: shape({}), args: [rename_a])).to be_nil
        expect(dispatch(receiver: shape({}, extra_keys: :open), args: [rename_a])).not_to be_nil
      end

      it "for a union with a member that is not a Hash carrier" do
        expect(dispatch(receiver: union(pair_shape, constant(nil)), args: [rename_a])).to be_nil
      end
    end
  end

  describe ".block_param_types" do
    def block_params(receiver:, args:)
      described_class.block_param_types(cc(receiver: receiver, method_name: :transform_keys, args: args))
    end

    it "binds the mapping form's block parameter to the receiver's keys" do
      expect(block_params(receiver: pair_shape, args: [rename_a])).to eq([union(constant(:a), constant(:b))])
      expect(block_params(receiver: union(pair_shape, hash_of(nominal("String"), nominal("Float"))), args: [rename_a]))
        .to eq([union(constant(:a), constant(:b), nominal("String"))])
    end

    it "leaves the block-only form and a non-Hash receiver to the RBS probe" do
      expect(block_params(receiver: pair_shape, args: [])).to be_nil
      expect(block_params(receiver: nominal("Array"), args: [rename_a])).to be_nil
    end

    it "answers through MethodDispatcher.expected_block_param_types, ahead of the RBS probe" do
      result = Rigor::Inference::MethodDispatcher.expected_block_param_types(
        receiver_type: pair_shape, method_name: :transform_keys, arg_types: [rename_a]
      )
      expect(result).to eq([union(constant(:a), constant(:b))])
    end
  end
end
