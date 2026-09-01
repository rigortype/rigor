# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::RbsDispatch do
  let(:environment) { Rigor::Environment.default }

  def dispatch(receiver, method_name, args = [])
    described_class.try_dispatch(cc(
                                   receiver: receiver,
                                   method_name: method_name,
                                   args: args,
                                   environment: environment
                                 ))
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
        # Module#instance_methods is a singleton-side method on every class type (Foo.instance_methods works), but is
        # NOT itself an instance method of Integer. Phase 2b must keep these distinct: dispatching :instance_methods on
        # Nominal[Integer] returns nil.
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
        # Raw `Nominal[Array]` carries no type_args, so Array#first on the raw form falls back to the original phase-2c
        # behavior.
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

    # Issue #303 — method-level `[T]` bound from an argument position. The signatures live in a virtual
    # RBS buffer so the shapes under test are stated here rather than borrowed from whatever core RBS
    # happens to spell today.
    describe "method-level type parameters bound from argument positions (issue #303)" do
      let(:generic_rbs) do
        <<~RBS
          class RigorSpecBox
            def self.wrap: [T] (T obj) -> T
            def self.pair: [T] (T obj) -> ::Array[T]
            def self.both: [T] (T a, T b) -> T
            def self.boxed: [T] (::Array[T] objs) -> T
          end

          class RigorSpecCrate[T]
            def relabel: [T] (T obj) -> T
          end
        RBS
      end
      let(:generic_environment) do
        Rigor::Environment.new(
          rbs_loader: Rigor::Environment::RbsLoader.new(virtual_rbs: [["(spec: issue #303)", generic_rbs]])
        )
      end
      let(:call_node) { Prism.parse("RigorSpecBox.wrap(obj)").value.statements.body.first }
      let(:box) { Rigor::Type::Combinator.singleton_of("RigorSpecBox") }

      # The permitting call site: a live scope and call node, with nothing discovered that shadows the
      # resolved method.
      def bind(receiver, method_name, args, scope: Rigor::Scope.empty(environment: generic_environment))
        described_class.try_dispatch(cc(
                                       receiver: receiver,
                                       method_name: method_name,
                                       args: args,
                                       environment: generic_environment,
                                       scope: scope,
                                       call_node: call_node
                                     ))
      end

      it "binds `[T] (T) -> T` to the argument type" do
        type = bind(box, :wrap, [Rigor::Type::Combinator.constant_of("x")])
        expect(type).to eq(Rigor::Type::Combinator.constant_of("x"))
      end

      it "carries the binding into a generic return type (`-> Array[T]`)" do
        type = bind(box, :pair, [Rigor::Type::Combinator.constant_of("x")])
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Array")
        expect(type.type_args).to eq([Rigor::Type::Combinator.constant_of("x")])
      end

      it "unions the arguments when one variable occupies several positions" do
        type = bind(box, :both, [Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of("x")])
        expect(type).to be_a(Rigor::Type::Union)
        expect(type.members.map(&:value)).to contain_exactly(1, "x")
      end

      it "leaves the variable unbound for a `Dynamic[top]` argument (no evidence)" do
        type = bind(box, :wrap, [Rigor::Type::Combinator.untyped])
        expect(type).to equal(Rigor::Type::Combinator.untyped)
      end

      it "does not walk into a container position (`Array[T] arg` stays unbound)" do
        arg = Rigor::Type::Combinator.nominal_of(Array, type_args: [Rigor::Type::Combinator.constant_of("x")])
        expect(bind(box, :boxed, [arg])).to equal(Rigor::Type::Combinator.untyped)
      end

      it "lets a class-level type variable of the same name win over the argument binding" do
        # `RigorSpecCrate[T]#relabel: [T] (T) -> T` — the receiver already binds `T` to Integer, so the
        # String argument must NOT displace it.
        crate = Rigor::Type::Combinator.nominal_of(
          "RigorSpecCrate", type_args: [Rigor::Type::Combinator.nominal_of(Integer)]
        )
        type = bind(crate, :relabel, [Rigor::Type::Combinator.constant_of("x")])
        expect(type).to eq(Rigor::Type::Combinator.nominal_of(Integer))
      end

      it "declines with no scope threaded (the ancestor-fallback dispatch path)" do
        type = described_class.try_dispatch(cc(
                                              receiver: box,
                                              method_name: :wrap,
                                              args: [Rigor::Type::Combinator.constant_of("x")],
                                              environment: generic_environment
                                            ))
        expect(type).to equal(Rigor::Type::Combinator.untyped)
      end

      # The FP mechanism the guard exists for: a user method shadowing the RBS one turns a bound `T` into a
      # confidently WRONG type. Both declines are paired with the must-still-bind control above them, since a
      # decline assertion on its own passes for any reason at all.
      describe "the user-redefinition guard" do
        let(:permitting_scope) { Rigor::Scope.empty(environment: generic_environment) }

        it "binds when nothing shadows the resolved method (control)" do
          type = bind(box, :wrap, [Rigor::Type::Combinator.constant_of("x")], scope: permitting_scope)
          expect(type).to eq(Rigor::Type::Combinator.constant_of("x"))
        end

        it "declines when the scope discovered a method of the same name on the resolved class" do
          shadowed = permitting_scope.with_discovery(
            Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_methods: { "RigorSpecBox" => { wrap: :singleton } })
          )
          type = bind(box, :wrap, [Rigor::Type::Combinator.constant_of("x")], scope: shadowed)
          expect(type).to equal(Rigor::Type::Combinator.untyped)
        end

        it "declines when the scope discovered a top-level def of the same name" do
          def_node = Prism.parse("def wrap(obj) = obj.to_s").value.statements.body.first
          shadowed = permitting_scope.with_discovery(
            Rigor::Scope::DiscoveryIndex::EMPTY.with(
              discovered_def_nodes: {
                Rigor::Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY => { wrap: def_node }
              }
            )
          )
          type = bind(box, :wrap, [Rigor::Type::Combinator.constant_of("x")], scope: shadowed)
          expect(type).to equal(Rigor::Type::Combinator.untyped)
        end
      end
    end

    # Issue #529 — a signature whose return names a type alias (or an intersection through one) used to
    # collapse to `untyped` at the translation boundary. The dispatch tier passes its loader as the
    # translator's alias expander, so the aliased return resolves like the spelled-out type would.
    describe "aliased return types (issue #529)" do
      let(:aliased_rbs) do
        <<~RBS
          interface _RigorSpecMarker
          end

          class RigorSpecLeaf
          end

          type rigor_spec_leaf = RigorSpecLeaf & _RigorSpecMarker

          class RigorSpecTree
            def leaf: () -> rigor_spec_leaf
            def leaf_or_nil: () -> rigor_spec_leaf?
          end
        RBS
      end
      let(:aliased_environment) do
        Rigor::Environment.new(
          rbs_loader: Rigor::Environment::RbsLoader.new(virtual_rbs: [["(spec: issue #529)", aliased_rbs]])
        )
      end
      let(:tree) { Rigor::Type::Combinator.nominal_of("RigorSpecTree") }

      def dispatch_on_tree(method_name)
        described_class.try_dispatch(cc(
                                       receiver: tree,
                                       method_name: method_name,
                                       args: [],
                                       environment: aliased_environment
                                     ))
      end

      it "resolves an alias-of-intersection return to the nominal member" do
        type = dispatch_on_tree(:leaf)
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("RigorSpecLeaf")
      end

      it "keeps the optional wrapper around a resolved alias" do
        type = dispatch_on_tree(:leaf_or_nil)
        expect(type.describe(:short)).to eq("RigorSpecLeaf?")
      end
    end

    it "returns nil when the environment has no RBS loader" do
      blank_env = Rigor::Environment.new
      expect(blank_env.rbs_loader).to be_nil

      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.constant_of(1),
                                              method_name: :succ,
                                              args: [],
                                              environment: blank_env
                                            ))
      expect(result).to be_nil
    end
  end
end
