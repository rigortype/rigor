# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::RbsDispatch do
  let(:environment) { Rigor::Environment.default }

  def dispatch(receiver, method_name, args = [])
    described_class.try_dispatch(
      receiver: receiver,
      method_name: method_name,
      args: args,
      environment: environment
    )
  end

  describe ".try_dispatch" do
    it "resolves Constant<Integer>#succ to Nominal[Integer]" do
      type = dispatch(Rigor::Type::Combinator.constant_of(1), :succ)
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "resolves Nominal[Array]#length to Nominal[Integer]" do
      type = dispatch(Rigor::Type::Combinator.nominal_of(Array), :length)
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "resolves boolean predicates as Union[true, false]" do
      type = dispatch(Rigor::Type::Combinator.constant_of(1), :zero?)
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:value)).to contain_exactly(true, false)
    end

    it "unwraps Dynamic[T] receivers and dispatches on the static facet" do
      dyn_int = Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.nominal_of(Integer))
      type = dispatch(dyn_int, :succ)
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "unions return types when receiver is a Union of known classes" do
      union = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of(Integer),
        Rigor::Type::Combinator.nominal_of(String)
      )
      type = dispatch(union, :to_s)
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("String")
    end

    it "returns nil when one Union member misses the method" do
      union = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of(Integer),
        Rigor::Type::Combinator.nominal_of(String)
      )
      expect(dispatch(union, :bit_length)).to be_nil
    end

    it "returns nil for unknown methods" do
      expect(dispatch(Rigor::Type::Combinator.constant_of(1), :totally_does_not_exist)).to be_nil
    end

    it "returns nil for unknown classes" do
      unknown = Rigor::Type::Combinator.nominal_of("ThisClassDoesNotExist123")
      expect(dispatch(unknown, :succ)).to be_nil
    end

    it "returns nil for Top and Bot receivers" do
      expect(dispatch(Rigor::Type::Combinator.top, :succ)).to be_nil
      expect(dispatch(Rigor::Type::Combinator.bot, :succ)).to be_nil
    end

    it "returns nil when the environment has no RBS loader" do
      blank_env = Rigor::Environment.new
      expect(blank_env.rbs_loader).to be_nil

      result = described_class.try_dispatch(
        receiver: Rigor::Type::Combinator.constant_of(1),
        method_name: :succ,
        args: [],
        environment: blank_env
      )
      expect(result).to be_nil
    end
  end
end
