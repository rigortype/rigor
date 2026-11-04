# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::MethodParameterBinder do
  let(:env) { Rigor::Environment.default }

  def def_node(source)
    Prism.parse(source).value.statements.body.first
  end

  describe "#bind" do
    it "returns Dynamic[Top] for every parameter when no class context is given" do
      binder = described_class.new(environment: env, class_path: nil, singleton: false)
      result = binder.bind(def_node("def add(a, b); a + b; end"))

      expect(result.keys).to eq(%i[a b])
      result.each_value do |t|
        expect(t).to equal(Rigor::Type::Combinator.untyped)
      end
    end

    it "returns Dynamic[Top] for every parameter when the class is unknown to RBS" do
      binder = described_class.new(environment: env, class_path: "NoSuchClass", singleton: false)
      result = binder.bind(def_node("def foo(x); x; end"))

      expect(result[:x]).to equal(Rigor::Type::Combinator.untyped)
    end

    it "returns Dynamic[Top] when the class is known but the method is not" do
      binder = described_class.new(environment: env, class_path: "Integer", singleton: false)
      result = binder.bind(def_node("def my_unknown_method(x); x; end"))

      expect(result[:x]).to equal(Rigor::Type::Combinator.untyped)
    end

    it "binds positional parameters from RBS instance methods, unioned across overloads" do
      binder = described_class.new(environment: env, class_path: "Integer", singleton: false)
      result = binder.bind(def_node("def divmod(other); other; end"))

      expect(result.keys).to eq([:other])
      type = result[:other]
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:class_name)).to contain_exactly("Float", "Integer", "Numeric", "Rational")
    end

    it "skips overloads that omit a parameter slot when unioning across overloads" do
      # Array#first has both `()` and `(int)` overloads; binding a `def first(n)` redefinition MUST union from the only
      # overload that has slot 0.
      binder = described_class.new(environment: env, class_path: "Array", singleton: false)
      result = binder.bind(def_node("def first(n); n; end"))

      # The single relevant overload's type is the `int` alias (`::Integer | ::_ToInt`). Since #529 the
      # translator expands it: the Integer member survives as evidence and the interface member keeps the
      # union gradual, so the binder's result proves the `(int)` overload — not the `()` one — was read.
      type = result[:n]
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to include(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(type.members).to include(Rigor::Type::Combinator.untyped)
    end

    it "binds singleton (class-method) parameters when singleton: true" do
      binder = described_class.new(environment: env, class_path: "Integer", singleton: true)
      result = binder.bind(def_node("def sqrt(n); n; end"))

      # `Integer.sqrt(::int)` — the expanded alias's Integer member proves the singleton path was the one
      # consulted (the instance side has no `sqrt`).
      expect(result.keys).to eq([:n])
      expect(result[:n].members).to include(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "routes def self.foo through the singleton path even when singleton: false" do
      binder = described_class.new(environment: env, class_path: "Integer", singleton: false)
      result = binder.bind(def_node("def self.sqrt(n); n; end"))

      expect(result.keys).to eq([:n])
    end

    it "wraps a *rest parameter as Array[T]" do
      binder = described_class.new(environment: env, class_path: "Array", singleton: false)
      result = binder.bind(def_node("def push(*items); items; end"))

      type = result[:items]
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
      expect(type.type_args.size).to eq(1)
    end

    it "binds keyword parameters by name from RBS" do
      # We pick a method that has at least one keyword parameter in core RBS. `Numeric#step` has `by:` and `to:`
      # keywords.
      binder = described_class.new(environment: env, class_path: "Numeric", singleton: false)
      result = binder.bind(def_node("def step(by:, to:); by; end"))

      expect(result.keys).to contain_exactly(:by, :to)
      # Both should resolve to non-untyped types via RBS.
      expect(result[:by]).not_to equal(Rigor::Type::Combinator.untyped)
      expect(result[:to]).not_to equal(Rigor::Type::Combinator.untyped)
    end

    it "returns an empty hash for a parameterless def" do
      binder = described_class.new(environment: env, class_path: "Integer", singleton: false)
      result = binder.bind(def_node("def succ; self + 1; end"))

      expect(result).to be_empty
    end

    it "skips anonymous rest parameters silently (no name to bind)" do
      binder = described_class.new(environment: env, class_path: nil, singleton: false)
      result = binder.bind(def_node("def foo(*); 1; end"))

      expect(result).to be_empty
    end

    context "with destructured positional parameters (Prism::MultiTargetNode)" do
      let(:binder) { described_class.new(environment: env, class_path: nil, singleton: false) }

      it "binds each leaf sub-target to Dynamic[Top] for a simple destructure" do
        result = binder.bind(def_node("def f((a, b)); a; end"))

        expect(result.keys).to eq(%i[a b])
        result.each_value { |t| expect(t).to equal(Rigor::Type::Combinator.untyped) }
      end

      it "binds plain positionals alongside a destructured slot" do
        result = binder.bind(def_node("def g(x, (y, z)); y; end"))

        expect(result.keys).to eq(%i[x y z])
      end

      it "recurses into nested destructures and unwraps a splat sub-target" do
        result = binder.bind(def_node("def h((a, (b, c)), (d, *e, f)); a; end"))

        expect(result.keys).to eq(%i[a b c d e f])
      end

      it "binds a destructured trailing positional (the erb.rb `location=` shape)" do
        result = binder.bind(def_node("def location=((filename, lineno)); filename; end"))

        expect(result.keys).to eq(%i[filename lineno])
      end
    end

    context "with every positional/keyword/rest/block slot kind bound from RBS" do
      # A single fixture method exercising every ParamSlot kind in one pass: required/optional/rest/trailing
      # positionals, required/optional keywords, keyword-rest, and a block. Each slot's RBS type is a distinct concrete
      # nominal so a wrong RBS_TYPE_PROVIDERS lookup (wrong lambda, wrong `.index`/`.name` key) or a wrong
      # `wrap_for_kind` argument surfaces as a mismatched class_name rather than merely "not Dynamic".
      def with_full_slot_demo
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "sig"))
          File.write(File.join(dir, "sig/full_slot_demo.rbs"), <<~RBS)
            class FullSlotDemo
              def f: (String a, ?Integer b, *Float rest, Symbol c, d: TrueClass, ?e: FalseClass, **Numeric kw) { (Integer) -> void } -> void
            end
          RBS
          project_env = Rigor::Environment.for_project(root: dir)
          binder = described_class.new(environment: project_env, class_path: "FullSlotDemo", singleton: false)
          yield binder
        end
      end

      it "binds every slot kind to its distinct RBS-declared type" do
        with_full_slot_demo do |binder|
          result = binder.bind(def_node("def f(a, b=1, *rest, c, d:, e: 1, **kw, &blk); a; end"))

          expect(result.keys).to eq(%i[a b rest c d e kw blk])
          expect(result[:a]).to eq(Rigor::Type::Combinator.nominal_of("String"))
          expect(result[:b]).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
          expect(result[:rest]).to eq(
            Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("Float")])
          )
          expect(result[:c]).to eq(Rigor::Type::Combinator.nominal_of("Symbol"))
          expect(result[:d]).to eq(Rigor::Type::Combinator.nominal_of("TrueClass"))
          expect(result[:e]).to eq(Rigor::Type::Combinator.nominal_of("FalseClass"))
          expect(result[:kw]).to eq(
            Rigor::Type::Combinator.nominal_of(
              "Hash",
              type_args: [Rigor::Type::Combinator.nominal_of("Symbol"), Rigor::Type::Combinator.nominal_of("Numeric")]
            )
          )
          # The block slot has no RBS counterpart to bind against (the `{ ... }` in the signature types the *call*, not
          # a `&blk` parameter) — it MUST still be present in the entry scope, defaulted to Dynamic[Top].
          expect(result[:blk]).to equal(Rigor::Type::Combinator.untyped)
        end
      end
    end

    # #2681 — a `def` whose parameter shape differs from its RBS overload's binds a slot only where the two line up:
    # leading positionals by absolute position, `*rest` only when the def has every declared leading positional,
    # `**kw` only when the def names every declared keyword. Before, a slot was indexed within its own kind, so
    # `def opt(x = 0, y = "")` under `(Integer x, ?String y)` bound `x` to `String`, and `x.even?` reported.
    context "with a def whose parameter shape differs from its RBS overload" do
      def with_shape_demo
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "sig"))
          File.write(File.join(dir, "sig/shape_demo.rbs"), <<~RBS)
            class ShapeDemo
              def opt: (Integer x, ?String y) -> void
              def go: (Integer x, ?String y, *Symbol rest, **Float kw) -> void
              def kws: (Integer x, path: String, **Float kw) -> void
              def posts: (Integer a, Symbol z) -> void
              def absorb: (Integer x) -> void
                        | (*Symbol rest) -> void
              def pos_kw: (Integer x, ?String y, path: String) -> void
              def rest_kw: (*Integer xs, path: String) -> void
              def past_rest: (Integer x, String y) -> void
                           | (Integer x, *Symbol r) -> void
              def kw_rest: (path: String) -> void
                         | (**Float kw) -> void
              def posts_rest: (Integer x, *Symbol s, Float u, String t) -> void
            end
          RBS
          project_env = Rigor::Environment.for_project(root: dir)
          yield described_class.new(environment: project_env, class_path: "ShapeDemo", singleton: false)
        end
      end

      let(:untyped) { Rigor::Type::Combinator.untyped }

      def nominal(name, args = []) = Rigor::Type::Combinator.nominal_of(name, type_args: args)

      it "binds optional positionals by their absolute position" do
        with_shape_demo do |binder|
          result = binder.bind(def_node("def opt(x = 0, y = ''); x; end"))

          expect(result).to eq(x: nominal("Integer"), y: nominal("String"))
        end
      end

      it "leaves a *rest that absorbs declared leading positionals Dynamic[Top]" do
        with_shape_demo do |binder|
          expect(binder.bind(def_node("def go(*args); args; end"))).to eq(args: untyped)
        end
      end

      # `**kw` takes the declared keywords, so none of them reach `*rest` as a positional Hash.
      it "binds *rest to the declared rest when the def has exactly the declared leading positionals" do
        with_shape_demo do |binder|
          result = binder.bind(def_node("def go(x, y = '', *rest, **kw); x; end"))

          expect(result[:rest]).to eq(nominal("Array", [nominal("Symbol")]))
        end
      end

      it "leaves a **kw that absorbs a declared keyword Dynamic[Top]" do
        with_shape_demo do |binder|
          result = binder.bind(def_node("def kws(x, **opts); x; end"))

          expect(result).to eq(x: nominal("Integer"), opts: untyped)
        end
      end

      it "binds **kw to the declared keyword rest when the def names every declared keyword" do
        with_shape_demo do |binder|
          result = binder.bind(def_node("def kws(x, path:, **opts); x; end"))

          expect(result).to eq(x: nominal("Integer"), path: nominal("String"),
                               opts: nominal("Hash", [nominal("Symbol"), nominal("Float")]))
        end
      end

      # The `(*Symbol rest)` overload alone would bind `Array[Symbol]`, but under `(Integer x)` the same `*args`
      # receives the Integer: one overload that does not line up leaves the slot Dynamic[Top].
      it "leaves a slot Dynamic[Top] when any overload does not line up with it" do
        with_shape_demo do |binder|
          expect(binder.bind(def_node("def absorb(*args); args; end"))).to eq(args: untyped)
        end
      end

      # A def with no keyword parameter and no `**` takes a call's keywords as a Hash in one more positional argument,
      # so a slot past the declared required leading positionals, a `*rest` or a post positional may hold that Hash.
      it "leaves a slot that may receive the keywords as a positional Hash Dynamic[Top]" do
        with_shape_demo do |binder|
          expect(binder.bind(def_node("def pos_kw(x, opts = {}); x; end"))).to eq(x: nominal("Integer"), opts: untyped)
          expect(binder.bind(def_node("def pos_kw(x, y); x; end"))).to eq(x: nominal("Integer"), y: untyped)
          expect(binder.bind(def_node("def rest_kw(*xs); xs; end"))).to eq(xs: untyped)
        end
      end

      it "still binds those slots when the def takes the keywords itself" do
        with_shape_demo do |binder|
          result = binder.bind(def_node("def pos_kw(x, y = '', path:); x; end"))

          expect(result).to eq(x: nominal("Integer"), y: nominal("String"), path: nominal("String"))
        end
      end

      it "leaves a leading positional past the declared ones Dynamic[Top] when an overload declares a rest" do
        with_shape_demo do |binder|
          expect(binder.bind(def_node("def past_rest(a, b); a; end"))).to eq(a: nominal("Integer"), b: untyped)
        end
      end

      # The `(**Float kw)` overload hands `path:` a Float; the rule leaves a keyword an overload does not declare
      # beside its `**` rest Dynamic[Top] rather than unioning the rest's value type in.
      it "leaves a keyword an overload covers only through its ** rest Dynamic[Top]" do
        with_shape_demo do |binder|
          expect(binder.bind(def_node("def kw_rest(path:); path; end"))).to eq(path: untyped)
        end
      end

      it "leaves a post positional Dynamic[Top] when the trailing counts differ" do
        with_shape_demo do |binder|
          expect(binder.bind(def_node("def posts_rest(*r, z); z; end"))).to eq(r: untyped, z: untyped)
        end
      end

      it "leaves every positional Dynamic[Top] when the post positionals do not line up" do
        with_shape_demo do |binder|
          expect(binder.bind(def_node("def posts(a, *rest, z); a; end"))).to eq(a: untyped, rest: untyped, z: untyped)
        end
      end
    end

    # #2681 — an RBS-blind environment (no loader) declares no ancestor member, so an override in a source-only
    # class binds nothing from the bridge and the name gate must not reach for the missing loader.
    it "binds nothing from an ancestor in an RBS-blind environment" do
      blind = Rigor::Environment.new(rbs_loader: nil)
      binder = described_class.new(environment: blind, class_path: "BlindLeaf", singleton: false,
                                   scope: Rigor::Scope.empty(environment: blind))

      expect(binder.bind(def_node("def diagnostics_for_file(path:); path; end")))
        .to eq(path: Rigor::Type::Combinator.untyped)
    end

    # Issue #1430 — `(?)` is `RBS::Types::UntypedFunction`, which carries no parameter lists. Before the guard the
    # binder's slot providers called `required_positionals` on it and the whole file failed with an internal error.
    context "with an untyped-parameter `(?)` signature" do
      def with_untyped_demo
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "sig"))
          File.write(File.join(dir, "sig/untyped_demo.rbs"), <<~RBS)
            class UntypedDemo
              def uf2: (?) -> Integer
              def mixed: (?) -> Integer
                       | (String a) -> Integer
              %a{rigor:v1:param: id is non-empty-string}
              def with_override: (?) -> String
            end
          RBS
          project_env = Rigor::Environment.for_project(root: dir)
          yield described_class.new(environment: project_env, class_path: "UntypedDemo", singleton: false)
        end
      end

      it "binds every parameter to Dynamic[Top]" do
        with_untyped_demo do |binder|
          result = binder.bind(def_node("def uf2(a, b); a; end"))

          expect(result.keys).to eq(%i[a b])
          result.each_value { |t| expect(t).to equal(Rigor::Type::Combinator.untyped) }
        end
      end

      it "binds every slot kind to Dynamic[Top]" do
        with_untyped_demo do |binder|
          result = binder.bind(def_node("def uf2(a, b=1, *rest, c, d:, e: 1, **kw, &blk); a; end"))

          expect(result.keys).to eq(%i[a b rest c d e kw blk])
          result.each_value { |t| expect(t).to equal(Rigor::Type::Combinator.untyped) }
        end
      end

      it "keeps Dynamic[Top] when a `(?)` overload sits beside a typed one" do
        # The `(?)` overload admits any argument in every slot, so narrowing `a` to the typed sibling's `String`
        # would read a value the method legitimately receives as a contradiction inside the body.
        with_untyped_demo do |binder|
          result = binder.bind(def_node("def mixed(a); a; end"))

          expect(result[:a]).to equal(Rigor::Type::Combinator.untyped)
        end
      end

      it "still applies a `rigor:v1:param:` override to a `(?)` method" do
        with_untyped_demo do |binder|
          result = binder.bind(def_node("def with_override(id, other); id; end"))

          expect(result[:id]).to eq(Rigor::Type::Combinator.non_empty_string)
          expect(result[:other]).to equal(Rigor::Type::Combinator.untyped)
        end
      end
    end

    context "with a self-typed singleton parameter (self_and_instance_type)" do
      it "binds a `self`-typed singleton-method parameter to Type::Singleton, not the instance type" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "sig"))
          File.write(File.join(dir, "sig/self_slot_demo.rbs"), <<~RBS)
            class SelfSlotDemo
              def self.g: (self x) -> void
            end
          RBS
          project_env = Rigor::Environment.for_project(root: dir)
          binder = described_class.new(environment: project_env, class_path: "SelfSlotDemo", singleton: true)
          result = binder.bind(def_node("def g(x); x; end"))

          expect(result[:x]).to eq(Rigor::Type::Combinator.singleton_of("SelfSlotDemo"))
        end
      end
    end

    describe "ADR-28 path-scoped protocol contracts (#apply_protocol_contract)" do
      def contract_registry(param_types:, method_name: :get, singleton: false, path_glob: "lib/controller/**/*.rb")
        services = Rigor::Plugin::Services.new(
          reflection: Rigor::Reflection,
          type: Rigor::Type::Combinator,
          configuration: Rigor::Configuration.new
        )
        klass = Class.new(Rigor::Plugin::Base) do
          manifest(
            id: "spec-protocol-contract", version: "0.1.0",
            protocol_contracts: [
              Rigor::Plugin::ProtocolContract.new(
                path_glob: path_glob,
                method_name: method_name,
                singleton: singleton,
                param_types: param_types
              )
            ]
          )
        end
        Rigor::Plugin::Registry.new(plugins: [klass.new(services: services)])
      end

      def contract_env(registry)
        Rigor::Environment.new(rbs_loader: Rigor::Environment.default.rbs_loader, plugin_registry: registry)
      end

      it "substitutes the contract's declared type for a matching positional slot" do
        registry = contract_registry(param_types: [{ index: 0, type_name: "String" }])
        binder = described_class.new(
          environment: contract_env(registry), class_path: nil, singleton: false,
          source_path: "lib/controller/foo.rb"
        )

        result = binder.bind(def_node("def get(req); req; end"))

        expect(result[:req]).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "overrides even an RBS-bound type — the contract tier runs last" do
        binder = described_class.new(
          environment: contract_env(contract_registry(param_types: [{ index: 0, type_name: "String" }])),
          class_path: "Integer", singleton: false, source_path: "lib/controller/foo.rb"
        )

        result = binder.bind(def_node("def get(other); other; end"))

        expect(result[:other]).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "does not apply the contract when source_path is nil" do
        binder = described_class.new(
          environment: contract_env(contract_registry(param_types: [{ index: 0, type_name: "String" }])),
          class_path: nil, singleton: false
        )

        result = binder.bind(def_node("def get(req); req; end"))

        expect(result[:req]).to equal(Rigor::Type::Combinator.untyped)
      end

      it "does not apply the contract when the environment has no plugin_registry" do
        binder = described_class.new(environment: env, class_path: nil, singleton: false,
                                     source_path: "lib/controller/foo.rb")

        result = binder.bind(def_node("def get(req); req; end"))

        expect(result[:req]).to equal(Rigor::Type::Combinator.untyped)
      end

      it "does not apply the contract when the file path does not match the glob" do
        registry = contract_registry(param_types: [{ index: 0, type_name: "String" }])
        binder = described_class.new(
          environment: contract_env(registry), class_path: nil, singleton: false,
          source_path: "lib/other/foo.rb"
        )

        result = binder.bind(def_node("def get(req); req; end"))

        expect(result[:req]).to equal(Rigor::Type::Combinator.untyped)
      end

      it "does not apply the contract when the method name does not match" do
        registry = contract_registry(param_types: [{ index: 0, type_name: "String" }], method_name: :post)
        binder = described_class.new(
          environment: contract_env(registry), class_path: nil, singleton: false,
          source_path: "lib/controller/foo.rb"
        )

        result = binder.bind(def_node("def get(req); req; end"))

        expect(result[:req]).to equal(Rigor::Type::Combinator.untyped)
      end

      it "does not apply the contract when singleton-ness does not match" do
        registry = contract_registry(param_types: [{ index: 0, type_name: "String" }], singleton: true)
        binder = described_class.new(
          environment: contract_env(registry), class_path: nil, singleton: false,
          source_path: "lib/controller/foo.rb"
        )

        result = binder.bind(def_node("def get(req); req; end"))

        expect(result[:req]).to equal(Rigor::Type::Combinator.untyped)
      end

      it "matches a singleton def when both the contract and the def are singleton" do
        registry = contract_registry(param_types: [{ index: 0, type_name: "String" }], singleton: true)
        binder = described_class.new(
          environment: contract_env(registry), class_path: nil, singleton: true,
          source_path: "lib/controller/foo.rb"
        )

        result = binder.bind(def_node("def get(req); req; end"))

        expect(result[:req]).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "leaves the slot untouched when the contract's type_name does not resolve" do
        registry = contract_registry(param_types: [{ index: 0, type_name: "NoSuchClassAtAll" }])
        binder = described_class.new(
          environment: contract_env(registry), class_path: nil, singleton: false,
          source_path: "lib/controller/foo.rb"
        )

        result = binder.bind(def_node("def get(req); req; end"))

        expect(result[:req]).to equal(Rigor::Type::Combinator.untyped)
      end

      it "leaves the slot untouched when the contract's index has no matching positional slot" do
        registry = contract_registry(param_types: [{ index: 5, type_name: "String" }])
        binder = described_class.new(
          environment: contract_env(registry), class_path: nil, singleton: false,
          source_path: "lib/controller/foo.rb"
        )

        result = binder.bind(def_node("def get(a); a; end"))

        expect(result[:a]).to equal(Rigor::Type::Combinator.untyped)
      end
    end

    describe "rigor:v1:param: body-side overrides (v0.0.4)" do
      def with_param_demo(rbs_body)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "sig"))
          File.write(File.join(dir, "sig/normaliser.rbs"), <<~RBS)
            class ParamBindDemo
              #{rbs_body}
            end
          RBS
          project_env = Rigor::Environment.for_project(root: dir)
          binder = described_class.new(environment: project_env, class_path: "ParamBindDemo", singleton: false)
          yield binder
        end
      end

      it "tightens an RBS-declared parameter to the refinement when the directive matches" do
        with_param_demo(<<~RBS) do |binder|
          %a{rigor:v1:param: id is non-empty-string}
          def normalise: (::String id) -> String
        RBS
          result = binder.bind(def_node("def normalise(id); id; end"))
          expect(result[:id]).to eq(Rigor::Type::Combinator.non_empty_string)
        end
      end

      it "applies parameterised refinement payloads through the override path" do
        with_param_demo(<<~RBS) do |binder|
          %a{rigor:v1:param: ids is non-empty-array[Integer]}
          def normalise: (::Array[::Integer] ids) -> Array[Integer]
        RBS
          result = binder.bind(def_node("def normalise(ids); ids; end"))
          expect(result[:ids]).to eq(
            Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("Integer"))
          )
        end
      end

      it "leaves slots without an override at the RBS-translated type" do
        with_param_demo(<<~RBS) do |binder|
          %a{rigor:v1:param: id is non-empty-string}
          def normalise: (::String id, ::Integer count) -> String
        RBS
          result = binder.bind(def_node("def normalise(id, count); id; end"))
          expect(result[:id]).to eq(Rigor::Type::Combinator.non_empty_string)
          expect(result[:count]).to be_a(Rigor::Type::Nominal)
          expect(result[:count].class_name).to eq("Integer")
        end
      end
    end
  end
end
