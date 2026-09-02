# frozen_string_literal: true

require "rbs"

RSpec.describe Rigor::Inference::MethodDispatcher::ReceiverAffinity do
  let(:env) { instance_double(Rigor::Environment) }
  let(:nominal_string) { Rigor::Type::Combinator.nominal_of("String") }
  let(:nominal_integer) { Rigor::Type::Combinator.nominal_of("Integer") }

  def stub_method_type(param_class: "::String")
    param_type = RBS::Types::ClassInstance.new(
      name: RBS::TypeName.parse(param_class), args: [], location: nil
    )
    param = instance_double(RBS::Types::Function::Param, type: param_type, name: :x)
    func = instance_double(RBS::Types::Function)
    allow(func).to receive_messages(required_positionals: [param], optional_positionals: [], trailing_positionals: [])
    allow(func).to receive(:respond_to?).with(:required_positionals).and_return(true)
    # RBS::Types::MethodType is not loaded in the spec context
    # rubocop:disable-next RSpec/VerifiedDoubles
    double("MethodType", type: func)
  end

  describe ".reorder" do
    it "returns overloads unchanged when environment is nil" do
      overloads = %i[a b]
      expect(described_class.reorder(overloads, self_type: nominal_string, environment: nil)).to eq(%i[a b])
    end

    it "returns overloads unchanged for non-nominal self_type" do
      overloads = [:a]
      untyped = Rigor::Type::Combinator.untyped
      expect(described_class.reorder(overloads, self_type: untyped, environment: env)).to eq([:a])
    end

    it "promotes affinity-matching overloads before disjoint ones" do
      allow(env).to receive(:class_ordering).with("Integer", "Integer").and_return(:same)
      allow(env).to receive(:class_ordering).with("Integer", "BigDecimal").and_return(:disjoint)

      int_overload = stub_method_type(param_class: "::Integer")
      bd_overload  = stub_method_type(param_class: "::BigDecimal")

      result = described_class.reorder(
        [bd_overload, int_overload],
        self_type: nominal_integer,
        environment: env
      )
      expect(result).to eq([int_overload, bd_overload])
    end

    it "preserves order within each partition (stable sort)" do
      allow(env).to receive(:class_ordering).with("Integer", "Integer").and_return(:same)

      a = stub_method_type(param_class: "::Integer")
      b = stub_method_type(param_class: "::Integer")

      result = described_class.reorder(
        [a, b],
        self_type: nominal_integer,
        environment: env
      )
      expect(result).to eq([a, b])
    end
  end

  describe "private helpers" do
    describe "class_in_ancestry?" do
      it "returns true when class names match" do
        expect(described_class.send(:class_in_ancestry?, "String", "String", env)).to be(true)
      end

      it "returns true when self_class is a subclass of param_class" do
        allow(env).to receive(:class_ordering).with("Integer", "Numeric").and_return(:subclass)
        expect(described_class.send(:class_in_ancestry?, "Numeric", "Integer", env)).to be(true)
      end

      it "returns false for unrelated classes" do
        allow(env).to receive(:class_ordering).with("String", "Integer").and_return(:disjoint)
        expect(described_class.send(:class_in_ancestry?, "Integer", "String", env)).to be(false)
      end
    end

    describe "self_type_class_name" do
      it "extracts the class name from a Nominal" do
        expect(described_class.send(:self_type_class_name, nominal_string)).to eq("String")
      end

      it "extracts the class name from a Singleton" do
        singleton = Rigor::Type::Combinator.singleton_of("String")
        expect(described_class.send(:self_type_class_name, singleton)).to eq("String")
      end

      it "returns nil for a non-Nominal/Singleton type" do
        expect(described_class.send(:self_type_class_name, Rigor::Type::Combinator.untyped)).to be_nil
      end
    end
  end
end
