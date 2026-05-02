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
