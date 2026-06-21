# frozen_string_literal: true

RSpec.describe Rigor::Inference::MethodDispatcher::MemberShapeProjection do
  let!(:projector) do
    mod = described_class
    Module.new { extend mod }
  end
  let(:one) { Rigor::Type::Combinator.constant_of(1) }
  let(:two) { Rigor::Type::Combinator.constant_of("two") }
  let(:members) { { x: one, y: two } }
  let(:instance) do
    instance_double(Rigor::Type::DataInstance, members: members, class_name: "Point",
                                               member_names: %i[x y])
  end

  describe "#reader_overridden?" do
    it "returns false when class_name is nil" do
      anon = instance_double(Rigor::Type::DataInstance, class_name: nil)
      expect(projector.reader_overridden?(anon, :x, nil)).to be(false)
    end

    it "returns false when scope is nil" do
      expect(projector.reader_overridden?(instance, :x, nil)).to be(false)
    end

    it "returns false when scope has no user_def for the method" do
      scope = instance_double(Rigor::Scope, user_def_for: nil)
      expect(projector.reader_overridden?(instance, :x, scope)).to be(false)
    end

    it "returns true when scope has a user def for the method" do
      scope = instance_double(Rigor::Scope, user_def_for: instance_double(Prism::DefNode))
      expect(projector.reader_overridden?(instance, :x, scope)).to be(true)
    end
  end

  describe "#instance_index" do
    it "returns the member type for a Symbol key" do
      arg = Rigor::Type::Combinator.constant_of(:x)
      expect(projector.instance_index(instance, [arg])).to eq(one)
    end

    it "returns nil for a non-Constant arg" do
      arg = Rigor::Type::Combinator.nominal_of("Symbol")
      expect(projector.instance_index(instance, [arg])).to be_nil
    end

    it "returns nil for wrong arg count" do
      expect(projector.instance_index(instance, [])).to be_nil
    end

    it "returns the member type for a non-negative Integer key" do
      arg = Rigor::Type::Combinator.constant_of(0)
      expect(projector.instance_index(instance, [arg])).to eq(one)
    end

    it "returns the member type for a positive Integer key" do
      arg = Rigor::Type::Combinator.constant_of(1)
      expect(projector.instance_index(instance, [arg])).to eq(two)
    end

    it "returns nil for an out-of-bounds positive Integer key" do
      arg = Rigor::Type::Combinator.constant_of(99)
      expect(projector.instance_index(instance, [arg])).to be_nil
    end

    it "handles negative Integer key relative from end" do
      arg = Rigor::Type::Combinator.constant_of(-1)
      expect(projector.instance_index(instance, [arg])).to eq(two)
    end

    it "returns nil for out-of-bounds negative Integer key" do
      arg = Rigor::Type::Combinator.constant_of(-99)
      expect(projector.instance_index(instance, [arg])).to be_nil
    end
  end

  describe "#instance_to_h" do
    it "returns a HashShape with the member entries" do
      result = projector.instance_to_h(instance)
      expect(result).to be_a(Rigor::Type::HashShape)
    end
  end

  describe "#instance_deconstruct" do
    it "returns a Tuple of member values" do
      result = projector.instance_deconstruct(instance)
      expect(result).to be_a(Rigor::Type::Tuple)
    end
  end

  describe "#instance_deconstruct_keys" do
    it "returns nil when args count > 1" do
      expect(projector.instance_deconstruct_keys(instance, [1, 2])).to be_nil
    end

    it "returns a HashShape for valid args" do
      result = projector.instance_deconstruct_keys(instance, [])
      expect(result).to be_a(Rigor::Type::HashShape)
    end
  end

  describe "#instance_members" do
    it "returns a Tuple of constant member names" do
      result = projector.instance_members(instance)
      expect(result).to be_a(Rigor::Type::Tuple)
    end
  end

  describe "#instance_with" do
    it "returns instance when args are empty" do
      expect(projector.instance_with(instance, [])).to be(instance)
    end

    it "returns nil for non-HashShape arg" do
      arg = Rigor::Type::Combinator.nominal_of("String")
      expect(projector.instance_with(instance, [arg])).to be_nil
    end

    it "yields merged members and class_name for a valid closed HashShape" do
      shape = Rigor::Type::HashShape.new(x: one)
      merged = nil
      class_name = nil
      projector.instance_with(instance, [shape]) do |m, c|
        merged = m
        class_name = c
      end
      expect(merged).to eq(members.merge(x: one))
      expect(class_name).to eq("Point")
    end

    it "returns nil when HashShape has optional keys" do
      shape = Rigor::Type::HashShape.new({ y: two }, optional_keys: [:y])
      expect(projector.instance_with(instance, [shape])).to be_nil
    end

    it "returns nil when HashShape has keys not in members" do
      shape = Rigor::Type::HashShape.new(z: one)
      expect(projector.instance_with(instance, [shape])).to be_nil
    end
  end
end
