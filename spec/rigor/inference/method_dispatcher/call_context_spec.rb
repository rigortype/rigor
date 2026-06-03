# frozen_string_literal: true

require "rigor/inference/method_dispatcher/call_context"

RSpec.describe Rigor::Inference::MethodDispatcher::CallContext do
  describe ".build" do
    it "defaults the optional context fields when given only the call quartet" do
      ctx = described_class.build(receiver: :recv, method_name: :size, args: [])

      expect(ctx).to have_attributes(
        receiver: :recv,
        method_name: :size,
        args: [],
        block_type: nil,
        environment: nil,
        call_node: nil,
        scope: nil,
        self_type_override: nil,
        public_only: false
      )
    end

    it "carries the wider context fields when supplied" do
      ctx = described_class.build(
        receiver: :recv, method_name: :select, args: [:a],
        block_type: :blk, environment: :env, call_node: :node,
        scope: :scope, self_type_override: :so, public_only: true
      )

      expect(ctx).to have_attributes(
        block_type: :blk, environment: :env, call_node: :node,
        scope: :scope, self_type_override: :so, public_only: true
      )
    end
  end

  describe "#with" do
    it "copies the base context with only the named fields changed" do
      base = described_class.build(receiver: :recv, method_name: :m, args: [], environment: :env)
      derived = base.with(receiver: :other, public_only: true)

      expect(derived).to have_attributes(
        receiver: :other, public_only: true,
        method_name: :m, args: [], environment: :env
      )
      # The base is immutable — `with` returns a fresh value.
      expect(base.receiver).to eq(:recv)
      expect(base.public_only).to be(false)
    end
  end

  it "is frozen / immutable (Data value semantics)" do
    ctx = described_class.build(receiver: :recv, method_name: :m, args: [])

    expect(ctx).to be_frozen
    expect(ctx).to eq(described_class.build(receiver: :recv, method_name: :m, args: []))
  end
end
