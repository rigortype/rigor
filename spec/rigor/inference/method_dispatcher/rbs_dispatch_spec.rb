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

    # Issue #1092 — `Array#tap` is `-> self`; the substitute keeps the receiver's `Dynamic` wrapping and its
    # type arguments rather than baking in the erased raw nominal.
    it "keeps a Dynamic receiver's wrapping and type arguments on a `-> self` return" do
      ints = Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of(Integer)])
      type = dispatch(Rigor::Type::Combinator.dynamic(ints), :itself)
      expect(type).to be_a(Rigor::Type::Dynamic)
      expect(type.static_facet).to eq(ints)
    end

    it "answers the raw nominal on a `-> self` return when every type argument is untyped" do
      untyped = Rigor::Type::Combinator.untyped
      hash = Rigor::Type::Combinator.nominal_of("Hash", type_args: [untyped, untyped])
      expect(dispatch(hash, :itself)).to eq(Rigor::Type::Combinator.nominal_of("Hash"))
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

      # Issue #1121 — FEWER arguments than the class declares is the partial application RBS licenses for a
      # defaulted trailing parameter, not an arity disagreement. `Enumerable#lazy:
      # () -> Enumerator::Lazy[Elem]` hands back exactly such a receiver (the class is
      # `Enumerator::Lazy[out E, out R = void]`), and withholding the whole map left `Elem` unbound so every
      # method reached through it degraded to `Dynamic[top]`.
      def partial_lazy_receiver
        Rigor::Type::Combinator.nominal_of(
          "Enumerator::Lazy",
          type_args: [Rigor::Type::Combinator.nominal_of(Integer)]
        )
      end

      it "binds the supplied prefix of a partial application of a defaulted generic" do
        # `Enumerable#to_a: () -> Array[Elem]`
        expect(dispatch(partial_lazy_receiver, :to_a)).to eq(
          Rigor::Type::Combinator.nominal_of(
            "Array",
            type_args: [Rigor::Type::Combinator.nominal_of(Integer)]
          )
        )
      end

      it "leaves the omitted trailing parameter unbound on a partial application" do
        # `Enumerator::Lazy#eager: () -> Enumerator[E, R]` -- `R` is the parameter the receiver did not
        # supply, so it degrades to `Dynamic[top]` like any other free variable.
        expect(dispatch(partial_lazy_receiver, :eager).describe(:short))
          .to eq("Enumerator[Integer, Dynamic[top]]")
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

    # Issue #842 — an IntegerRange receiver used to have no arm in `receiver_descriptor`, so anything
    # the fold tiers did not own fell soft to Dynamic[top] instead of reaching RBS.
    describe "IntegerRange receiver (issue #842)" do
      let(:non_negative_int) { Rigor::Type::Combinator.non_negative_int }

      it "resolves #digits to Array[Integer]" do
        type = dispatch(non_negative_int, :digits)
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Array")
        expect(type.type_args).to eq([Rigor::Type::Combinator.nominal_of(Integer)])
      end

      it "resolves #fdiv(2) to Float" do
        type = dispatch(non_negative_int, :fdiv, [Rigor::Type::Combinator.constant_of(2)])
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Float")
      end

      it "resolves #to_f to Float" do
        type = dispatch(non_negative_int, :to_f)
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Float")
      end

      it "still declines an undefined method" do
        expect(dispatch(non_negative_int, :frobnicate)).to be_nil
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
            def self.bracket: [A] (::Range[A] range) -> A
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

      # Issue #834 — the one container position the envelope admits. `Comparable#clamp: [A] (Range[A]) ->
      # (self | A)` left `A` unbound, so `Integer(ARGV[0]).clamp(1..9)` answered `Dynamic[top] | Integer`.
      describe "a `Range[A]` parameter against a Constant<Range> argument" do
        it "binds A to the endpoints' class, not to the endpoint values" do
          # Lifted, because `1..9` yields Integers rather than the two values 1 and 9; a `1 | 9` binding
          # would be contradicted by every receiver already inside the bracket.
          type = bind(box, :bracket, [Rigor::Type::Combinator.constant_of(1..9)])
          expect(type).to eq(Rigor::Type::Combinator.nominal_of(Integer))
        end

        it "binds from the present endpoint of an endless range" do
          type = bind(box, :bracket, [Rigor::Type::Combinator.constant_of(Range.new(1, nil))])
          expect(type).to eq(Rigor::Type::Combinator.nominal_of(Integer))
        end

        it "unions the endpoints of a mixed-endpoint range" do
          type = bind(box, :bracket, [Rigor::Type::Combinator.constant_of(1.0..2)])
          expect(type).to be_a(Rigor::Type::Union)
          expect(type.members.map(&:class_name)).to contain_exactly("Float", "Integer")
        end

        it "binds A from a Nominal[Range, [T]] carrier's own type arg" do
          # Issue #862 — `1..ARGV.size` has no literal endpoint, so `ExpressionTyper` hands back the
          # nominal carrier. Its `T` is the element the Range was constructed with, and a Range is
          # immutable, so the carrier says as much as a literal's endpoints do.
          arg = Rigor::Type::Combinator.nominal_of("Range", type_args: [Rigor::Type::Combinator.nominal_of(Integer)])
          expect(bind(box, :bracket, [arg])).to eq(Rigor::Type::Combinator.nominal_of(Integer))
        end

        it "binds A from a Nominal[Range, [T]] carrier whose T is a union of Nominals" do
          element = Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.nominal_of(Integer), Rigor::Type::Combinator.nominal_of(Float)
          )
          arg = Rigor::Type::Combinator.nominal_of("Range", type_args: [element])
          type = bind(box, :bracket, [arg])
          expect(type).to be_a(Rigor::Type::Union)
          expect(type.members.map(&:class_name)).to contain_exactly("Float", "Integer")
        end

        it "leaves A unbound for a Nominal[Range, [untyped]] carrier" do
          # An untyped element is an absence of evidence; binding it would dress `self | A` up as an
          # inference while it reads `self | unknown`.
          arg = Rigor::Type::Combinator.nominal_of("Range", type_args: [Rigor::Type::Combinator.untyped])
          expect(bind(box, :bracket, [arg])).to equal(Rigor::Type::Combinator.untyped)
        end

        it "leaves A unbound for a Dynamic argument" do
          expect(bind(box, :bracket, [Rigor::Type::Combinator.untyped])).to equal(Rigor::Type::Combinator.untyped)
        end

        it "leaves A unbound for a Nominal carrier that is not a Range" do
          arg = Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of(Integer)])
          expect(bind(box, :bracket, [arg])).to equal(Rigor::Type::Combinator.untyped)
        end

        it "leaves A unbound for a Constant that is not a Range" do
          expect(bind(box, :bracket, [Rigor::Type::Combinator.constant_of(1)]))
            .to equal(Rigor::Type::Combinator.untyped)
        end
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

    # A method-level variable that is both the block's return type and part of a parameter's type
    # (`Enumerable#inject: [A] (A initial) { (A, E) -> A } -> A`) depends on the argument as well as the
    # block. When the call passes an argument, the variable is not bound to the block's type: a
    # `Dynamic[block_type]` facet still dispatches exactly, and the block's type need not contain the
    # result. Where the variable is the whole type of the argument's parameter, the block receives nothing
    # it names, and both sides widen to one closed value class, it is bound to that class; every other
    # shape leaves it `Dynamic[top]`. Each untyped example is paired with a control that binds.
    describe "a block-return variable that a parameter also names" do
      let(:fold_rbs) do
        <<~RBS
          class RigorSpecFold
            def self.seeded: [A] (A initial) { () -> A } -> A
            def self.optional_seed: [U] (?U seed) { () -> U } -> U
            def self.accumulated: [A] (A initial) { (A acc) -> A } -> A
            def self.rebound: [A] (A initial) { () [self: A] -> A } -> A
            def self.paired_seed: [T] (T first, T second) { () -> T } -> T
            def self.late_seed: [T] (?::Integer count, ?T seed) { () -> T } -> T
            def self.rest_seed: [T] (*T seeds) { () -> T } -> T
            def self.trailing_seed: [T] (*::Integer counts, T last) { () -> T } -> T
            def self.keyword_seed: [T] (?seed: T) { () -> T } -> T
            def self.keyword_rest_seed: [T] (**T seeds) { () -> T } -> T
            def self.mapped: [K2] (::Hash[::Symbol, K2] mapping) { () -> K2 } -> ::Array[K2]
            def self.listed: [T] (::Array[T] seeds) { () -> T } -> T
            def self.counted: [U] (::Integer n) { () -> U } -> U
            def self.block_only: [U] () { () -> U } -> U
          end
        RBS
      end
      let(:fold_environment) do
        Rigor::Environment.new(
          rbs_loader: Rigor::Environment::RbsLoader.new(virtual_rbs: [["(spec: block-return variable)", fold_rbs]])
        )
      end
      let(:fold) { Rigor::Type::Combinator.singleton_of("RigorSpecFold") }
      let(:integer) { Rigor::Type::Combinator.nominal_of(Integer) }
      let(:untyped) { Rigor::Type::Combinator.untyped }
      let(:seed) { Rigor::Type::Combinator.constant_of(0) }
      let(:keywords) { Rigor::Type::Combinator.hash_shape_of({ seed: seed }) }

      def permitting_scope
        Rigor::Scope.empty(environment: fold_environment)
      end

      def call_node_of(source)
        Prism.parse(source).value.statements.body.first
      end

      # The call site the issue #303 argument binding accepts — a live scope and a call node passing plain
      # positional arguments — so a decline below comes from the shape under test, not from that gate.
      def fold_call(method_name, args, block_type: integer, scope: permitting_scope, call_node: nil)
        placeholders = Array.new(args.size) { |i| "a#{i}" }.join(", ")
        call_node ||= call_node_of("RigorSpecFold.#{method_name}(#{placeholders}) { 1 }")
        described_class.try_dispatch(cc(
                                       receiver: fold,
                                       method_name: method_name,
                                       args: args,
                                       environment: fold_environment,
                                       block_type: block_type,
                                       scope: scope,
                                       call_node: call_node
                                     ))
      end

      # Binding the argument alone (issue #303) would answer the literal `0`.
      it "binds the shared class when a required positional parameter is the variable" do
        expect(fold_call(:seeded, [seed])).to eq(integer)
      end

      it "binds the shared class when the call passes the optional parameter that is the variable" do
        expect(fold_call(:optional_seed, [seed])).to eq(integer)
      end

      it "binds exactly when the call omits the optional parameter that names it (control)" do
        expect(fold_call(:optional_seed, [])).to eq(integer)
      end

      # `sum(1) { -1 }` over three elements is `-2`, which neither `1` nor `-1` contains. A literal is not
      # closed under the arithmetic a combining method applies; its class is.
      it "widens a literal and a bounded integer to their class" do
        block_type = Rigor::Type::Combinator.negative_int
        expect(fold_call(:seeded, [Rigor::Type::Combinator.constant_of(1)], block_type: block_type)).to eq(integer)
      end

      # A plugin-built nominal may keep the absolute spelling.
      it "reads a class name spelled with a leading `::`" do
        expect(fold_call(:seeded, [seed], block_type: Rigor::Type::Combinator.nominal_of("::Integer"))).to eq(integer)
      end

      it "widens a bounded float to its class" do
        float = Rigor::Type::Combinator.nominal_of(Float)
        block_type = Rigor::Type::Combinator.non_nan_float
        expect(fold_call(:seeded, [Rigor::Type::Combinator.constant_of(0.0)], block_type: block_type)).to eq(float)
      end

      it "widens a difference to its base's class" do
        expect(fold_call(:seeded, [seed], block_type: Rigor::Type::Combinator.non_zero_int)).to eq(integer)
      end

      it "widens a refinement to its base's class" do
        string = Rigor::Type::Combinator.nominal_of(String)
        type = fold_call(:seeded, [Rigor::Type::Combinator.constant_of("")],
                         block_type: Rigor::Type::Combinator.lowercase_string)
        expect(type).to eq(string)
      end

      # `sum(0.0)` over Integers is a Float every time; `Float | Integer` would fire
      # `def.return-type-mismatch` against a declared `-> Float`.
      it "leaves the variable untyped when the two sides' classes differ" do
        expect(fold_call(:seeded, [Rigor::Type::Combinator.constant_of(0.0)])).to equal(untyped)
      end

      it "reads every argument the variable's parameters receive" do
        expect(fold_call(:paired_seed, [seed, Rigor::Type::Combinator.constant_of("x")])).to equal(untyped)
      end

      it "binds when every argument shares the block's class (control)" do
        expect(fold_call(:paired_seed, [seed, Rigor::Type::Combinator.constant_of(2)])).to eq(integer)
      end

      # The block's type is one typing of its body, taken with whatever its `acc` or `self` was typed as.
      it "leaves the variable untyped when the block's parameter names it" do
        expect(fold_call(:accumulated, [seed])).to equal(untyped)
      end

      it "leaves the variable untyped when the block's self names it" do
        expect(fold_call(:rebound, [seed])).to equal(untyped)
      end

      it "leaves the variable untyped when the argument is nil" do
        nil_type = Rigor::Type::Combinator.constant_of(nil)
        expect(fold_call(:seeded, [nil_type], block_type: nil_type)).to equal(untyped)
      end

      it "leaves the variable untyped for NilClass" do
        nil_class = Rigor::Type::Combinator.nominal_of("NilClass")
        expect(fold_call(:seeded, [nil_class], block_type: nil_class)).to equal(untyped)
      end

      # `class Name < String` inherits a `+` that answers a plain String.
      it "leaves the variable untyped for a class outside the closed value classes" do
        own = Rigor::Type::Combinator.nominal_of("RigorSpecFold")
        expect(fold_call(:seeded, [own], block_type: own)).to equal(untyped)
      end

      # Dropping the key instead would let the issue #303 argument binding pin `A` to the argument alone.
      it "leaves the variable untyped when the argument is generic" do
        array = Rigor::Type::Combinator.nominal_of("Array", type_args: [integer])
        expect(fold_call(:seeded, [array], block_type: array)).to equal(untyped)
      end

      it "leaves the variable untyped when the block's type is a tuple" do
        expect(fold_call(:seeded, [seed], block_type: Rigor::Type::Combinator.tuple_of(integer))).to equal(untyped)
      end

      it "leaves the variable untyped when the block's type is Dynamic" do
        expect(fold_call(:seeded, [seed], block_type: Rigor::Type::Combinator.dynamic(integer))).to equal(untyped)
      end

      # A splat that turns out empty moves the argument after it into `count`.
      it "leaves the variable untyped when a splat precedes the argument" do
        splat = call_node_of("RigorSpecFold.late_seed(*counts, a1) { 1 }")
        expect(fold_call(:late_seed, [untyped, seed], call_node: splat)).to equal(untyped)
      end

      it "binds when plain arguments fix the positions (control)" do
        expect(fold_call(:late_seed, [Rigor::Type::Combinator.constant_of(3), seed])).to eq(integer)
      end

      # Keyword arguments reach a method without keyword parameters as a trailing positional hash.
      it "leaves the variable untyped when the call passes keyword arguments" do
        type = fold_call(:optional_seed, [seed], call_node: call_node_of("RigorSpecFold.optional_seed(k: a0) { 1 }"))
        expect(type).to equal(untyped)
      end

      it "leaves the variable untyped when the call forwards `...`" do
        definition = call_node_of("def forward(...) = RigorSpecFold.optional_seed(...)")
        type = fold_call(:optional_seed, [seed], call_node: definition.body.body.first)
        expect(type).to equal(untyped)
      end

      it "leaves the variable untyped when the argument types do not line up with the call's arguments" do
        expect(fold_call(:seeded, [seed], call_node: call_node_of("RigorSpecFold.seeded { 1 }"))).to equal(untyped)
      end

      it "leaves the variable untyped at a call node that is not a method call" do
        definition = call_node_of("def seeded(a0) = super(a0) { 1 }")
        expect(fold_call(:seeded, [seed], call_node: definition.body.body.first)).to equal(untyped)
      end

      it "leaves the variable untyped without a call site the argument binding accepts" do
        expect(fold_call(:seeded, [seed], scope: nil)).to equal(untyped)
      end

      it "leaves the variable untyped when the scope discovered a method shadowing the resolved one" do
        shadowed = permitting_scope.with_discovery(
          Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_methods: { "RigorSpecFold" => { seeded: :singleton } })
        )
        expect(fold_call(:seeded, [seed], scope: shadowed)).to equal(untyped)
      end

      it "leaves the variable untyped when a rest parameter names it" do
        expect(fold_call(:rest_seed, [seed, seed])).to equal(untyped)
      end

      it "leaves the variable untyped when a trailing positional parameter names it" do
        expect(fold_call(:trailing_seed, [Rigor::Type::Combinator.constant_of(1), seed])).to equal(untyped)
      end

      it "leaves the variable untyped when a keyword parameter names it" do
        expect(fold_call(:keyword_seed, [keywords])).to equal(untyped)
      end

      it "leaves the variable untyped when a keyword rest parameter names it" do
        expect(fold_call(:keyword_rest_seed, [keywords])).to equal(untyped)
      end

      it "leaves the variable untyped when it sits inside a container parameter" do
        mapping = Rigor::Type::Combinator.hash_shape_of({ a: Rigor::Type::Combinator.constant_of(:x) })
        type = fold_call(:mapped, [mapping])
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Array", type_args: [untyped]))
      end

      # `T` is the container's element, whatever class the argument has.
      it "leaves the variable untyped when a closed-class argument lands in a container parameter" do
        string = Rigor::Type::Combinator.nominal_of(String)
        expect(fold_call(:listed, [string], block_type: string)).to equal(untyped)
      end

      it "binds exactly when the argument's parameter does not name the variable (control)" do
        expect(fold_call(:counted, [Rigor::Type::Combinator.constant_of(3)])).to eq(integer)
      end

      it "binds exactly for a generic whose only positional is the block (control)" do
        expect(fold_call(:block_only, [])).to eq(integer)
      end

      # core RBS: `Hash#transform_keys: [K2] (hash[_Key, K2]) { (K) -> K2 } -> Hash[K2, V]`. The key a
      # mapping hit takes never reaches the block, so the block's `String` does not cover `:x`.
      # `HashTransformKeysFolding` answers this form ahead of this tier; calling the tier directly shows
      # what a form that tier declines would get, at a call site the argument binding accepts.
      it "leaves the core transform_keys mapping overload's key untyped" do
        receiver = Rigor::Type::Combinator.nominal_of(
          "Hash", type_args: [Rigor::Type::Combinator.nominal_of(Symbol), integer]
        )
        mapping = Rigor::Type::Combinator.hash_shape_of({ a: Rigor::Type::Combinator.constant_of(:x) })
        type = described_class.try_dispatch(cc(
                                              receiver: receiver,
                                              method_name: :transform_keys,
                                              args: [mapping],
                                              environment: environment,
                                              block_type: Rigor::Type::Combinator.nominal_of(String),
                                              scope: Rigor::Scope.empty(environment: environment),
                                              call_node: Prism.parse("h.transform_keys(m) { |k| k.to_s }")
                                                              .value.statements.body.first
                                            ))
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Hash", type_args: [untyped, integer]))
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
          type rigor_spec_name = ::String & _RigorSpecMarker

          class RigorSpecTree
            def leaf: () -> rigor_spec_leaf
            def leaf_or_nil: () -> rigor_spec_leaf?
            def graft: (rigor_spec_leaf) -> ::Integer
                     | (rigor_spec_name) -> ::String
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

      # Overload selection: BOTH overloads carry alias params, so the strict pass skips them (not
      # strictly typed) and the well-known-alias pass does not know these names — the gradual pass
      # decides. With the expander threaded through `accepts_param?`, the first overload's expanded
      # `Nominal[RigorSpecLeaf]` REJECTS a String argument outright, so the call lands on the
      # String-aliased overload. Before the threading both params translated untyped, the first
      # overload gradually accepted everything, and the String argument read Integer by list position.
      it "steers overload selection through an expanded alias parameter" do
        string_arg = Rigor::Type::Combinator.nominal_of("String")
        type = described_class.try_dispatch(cc(
                                              receiver: tree,
                                              method_name: :graft,
                                              args: [string_arg],
                                              environment: aliased_environment
                                            ))
        expect(type.describe(:short)).to eq("String")
      end

      it "still selects the first alias-param overload when the argument matches it" do
        leaf_arg = Rigor::Type::Combinator.nominal_of("RigorSpecLeaf")
        type = described_class.try_dispatch(cc(
                                              receiver: tree,
                                              method_name: :graft,
                                              args: [leaf_arg],
                                              environment: aliased_environment
                                            ))
        expect(type.describe(:short)).to eq("Integer")
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

  # Issue #1130 — the block-param probe must apply the SAME {SelfSubstitute} keep-vs-degrade verdict the
  # return path applies (#1092), so a `-> self`-ish block parameter (`tap` yields `self`) arrives with the
  # receiver's type arguments. The block path reuses only the verdict, not the return path's value-pin
  # widening: the block parameter is a destructure source, so pinned element constants stay (`[1, 2].tap`
  # yields `Array[1 | 2]`, and `|a, b|` binds the element union per slot), and a mutator the verdict
  # declines keeps the raw nominal.
  describe ".block_param_types" do
    let(:integer_nominal) { Rigor::Type::Combinator.nominal_of("Integer") }

    def probe(receiver, method_name, args = [], env = environment)
      described_class.block_param_types(cc(
                                          receiver: receiver,
                                          method_name: method_name,
                                          args: args,
                                          environment: env
                                        ))
    end

    it "binds tap's `self` block parameter with the receiver's type arguments" do
      ints = Rigor::Type::Combinator.nominal_of("Array", type_args: [integer_nominal])
      expect(probe(ints, :tap)).to eq([ints])
    end

    it "keeps the literal-tuple receiver's pinned element union (`[1, 2].tap` yields `Array[1 | 2]`)" do
      one = Rigor::Type::Combinator.constant_of(1)
      two = Rigor::Type::Combinator.constant_of(2)
      yielded = Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.union(one, two)])
      expect(probe(Rigor::Type::Combinator.tuple_of(one, two), :tap)).to eq([yielded])
      expect(yielded.describe(:short)).to eq("Array[1 | 2]")
    end

    it "keeps the projected nominal for a HashShape receiver on a non-mutator" do
      shape = Rigor::Type::Combinator.hash_shape_of({ a: integer_nominal })
      yielded = Rigor::Type::Combinator.nominal_of(
        "Hash",
        type_args: [
          Rigor::Type::Combinator.constant_of(:a),
          integer_nominal
        ]
      )
      expect(probe(shape, :tap)).to eq([yielded])
    end

    it "declines the substitution for a mutator the verdict does not keep" do
      box = Rigor::Type::Combinator.nominal_of("SubBox", type_args: [integer_nominal])
      env = sub_box_environment
      # `pure` is `{ (self) -> void } -> self`: the block parameter sees the Box[Integer] substitution.
      expect(probe(box, :pure, [], env)).to eq([box])
      # `rewrite!` is an element-changing mutator; SelfSubstitute declines, so the block parameter stays
      # the raw nominal.
      expect(probe(box, :rewrite!, [], env))
        .to eq([Rigor::Type::Combinator.nominal_of("SubBox")])
    end

    it "loads a user class with the standard environment when no custom sig is needed" do
      raw_array = Rigor::Type::Combinator.nominal_of("Array")
      expect(probe(raw_array, :tap)).to eq([raw_array])
    end

    it "leaves the element type on a mutator's own block parameter (type-variable path, unchanged)" do
      ints = Rigor::Type::Combinator.nominal_of("Array", type_args: [integer_nominal])
      expect(probe(ints, :map!)).to eq([integer_nominal])
    end
  end

  # `SubBox[A]` — the minimal class surface for the mutator-decline assertion: a `-> self`-yielding
  # non-mutator (`pure`) and one that can rewrite the element (`rewrite!`).
  def sub_box_environment
    @sub_box_environment ||= begin
      dir = SpecTmpdir.suite_lifetime("rigor-subbox-sig")
      File.write(File.join(dir, "sub_box.rbs"), <<~RBS)
        class SubBox[A]
          def pure: () { (self) -> void } -> self
          def rewrite!: () { (self) -> void } -> self
        end
      RBS
      Rigor::Environment.for_project(root: dir, signature_paths: [dir])
    end
  end
end
