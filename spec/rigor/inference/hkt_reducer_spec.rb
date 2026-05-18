# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::HktReducer do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:str_nominal) { Rigor::Type::Combinator.nominal_of(String) }
  let(:int_nominal) { Rigor::Type::Combinator.nominal_of(Integer) }
  let(:registry_class) { Rigor::Inference::HktRegistry }
  let(:body) { Rigor::Inference::HktBody }

  def make_app(uri, args, bound: untyped)
    Rigor::Type::App.new(uri, args, bound: bound)
  end

  describe ".new" do
    it "rejects a non-HktRegistry argument" do
      expect { described_class.new(:not_a_registry) }
        .to raise_error(ArgumentError, /registry must be an HktRegistry/)
    end
  end

  describe "#reduce" do
    context "when the URI is not in the registry" do
      let(:registry) { registry_class.new }

      it "returns the App's bound" do
        app = make_app(:"json::value", [str_nominal], bound: int_nominal)
        expect(described_class.new(registry).reduce(app)).to eq(int_nominal)
      end
    end

    context "when the URI is registered but has no body_tree" do
      let(:registry) do
        registry_class.new(
          registrations: [registry_class::Registration.new(uri: :"box::it", arity: 1, variance: [:out],
                                                           bound: untyped)],
          definitions: [registry_class::Definition.new(uri: :"box::it", params: [:K], body: "K")]
        )
      end

      it "returns the App's bound (body_tree is nil)" do
        app = make_app(:"box::it", [str_nominal])
        expect(described_class.new(registry).reduce(app)).to eq(untyped)
      end
    end

    context "with a simple Param substitution" do
      # box::it[K] = K
      let(:registry) do
        registry_class.new(
          registrations: [registry_class::Registration.new(uri: :"box::it", arity: 1, variance: [:out],
                                                           bound: untyped)],
          definitions: [
            registry_class.definition_with_body_tree(
              uri: :"box::it",
              params: [:K],
              body_tree: body::Param.new(name: :K)
            )
          ]
        )
      end

      it "returns the substituted Type" do
        app = make_app(:"box::it", [str_nominal])
        expect(described_class.new(registry).reduce(app)).to eq(str_nominal)
      end
    end

    context "with a Union body" do
      # union::it[K] = K | Integer
      let(:registry) do
        registry_class.new(
          registrations: [registry_class::Registration.new(uri: :"union::it", arity: 1, variance: [:out],
                                                           bound: untyped)],
          definitions: [
            registry_class.definition_with_body_tree(
              uri: :"union::it",
              params: [:K],
              body_tree: body::Union.new(arms: [
                                           body::Param.new(name: :K),
                                           body::TypeLeaf.new(type: Rigor::Type::Combinator.nominal_of(Integer))
                                         ])
            )
          ]
        )
      end

      it "reduces to a normalized Union" do
        app = make_app(:"union::it", [str_nominal])
        result = described_class.new(registry).reduce(app)
        expect(result).to be_a(Rigor::Type::Union)
        expect(result.members).to include(str_nominal, int_nominal)
      end
    end

    context "with a NominalApp body" do
      # box::array[K] = Array[K]
      let(:registry) do
        registry_class.new(
          registrations: [registry_class::Registration.new(uri: :"box::array", arity: 1, variance: [:out],
                                                           bound: untyped)],
          definitions: [
            registry_class.definition_with_body_tree(
              uri: :"box::array",
              params: [:K],
              body_tree: body::NominalApp.new(class_name: "Array", args: [body::Param.new(name: :K)])
            )
          ]
        )
      end

      it "reduces to a parameterised Nominal" do
        app = make_app(:"box::array", [str_nominal])
        result = described_class.new(registry).reduce(app)
        expect(result).to be_a(Rigor::Type::Nominal)
        expect(result.class_name).to eq("Array")
        expect(result.type_args).to eq([str_nominal])
      end
    end

    context "with the JSON.parse-shaped recursive body" do
      # json::value[K] =
      #   nil | true | false | Integer | Float | String
      #   | Array[App[json::value, K]]
      #   | Hash[K, App[json::value, K]]
      let(:json_body_tree) do
        body::Union.new(arms: [
                          body::TypeLeaf.new(type: Rigor::Type::Constant.new(nil)),
                          body::TypeLeaf.new(type: Rigor::Type::Constant.new(true)),
                          body::TypeLeaf.new(type: Rigor::Type::Constant.new(false)),
                          body::TypeLeaf.new(type: Rigor::Type::Combinator.nominal_of(Integer)),
                          body::TypeLeaf.new(type: Rigor::Type::Combinator.nominal_of(Float)),
                          body::TypeLeaf.new(type: Rigor::Type::Combinator.nominal_of(String)),
                          body::NominalApp.new(
                            class_name: "Array",
                            args: [body::AppRef.new(uri: :"json::value", args: [body::Param.new(name: :K)])]
                          ),
                          body::NominalApp.new(
                            class_name: "Hash",
                            args: [
                              body::Param.new(name: :K),
                              body::AppRef.new(uri: :"json::value", args: [body::Param.new(name: :K)])
                            ]
                          )
                        ])
      end

      let(:registry) do
        registry_class.new(
          registrations: [
            registry_class::Registration.new(uri: :"json::value", arity: 1, variance: [:out], bound: untyped)
          ],
          definitions: [
            registry_class.definition_with_body_tree(
              uri: :"json::value", params: [:K], body_tree: json_body_tree
            )
          ]
        )
      end

      it "terminates without infinite expansion" do
        app = make_app(:"json::value", [str_nominal])
        expect { described_class.new(registry).reduce(app) }.not_to raise_error
      end

      it "produces a Union containing the leaf atoms" do
        app = make_app(:"json::value", [str_nominal])
        result = described_class.new(registry).reduce(app)
        expect(result).to be_a(Rigor::Type::Union)
        # leaf atoms — nil / true / false / Integer / Float / String
        # (Constant<nil> / Constant<true> / Constant<false> render as the
        # bare scalar form in the Union's display per the Constant carrier's
        # describe rule)
        expect(result.members.map(&:describe)).to include(
          "nil", "true", "false", "Integer", "Float", "String"
        )
      end

      it "keeps the recursive self-reference as a Type::App carrier inside the Array arm" do
        app = make_app(:"json::value", [str_nominal])
        result = described_class.new(registry).reduce(app)
        array_arm = result.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Array" }
        expect(array_arm).not_to be_nil
        expect(array_arm.type_args.size).to eq(1)
        nested = array_arm.type_args.first
        expect(nested).to be_a(Rigor::Type::App)
        expect(nested.uri).to eq(:"json::value")
        expect(nested.args).to eq([str_nominal])
      end

      it "keeps the recursive self-reference inside the Hash arm" do
        app = make_app(:"json::value", [str_nominal])
        result = described_class.new(registry).reduce(app)
        hash_arm = result.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Hash" }
        expect(hash_arm).not_to be_nil
        expect(hash_arm.type_args.size).to eq(2)
        expect(hash_arm.type_args[0]).to eq(str_nominal)
        nested = hash_arm.type_args[1]
        expect(nested).to be_a(Rigor::Type::App)
        expect(nested.uri).to eq(:"json::value")
        expect(nested.args).to eq([str_nominal])
      end

      it "substitutes K = Symbol distinctly from K = String" do
        sym_nominal = Rigor::Type::Combinator.nominal_of(Symbol)
        app = make_app(:"json::value", [sym_nominal])
        result = described_class.new(registry).reduce(app)
        hash_arm = result.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Hash" }
        expect(hash_arm.type_args[0]).to eq(sym_nominal)
        expect(hash_arm.type_args[1].args).to eq([sym_nominal])
      end
    end

    context "with fuel exhaustion on a non-recursive deep tree" do
      # union::deep[K] = K | K | K | K | K | K (six arms, costs more than fuel=3)
      let(:registry) do
        arms = Array.new(6) { body::Param.new(name: :K) }
        registry_class.new(
          registrations: [registry_class::Registration.new(uri: :"union::deep", arity: 1, variance: [:out],
                                                           bound: int_nominal)],
          definitions: [
            registry_class.definition_with_body_tree(
              uri: :"union::deep", params: [:K], body_tree: body::Union.new(arms: arms)
            )
          ]
        )
      end

      it "returns the App's bound when fuel runs out" do
        app = make_app(:"union::deep", [str_nominal], bound: int_nominal)
        result = described_class.new(registry).reduce(app, fuel: 3)
        expect(result).to eq(int_nominal)
      end

      it "completes when given enough fuel" do
        app = make_app(:"union::deep", [str_nominal], bound: int_nominal)
        result = described_class.new(registry).reduce(app, fuel: 64)
        expect(result).to be_a(Rigor::Type::Union).or eq(str_nominal)
      end
    end

    context "with an arity mismatch between Definition.params and App.args" do
      let(:registry) do
        registry_class.new(
          registrations: [registry_class::Registration.new(uri: :"box::pair", arity: 2, variance: %i[out out],
                                                           bound: untyped)],
          definitions: [
            registry_class.definition_with_body_tree(
              uri: :"box::pair", params: %i[K V], body_tree: body::Param.new(name: :K)
            )
          ]
        )
      end

      it "returns the App's bound when the App has the wrong arity" do
        app = make_app(:"box::pair", [str_nominal])
        expect(described_class.new(registry).reduce(app)).to eq(untyped)
      end
    end

    context "with conditional body nodes (ADR-20 § D3)" do
      let(:str_leaf) { body::TypeLeaf.new(type: str_nominal) }
      let(:int_leaf) { body::TypeLeaf.new(type: int_nominal) }

      def conditional_registry(test_node)
        registry_class.new(
          registrations: [registry_class::Registration.new(uri: :"cond::it", arity: 1, variance: [:out],
                                                           bound: untyped)],
          definitions: [
            registry_class.definition_with_body_tree(
              uri: :"cond::it",
              params: [:K],
              body_tree: body::Conditional.new(
                test: test_node,
                then_branch: str_leaf,
                else_branch: int_leaf
              )
            )
          ]
        )
      end

      it "TestSubtype: left == right yields the then_branch" do
        # K <: String when K = String → :yes → then_branch (String)
        test = body::TestSubtype.new(left: body::Param.new(name: :K), right: str_leaf)
        registry = conditional_registry(test)
        result = registry.reduce(make_app(:"cond::it", [str_nominal]))
        expect(result).to eq(str_nominal)
      end

      it "TestSubtype: disjoint nominals → else_branch" do
        # K <: String when K = Integer → :no (disjoint nominals) → else_branch (Integer)
        test = body::TestSubtype.new(left: body::Param.new(name: :K), right: str_leaf)
        registry = conditional_registry(test)
        result = registry.reduce(make_app(:"cond::it", [int_nominal]))
        expect(result).to eq(int_nominal)
      end

      it "TestEquality on constants: equal → then_branch" do
        # K == :foo when K = Constant<:foo> → :yes → then_branch (String)
        sym_const = Rigor::Type::Constant.new(:foo)
        test = body::TestEquality.new(
          left: body::Param.new(name: :K),
          right: body::TypeLeaf.new(type: sym_const)
        )
        registry = conditional_registry(test)
        result = registry.reduce(make_app(:"cond::it", [sym_const]))
        expect(result).to eq(str_nominal)
      end

      it "TestEquality on constants: not equal → else_branch" do
        test = body::TestEquality.new(
          left: body::Param.new(name: :K),
          right: body::TypeLeaf.new(type: Rigor::Type::Constant.new(:foo))
        )
        registry = conditional_registry(test)
        result = registry.reduce(make_app(:"cond::it", [Rigor::Type::Constant.new(:bar)]))
        expect(result).to eq(int_nominal)
      end

      it "TestMembership: any option matches → then_branch" do
        test = body::TestMembership.new(
          left: body::Param.new(name: :K),
          options: [
            body::TypeLeaf.new(type: Rigor::Type::Constant.new(:foo)),
            body::TypeLeaf.new(type: Rigor::Type::Constant.new(:bar))
          ]
        )
        registry = conditional_registry(test)
        result = registry.reduce(make_app(:"cond::it", [Rigor::Type::Constant.new(:bar)]))
        expect(result).to eq(str_nominal)
      end

      it "TestMembership: no option matches → else_branch" do
        test = body::TestMembership.new(
          left: body::Param.new(name: :K),
          options: [body::TypeLeaf.new(type: Rigor::Type::Constant.new(:foo))]
        )
        registry = conditional_registry(test)
        result = registry.reduce(make_app(:"cond::it", [Rigor::Type::Constant.new(:bar)]))
        expect(result).to eq(int_nominal)
      end

      it "undecided subtype (Dynamic[Top] vs String) widens to union of both branches" do
        # K <: String when K = Dynamic[Top] → :maybe → union(String, Integer)
        test = body::TestSubtype.new(left: body::Param.new(name: :K), right: str_leaf)
        registry = conditional_registry(test)
        result = registry.reduce(make_app(:"cond::it", [untyped]))
        expect(result).to be_a(Rigor::Type::Union)
        expect(result.members).to contain_exactly(str_nominal, int_nominal)
      end
    end

    context "with cross-URI references" do
      # outer::it[K] = Array[App[inner::it, K]]
      # inner::it[K] = K
      let(:registry) do
        registry_class.new(
          registrations: [
            registry_class::Registration.new(uri: :"outer::it", arity: 1, variance: [:out], bound: untyped),
            registry_class::Registration.new(uri: :"inner::it", arity: 1, variance: [:out], bound: untyped)
          ],
          definitions: [
            registry_class.definition_with_body_tree(
              uri: :"outer::it", params: [:K],
              body_tree: body::NominalApp.new(
                class_name: "Array",
                args: [body::AppRef.new(uri: :"inner::it", args: [body::Param.new(name: :K)])]
              )
            ),
            registry_class.definition_with_body_tree(
              uri: :"inner::it", params: [:K], body_tree: body::Param.new(name: :K)
            )
          ]
        )
      end

      it "reduces the cross-URI reference inline" do
        app = make_app(:"outer::it", [str_nominal])
        result = described_class.new(registry).reduce(app)
        expect(result).to be_a(Rigor::Type::Nominal)
        expect(result.class_name).to eq("Array")
        expect(result.type_args).to eq([str_nominal])
      end
    end
  end

  describe "Rigor::Inference::HktRegistry#reduce" do
    let(:registry) do
      registry_class.new(
        registrations: [registry_class::Registration.new(uri: :"box::it", arity: 1, variance: [:out], bound: untyped)],
        definitions: [
          registry_class.definition_with_body_tree(
            uri: :"box::it", params: [:K], body_tree: body::Param.new(name: :K)
          )
        ]
      )
    end

    it "is a convenience wrapper that allocates a fresh reducer" do
      app = make_app(:"box::it", [str_nominal])
      expect(registry.reduce(app)).to eq(str_nominal)
    end
  end

  describe "Rigor::Type::App#reduce" do
    let(:registry) do
      registry_class.new(
        registrations: [registry_class::Registration.new(uri: :"box::it", arity: 1, variance: [:out], bound: untyped)],
        definitions: [
          registry_class.definition_with_body_tree(
            uri: :"box::it", params: [:K], body_tree: body::Param.new(name: :K)
          )
        ]
      )
    end

    it "delegates to registry.reduce(self)" do
      app = make_app(:"box::it", [str_nominal])
      expect(app.reduce(registry)).to eq(str_nominal)
    end

    it "accepts an explicit fuel kwarg" do
      app = make_app(:"box::it", [str_nominal], bound: untyped)
      expect(app.reduce(registry, fuel: 64)).to eq(str_nominal)
    end
  end
end
