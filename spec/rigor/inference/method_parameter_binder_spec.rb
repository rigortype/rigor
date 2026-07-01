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
      # Array#first has both `()` and `(int)` overloads; binding a
      # `def first(n)` redefinition MUST union from the only overload
      # that has slot 0.
      binder = described_class.new(environment: env, class_path: "Array", singleton: false)
      result = binder.bind(def_node("def first(n); n; end"))

      # The single relevant overload's type is `int` (an RBS interface),
      # which the translator currently degrades to `Dynamic[Top]`.
      # The binder MUST NOT have left it at the default-untyped sentinel
      # under a different identity — it should match the translator's
      # canonical Dynamic[Top].
      expect(result[:n]).to eq(Rigor::Type::Combinator.untyped)
    end

    it "binds singleton (class-method) parameters when singleton: true" do
      binder = described_class.new(environment: env, class_path: "Integer", singleton: true)
      result = binder.bind(def_node("def sqrt(n); n; end"))

      # `Integer.sqrt(::int)` again degrades to Dynamic[Top] but the
      # singleton path MUST be the one consulted.
      expect(result.keys).to eq([:n])
      expect(result[:n]).to eq(Rigor::Type::Combinator.untyped)
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
      # We pick a method that has at least one keyword parameter in
      # core RBS. `Numeric#step` has `by:` and `to:` keywords.
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
      # A single fixture method exercising every ParamSlot kind in one
      # pass: required/optional/rest/trailing positionals, required/
      # optional keywords, keyword-rest, and a block. Each slot's RBS
      # type is a distinct concrete nominal so a wrong RBS_TYPE_PROVIDERS
      # lookup (wrong lambda, wrong `.index`/`.name` key) or a wrong
      # `wrap_for_kind` argument surfaces as a mismatched class_name
      # rather than merely "not Dynamic".
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
          # The block slot has no RBS counterpart to bind against (the
          # `{ ... }` in the signature types the *call*, not a `&blk`
          # parameter) — it MUST still be present in the entry scope,
          # defaulted to Dynamic[Top].
          expect(result[:blk]).to equal(Rigor::Type::Combinator.untyped)
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
