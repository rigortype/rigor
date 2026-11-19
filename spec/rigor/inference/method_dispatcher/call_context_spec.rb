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

  describe ".new" do
    it "takes the nine fields positionally, in the order of the field list" do
      ctx = described_class.new(:recv, :m, [:a], :blk, :env, :node, :scope, :so, true)

      expect(ctx).to have_attributes(
        receiver: :recv, method_name: :m, args: [:a],
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

    it "can replace each of the nine fields, and the copy is frozen" do
      base = described_class.build(receiver: :recv, method_name: :m, args: [])
      changes = {
        receiver: :r2, method_name: :m2, args: [:a2],
        block_type: :blk2, environment: :env2, call_node: :node2,
        scope: :scope2, self_type_override: :so2, public_only: true
      }

      expect(base.with(**changes)).to have_attributes(**changes).and be_frozen
    end

    it "rejects a keyword that names no field" do
      base = described_class.build(receiver: :recv, method_name: :m, args: [])

      expect { base.with(reciever: :typo) }.to raise_error(ArgumentError, /reciever/)
    end
  end

  it "is frozen / immutable, and compares by value" do
    ctx = described_class.build(receiver: :recv, method_name: :m, args: [])

    expect(ctx).to be_frozen
    expect(ctx).to eq(described_class.build(receiver: :recv, method_name: :m, args: []))
  end

  describe "value equality" do
    let(:fields) { [:recv, :m, [:a], :blk, :env, :node, :scope, :so, true] }

    it "tells apart two contexts that differ in any one field" do
      base = described_class.new(*fields)

      fields.each_index do |index|
        other = described_class.new(*fields.dup.tap { |copy| copy[index] = :different })

        expect(base).not_to eq(other), "field #{index} was not compared"
      end
    end

    it "is not equal to something that is not a context" do
      expect(described_class.new(*fields)).not_to eq(fields)
    end

    it "finds an equal context as a Hash key" do
      table = { described_class.new(*fields) => :found }

      expect(table[described_class.new(*fields)]).to eq(:found)
    end
  end

  # What the class is for (ADR-116 WD12): as a `Data`, positional `new` built a keyword Hash first, so a build
  # allocated three objects and a `with` five.
  describe "allocations" do
    # The counter is the process's, so the least of three windows is the call's own cost even when another thread
    # allocates during one of them.
    def allocated
      Array.new(3) do
        # Reading the counter may itself allocate; an empty window measures that floor.
        before = GC.stat(:total_allocated_objects)
        floor = GC.stat(:total_allocated_objects) - before
        before = GC.stat(:total_allocated_objects)
        yield
        GC.stat(:total_allocated_objects) - before - floor
      end.min
    end

    it "allocates only the context in `build`" do
      klass = described_class
      args = []
      build = -> { klass.build(receiver: :recv, method_name: :m, args: args, environment: :env, scope: :scope) }
      build.call

      expect(allocated(&build)).to eq(1)
    end

    it "allocates the keyword Hash and the copy in `with`" do
      base = described_class.build(receiver: :recv, method_name: :m, args: [])
      with = -> { base.with(receiver: :other, public_only: true) }
      with.call

      expect(allocated(&with)).to eq(2)
    end
  end
end
