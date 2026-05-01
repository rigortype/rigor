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

    describe "singleton (class-method) dispatch (Slice 4 phase 2b)" do
      it "resolves Singleton[Integer].sqrt as Nominal[Integer]" do
        type = dispatch(Rigor::Type::Combinator.singleton_of(Integer), :sqrt)
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Integer")
      end

      it "resolves Singleton[Foo].new via Class#new for any registered class" do
        type = dispatch(Rigor::Type::Combinator.singleton_of(Integer), :new)
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Integer")
      end

      it "resolves Singleton[Foo].name via Module#name as Nominal[String]" do
        type = dispatch(Rigor::Type::Combinator.singleton_of(Integer), :name)
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("String")
      end

      it "does NOT confuse instance and singleton namespaces" do
        # Module#instance_methods is a singleton-side method on every class
        # type (Foo.instance_methods works), but is NOT itself an instance
        # method of Integer. Phase 2b must keep these distinct: dispatching
        # :instance_methods on Nominal[Integer] returns nil.
        instance_recv = Rigor::Type::Combinator.nominal_of(Integer)
        expect(dispatch(instance_recv, :instance_methods)).to be_nil

        singleton_recv = Rigor::Type::Combinator.singleton_of(Integer)
        type = dispatch(singleton_recv, :instance_methods)
        expect(type).not_to be_nil
      end

      it "returns nil for Singleton[Foo] when Foo is unknown to RBS" do
        unknown = Rigor::Type::Combinator.singleton_of("ThisClassDoesNotExist123")
        expect(dispatch(unknown, :new)).to be_nil
      end

      it "returns nil for an unknown class method on a known class" do
        recv = Rigor::Type::Combinator.singleton_of(Integer)
        expect(dispatch(recv, :totally_does_not_exist)).to be_nil
      end
    end

    describe "generics instantiation (Slice 4 phase 2d)" do
      it "substitutes Elem from Array[Integer] receiver into Array#first" do
        recv = Rigor::Type::Combinator.nominal_of(
          Array,
          type_args: [Rigor::Type::Combinator.nominal_of(Integer)]
        )
        type = dispatch(recv, :first)
        expect(type).to eq(Rigor::Type::Combinator.nominal_of(Integer))
      end

      it "carries Elem through to a generic return type (Array#first(n) -> Array[Elem])" do
        recv = Rigor::Type::Combinator.nominal_of(
          Array,
          type_args: [Rigor::Type::Combinator.nominal_of(Integer)]
        )
        type = dispatch(recv, :first, [Rigor::Type::Combinator.constant_of(2)])
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Array")
        expect(type.type_args).to eq([Rigor::Type::Combinator.nominal_of(Integer)])
      end

      it "leaves unbound variables as Dynamic[Top] for raw receivers" do
        # Raw `Nominal[Array]` carries no type_args, so Array#first on
        # the raw form falls back to the original phase-2c behavior.
        type = dispatch(Rigor::Type::Combinator.nominal_of(Array), :first)
        expect(type).to equal(Rigor::Type::Combinator.untyped)
      end

      it "substitutes both type_vars in Hash[K, V]#fetch (returns V)" do
        recv = Rigor::Type::Combinator.nominal_of(
          Hash,
          type_args: [
            Rigor::Type::Combinator.nominal_of(Symbol),
            Rigor::Type::Combinator.nominal_of(Integer)
          ]
        )
        type = dispatch(recv, :fetch, [Rigor::Type::Combinator.constant_of(:k)])
        # `Hash[K, V]#fetch(K) -> V` -> Nominal[Integer]
        expect(type).to eq(Rigor::Type::Combinator.nominal_of(Integer))
      end

      it "leaves type_vars empty when receiver type_args arity disagrees with class params" do
        # Constructed bogusly: Array declares 1 type param but receiver carries 2.
        recv = Rigor::Type::Combinator.nominal_of(
          Array,
          type_args: [
            Rigor::Type::Combinator.nominal_of(Integer),
            Rigor::Type::Combinator.nominal_of(String)
          ]
        )
        type = dispatch(recv, :first)
        expect(type).to equal(Rigor::Type::Combinator.untyped)
      end
    end

    describe "shape carriers (Slice 5 phase 1)" do
      it "projects Tuple[A, B] receiver to Array[union] for dispatch" do
        tup = Rigor::Type::Combinator.tuple_of(
          Rigor::Type::Combinator.constant_of(1),
          Rigor::Type::Combinator.constant_of(2)
        )
        type = dispatch(tup, :first)
        expect(type).to be_a(Rigor::Type::Union)
        expect(type.members.map(&:value)).to contain_exactly(1, 2)
      end

      it "projects empty Tuple to raw Array (no element evidence)" do
        tup = Rigor::Type::Combinator.tuple_of
        type = dispatch(tup, :length)
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Integer")
      end

      it "projects HashShape{a: Int} receiver onto Hash[Symbol, Int] for #fetch" do
        sh = Rigor::Type::Combinator.hash_shape_of(
          a: Rigor::Type::Combinator.constant_of(1),
          b: Rigor::Type::Combinator.constant_of(2)
        )
        type = dispatch(sh, :fetch, [Rigor::Type::Combinator.constant_of(:a)])
        expect(type).to be_a(Rigor::Type::Union)
        expect(type.members.map(&:value)).to contain_exactly(1, 2)
      end
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
