# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::HktBodyParser do
  let(:body) { Rigor::Inference::HktBody }

  def parse(string, params: [])
    described_class.parse(string, params: params)
  end

  describe "atom parsing" do
    it "parses `nil` to a Constant<nil> TypeLeaf" do
      result = parse("nil")
      expect(result).to be_a(body::TypeLeaf)
      expect(result.type).to eq(Rigor::Type::Constant.new(nil))
    end

    it "parses `true` to a Constant<true> TypeLeaf" do
      result = parse("true")
      expect(result.type).to eq(Rigor::Type::Constant.new(true))
    end

    it "parses `false` to a Constant<false> TypeLeaf" do
      result = parse("false")
      expect(result.type).to eq(Rigor::Type::Constant.new(false))
    end

    it "parses `bool` to a TypeLeaf wrapping Constant<true> | Constant<false>" do
      result = parse("bool")
      expect(result).to be_a(body::TypeLeaf)
      expect(result.type).to be_a(Rigor::Type::Union)
      expect(result.type.members).to contain_exactly(
        Rigor::Type::Constant.new(true),
        Rigor::Type::Constant.new(false)
      )
    end

    it "parses `untyped` to a TypeLeaf wrapping Dynamic[Top]" do
      result = parse("untyped")
      expect(result.type).to eq(Rigor::Type::Combinator.untyped)
    end

    it "parses a bare class name to a Nominal TypeLeaf" do
      result = parse("Integer")
      expect(result).to be_a(body::TypeLeaf)
      expect(result.type).to eq(Rigor::Type::Nominal.new("Integer"))
    end

    it "parses a qualified class name (Foo::Bar) to a single Nominal" do
      result = parse("Foo::Bar")
      expect(result.type).to eq(Rigor::Type::Nominal.new("Foo::Bar"))
    end

    it "parses a leading-`::` class name and drops the leading separator" do
      result = parse("::String")
      expect(result.type).to eq(Rigor::Type::Nominal.new("String"))
    end
  end

  describe "param parsing" do
    it "parses a UCName matching params to a Param node" do
      result = parse("K", params: [:K])
      expect(result).to eq(body::Param.new(name: :K))
    end

    it "treats a UCName NOT in params as a Nominal class" do
      result = parse("K", params: [])
      expect(result).to eq(body::TypeLeaf.new(type: Rigor::Type::Nominal.new("K")))
    end

    it "treats `Foo::Bar` as a qualified Nominal even when `Foo` is a param" do
      # The `::` continuation forces the nominal interpretation.
      result = parse("Foo::Bar", params: [:Foo])
      expect(result.type).to eq(Rigor::Type::Nominal.new("Foo::Bar"))
    end

    it "treats `Array[K]` as a NominalApp even when `Array` would be a param" do
      # The `[` continuation forces the nominal-app interpretation.
      result = parse("Array[K]", params: %i[Array K])
      expect(result).to be_a(body::NominalApp)
      expect(result.class_name).to eq("Array")
      expect(result.args).to eq([body::Param.new(name: :K)])
    end
  end

  describe "nominal_app parsing" do
    it "parses Array[K] with a single arg" do
      result = parse("Array[K]", params: [:K])
      expect(result).to be_a(body::NominalApp)
      expect(result.class_name).to eq("Array")
      expect(result.args).to eq([body::Param.new(name: :K)])
    end

    it "parses Hash[K, V] with multiple args" do
      result = parse("Hash[K, V]", params: %i[K V])
      expect(result.class_name).to eq("Hash")
      expect(result.args).to eq([body::Param.new(name: :K), body::Param.new(name: :V)])
    end

    it "parses nested Array[Hash[K, V]]" do
      result = parse("Array[Hash[K, V]]", params: %i[K V])
      expect(result.class_name).to eq("Array")
      inner = result.args.first
      expect(inner).to be_a(body::NominalApp)
      expect(inner.class_name).to eq("Hash")
    end
  end

  describe "app_ref parsing" do
    it "parses App[json::value, K]" do
      result = parse("App[json::value, K]", params: [:K])
      expect(result).to be_a(body::AppRef)
      expect(result.uri).to eq(:"json::value")
      expect(result.args).to eq([body::Param.new(name: :K)])
    end

    it "parses App[dry_monads::result, T, E] with multiple args" do
      result = parse("App[dry_monads::result, T, E]", params: %i[T E])
      expect(result.uri).to eq(:"dry_monads::result")
      expect(result.args).to eq([body::Param.new(name: :T), body::Param.new(name: :E)])
    end

    it "rejects an unnamespaced uri" do
      expect { parse("App[value, K]", params: [:K]) }
        .to raise_error(described_class::ParseError, /must be namespaced/)
    end

    it "accepts a deeply-namespaced uri" do
      result = parse("App[a::b::c, K]", params: [:K])
      expect(result.uri).to eq(:"a::b::c")
    end
  end

  describe "union parsing" do
    it "parses `nil | true | false`" do
      result = parse("nil | true | false")
      expect(result).to be_a(body::Union)
      expect(result.arms.size).to eq(3)
    end

    it "parses a single arm without wrapping in a Union" do
      result = parse("Integer")
      expect(result).to be_a(body::TypeLeaf)
    end

    it "parses a heterogeneous union" do
      result = parse("nil | Integer | Array[K]", params: [:K])
      expect(result).to be_a(body::Union)
      expect(result.arms.size).to eq(3)
      expect(result.arms[0]).to be_a(body::TypeLeaf)
      expect(result.arms[1]).to be_a(body::TypeLeaf)
      expect(result.arms[2]).to be_a(body::NominalApp)
    end
  end

  describe "conditional parsing (ADR-20 § D3)" do
    it "parses `(K <: String ? Integer : Float)`" do
      result = parse("(K <: String ? Integer : Float)", params: [:K])
      expect(result).to be_a(body::Conditional)
      expect(result.test).to be_a(body::TestSubtype)
      expect(result.test.left).to eq(body::Param.new(name: :K))
      expect(result.test.right).to eq(body::TypeLeaf.new(type: Rigor::Type::Nominal.new("String")))
      expect(result.then_branch).to eq(body::TypeLeaf.new(type: Rigor::Type::Nominal.new("Integer")))
      expect(result.else_branch).to eq(body::TypeLeaf.new(type: Rigor::Type::Nominal.new("Float")))
    end

    it "parses `(K == nil ? untyped : K)`" do
      result = parse("(K == nil ? untyped : K)", params: [:K])
      expect(result).to be_a(body::Conditional)
      expect(result.test).to be_a(body::TestEquality)
    end

    it "supports nested conditionals" do
      result = parse("(K <: String ? Integer : (K <: Float ? String : nil))", params: [:K])
      expect(result).to be_a(body::Conditional)
      expect(result.else_branch).to be_a(body::Conditional)
    end

    it "supports unions in branches: `(K <: A ? B | C : D | E)`" do
      result = parse("(K <: A ? B | C : D | E)", params: [:K])
      expect(result.then_branch).to be_a(body::Union)
      expect(result.then_branch.arms.size).to eq(2)
      expect(result.else_branch).to be_a(body::Union)
      expect(result.else_branch.arms.size).to eq(2)
    end

    it "supports Array[K] on a test side" do
      result = parse("(K <: Array[Integer] ? Integer : String)", params: [:K])
      expect(result.test.right).to be_a(body::NominalApp)
    end

    it "supports App[uri, K] in branches" do
      result = parse("(K <: nil ? untyped : App[json::value, K])", params: [:K])
      expect(result.else_branch).to be_a(body::AppRef)
    end

    it "raises on missing test operator" do
      expect { parse("(K ? Integer : Float)", params: [:K]) }
        .to raise_error(described_class::ParseError, /expected `<:` or `==`/)
    end

    it "raises on missing `?`" do
      expect { parse("(K <: String Integer : Float)", params: [:K]) }
        .to raise_error(described_class::ParseError, /expected question/)
    end

    it "raises on missing `:` else marker" do
      expect { parse("(K <: String ? Integer Float)", params: [:K]) }
        .to raise_error(described_class::ParseError, /expected colon/)
    end

    it "raises on unclosed paren" do
      expect { parse("(K <: String ? Integer : Float", params: [:K]) }
        .to raise_error(described_class::ParseError, /expected rparen/)
    end

    it "the parsed conditional reduces end-to-end" do
      registry_class = Rigor::Inference::HktRegistry
      registry = registry_class.new(
        registrations: [
          registry_class::Registration.new(uri: :"cond::it", arity: 1, variance: [:out],
                                           bound: Rigor::Type::Combinator.untyped)
        ],
        definitions: [
          registry_class.definition_with_body_tree(
            uri: :"cond::it", params: [:K],
            body_tree: parse("(K <: String ? Integer : Float)", params: [:K])
          )
        ]
      )
      str_app = Rigor::Type::App.new(:"cond::it", [Rigor::Type::Combinator.nominal_of(String)],
                                     bound: Rigor::Type::Combinator.untyped)
      expect(registry.reduce(str_app)).to eq(Rigor::Type::Combinator.nominal_of(Integer))
    end
  end

  describe "JSON_VALUE end-to-end equivalence" do
    let(:registry_class) { Rigor::Inference::HktRegistry }
    let(:str) { Rigor::Type::Combinator.nominal_of(String) }

    let(:json_value_body_str) do
      "nil | true | false | Integer | Float | String | " \
        "Array[App[json::value, K]] | Hash[K, App[json::value, K]]"
    end

    let(:parsed_definition) do
      registry_class.definition_with_body_tree(
        uri: :"json::value",
        params: [:K],
        body_tree: described_class.parse(json_value_body_str, params: [:K])
      )
    end

    let(:registry) do
      registry_class.new(
        registrations: [Rigor::Builtins::HktBuiltins.json_value_registration],
        definitions: [parsed_definition]
      )
    end

    it "reduces to a Union containing the leaf JSON atoms" do
      app = Rigor::Type::App.new(:"json::value", [str], bound: Rigor::Type::Combinator.untyped)
      result = registry.reduce(app)
      expect(result).to be_a(Rigor::Type::Union)
      expect(result.members.map(&:describe)).to include("nil", "true", "false", "Integer", "Float", "String")
    end

    it "keeps the recursive self-reference inside the Array arm" do
      app = Rigor::Type::App.new(:"json::value", [str], bound: Rigor::Type::Combinator.untyped)
      result = registry.reduce(app)
      array_arm = result.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Array" }
      expect(array_arm).not_to be_nil
      nested = array_arm.type_args.first
      expect(nested).to be_a(Rigor::Type::App)
      expect(nested.uri).to eq(:"json::value")
    end

    it "keeps the recursive self-reference inside the Hash arm" do
      app = Rigor::Type::App.new(:"json::value", [str], bound: Rigor::Type::Combinator.untyped)
      result = registry.reduce(app)
      hash_arm = result.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Hash" }
      expect(hash_arm).not_to be_nil
      expect(hash_arm.type_args.first).to eq(str)
      nested = hash_arm.type_args[1]
      expect(nested).to be_a(Rigor::Type::App)
    end

    it "produces a reducer-equivalent answer to the programmatic JSON_VALUE bundled definition" do
      app = Rigor::Type::App.new(:"json::value", [str], bound: Rigor::Type::Combinator.untyped)
      parsed_result = registry.reduce(app)
      bundled_result = Rigor::Builtins::HktBuiltins.registry.reduce(app)
      expect(parsed_result.describe).to eq(bundled_result.describe)
    end
  end

  describe "error cases" do
    it "raises ParseError on an unknown lowercase atom" do
      expect { parse("nilable") }
        .to raise_error(described_class::ParseError, /unknown atom/)
    end

    it "raises ParseError on unbalanced `[`" do
      expect { parse("Array[K", params: [:K]) }
        .to raise_error(described_class::ParseError, /expected rb/)
    end

    it "raises ParseError on a trailing comma" do
      expect { parse("Hash[K, V,]", params: %i[K V]) }
        .to raise_error(described_class::ParseError)
    end

    it "raises ParseError on garbage trailing tokens" do
      expect { parse("Integer extra") }
        .to raise_error(described_class::ParseError, /expected end of input/)
    end

    it "raises ParseError on an unrecognised character" do
      expect { parse("Integer & String") }
        .to raise_error(described_class::ParseError, /unexpected character/)
    end
  end

  describe "directive integration" do
    it "HktDirectives.parse_define populates Definition#body_tree via the parser" do
      payload = "rigor:v1:hkt_define: uri=json::value params=K body=nil | true | false | Integer | " \
                "Float | String | Array[App[json::value, K]] | Hash[K, App[json::value, K]]"
      defn = Rigor::RbsExtended::HktDirectives.parse_define(payload)
      expect(defn).not_to be_nil
      expect(defn.body_tree).not_to be_nil
      expect(defn.body_tree).to be_a(body::Union)
    end

    it "drops body_tree (keeps body String) when the body fails to parse" do
      collected = []
      reporter = Class.new do
        define_method(:initialize) { @entries = collected }
        define_method(:record) { |**e| @entries << e }
      end.new
      payload = "rigor:v1:hkt_define: uri=json::value params=K body=Array[K"
      defn = Rigor::RbsExtended::HktDirectives.parse_define(payload, reporter: reporter)
      expect(defn).not_to be_nil
      expect(defn.body_tree).to be_nil
      expect(collected.last[:message]).to match(/body parse error/)
    end
  end
end
