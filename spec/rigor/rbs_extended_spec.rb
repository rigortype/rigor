# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rbs"

RSpec.describe Rigor::RbsExtended do
  describe ".parse_predicate_annotation" do
    it "parses a predicate-if-true directive" do
      effect = described_class.parse_predicate_annotation("rigor:v1:predicate-if-true value is String")
      expect(effect).to be_a(Rigor::RbsExtended::PredicateEffect)
      expect(effect.edge).to eq(:truthy_only)
      expect(effect.target_kind).to eq(:parameter)
      expect(effect.target_name).to eq(:value)
      expect(effect.class_name).to eq("String")
    end

    it "parses a predicate-if-false directive" do
      effect = described_class.parse_predicate_annotation("rigor:v1:predicate-if-false value is NilClass")
      expect(effect.edge).to eq(:falsey_only)
      expect(effect.class_name).to eq("NilClass")
    end

    it "strips a leading `::` from the class name" do
      effect = described_class.parse_predicate_annotation("rigor:v1:predicate-if-true value is ::String")
      expect(effect.class_name).to eq("String")
    end

    it "parses qualified class names" do
      effect = described_class.parse_predicate_annotation("rigor:v1:predicate-if-true value is Foo::Bar::Baz")
      expect(effect.class_name).to eq("Foo::Bar::Baz")
    end

    it "recognises `self` as the target" do
      effect = described_class.parse_predicate_annotation("rigor:v1:predicate-if-true self is LoggedInUser")
      expect(effect.target_kind).to eq(:self)
      expect(effect.target_name).to eq(:self)
    end

    it "returns nil for non-rigor directives" do
      expect(described_class.parse_predicate_annotation("steep:foo:bar")).to be_nil
    end

    it "returns nil for unrecognised rigor directives" do
      expect(described_class.parse_predicate_annotation("rigor:v1:assert value is String")).to be_nil
    end

    it "returns nil for malformed payload" do
      expect(described_class.parse_predicate_annotation("rigor:v1:predicate-if-true Garbage")).to be_nil
    end
  end

  describe ".read_predicate_effects integration" do
    def with_extdemo
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig/checker.rbs"), <<~RBS)
          class Checker
            %a{rigor:v1:predicate-if-true value is String}
            %a{rigor:v1:predicate-if-false value is NilClass}
            def string_value?: (untyped value) -> bool
          end
        RBS
        env = Rigor::Environment.for_project(root: dir)
        method_def = env.rbs_loader.instance_method(class_name: "Checker", method_name: :string_value?)
        yield method_def
      end
    end

    it "reads both predicate edges off a method's annotations" do
      with_extdemo do |method_def|
        effects = described_class.read_predicate_effects(method_def)
        expect(effects.size).to eq(2)
        expect(effects.map(&:edge)).to contain_exactly(:truthy_only, :falsey_only)
        expect(effects.map(&:class_name)).to contain_exactly("String", "NilClass")
      end
    end

    it "returns [] for a nil method def" do
      expect(described_class.read_predicate_effects(nil)).to eq([])
    end
  end

  describe "Narrowing integration end-to-end (Slice 7 phase 15)" do
    it "narrows a parameter at the call site through predicate-if-true / predicate-if-false" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig/checker.rbs"), <<~RBS)
          class Checker
            %a{rigor:v1:predicate-if-true value is String}
            %a{rigor:v1:predicate-if-false value is NilClass}
            def string_value?: (untyped value) -> bool
          end
        RBS
        File.write(File.join(dir, "demo.rb"), <<~RUBY)
          def f(value)
            c = Checker.new
            if c.string_value?(value)
              value
            else
              value
            end
          end
        RUBY
        Dir.chdir(dir) do
          env = Rigor::Environment.for_project
          source = File.read("demo.rb")
          tree = Prism.parse(source).value
          base = Rigor::Scope.empty(environment: env)
          index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: base)
          locator = Rigor::Source::NodeLocator.new(source: source, root: tree)
          truthy_node = locator.at_position(line: 4, column: 5)
          falsey_node = locator.at_position(line: 6, column: 5)
          truthy_scope = index[truthy_node]
          falsey_scope = index[falsey_node]
          expect(truthy_scope.local(:value)).to be_a(Rigor::Type::Nominal)
          expect(truthy_scope.local(:value).class_name).to eq("String")
          expect(falsey_scope.local(:value)).to be_a(Rigor::Type::Nominal)
          expect(falsey_scope.local(:value).class_name).to eq("NilClass")
        end
      end
    end
  end

  describe ".parse_assert_annotation (v0.0.2)" do
    it "parses an unconditional `assert` directive" do
      effect = described_class.parse_assert_annotation("rigor:v1:assert value is String")
      expect(effect).to be_a(Rigor::RbsExtended::AssertEffect)
      expect(effect.condition).to eq(:always)
      expect(effect.target_kind).to eq(:parameter)
      expect(effect.target_name).to eq(:value)
      expect(effect.class_name).to eq("String")
      expect(effect).to be_always
    end

    it "parses `assert-if-true`" do
      effect = described_class.parse_assert_annotation("rigor:v1:assert-if-true value is Integer")
      expect(effect.condition).to eq(:if_truthy_return)
      expect(effect).to be_if_truthy_return
    end

    it "parses `assert-if-false`" do
      effect = described_class.parse_assert_annotation("rigor:v1:assert-if-false value is NilClass")
      expect(effect.condition).to eq(:if_falsey_return)
      expect(effect).to be_if_falsey_return
    end

    it "returns nil for non-assert directives (e.g. predicate-if-true)" do
      expect(described_class.parse_assert_annotation("rigor:v1:predicate-if-true value is String")).to be_nil
    end

    it "returns nil for unrecognised payload shape" do
      expect(described_class.parse_assert_annotation("rigor:v1:assert garbage")).to be_nil
    end

    describe "negation `~T` (v0.0.2 #2)" do
      it "marks the assert effect as negative when the type is `~ClassName`" do
        effect = described_class.parse_assert_annotation("rigor:v1:assert value is ~NilClass")
        expect(effect).to be_negative
        expect(effect.class_name).to eq("NilClass")
      end

      it "leaves positive directives unmarked" do
        effect = described_class.parse_assert_annotation("rigor:v1:assert value is String")
        expect(effect).not_to be_negative
      end

      it "marks predicate effects as negative" do
        effect = described_class.parse_predicate_annotation("rigor:v1:predicate-if-true value is ~NilClass")
        expect(effect).to be_negative
        expect(effect.class_name).to eq("NilClass")
      end
    end
  end

  describe ".parse_return_type_override" do
    it "resolves a kebab-case refinement to its Type carrier" do
      type = described_class.parse_return_type_override("rigor:v1:return: non-empty-string")
      expect(type).to eq(Rigor::Type::Combinator.non_empty_string)
    end

    it "resolves the IntegerRange refinements" do
      expect(described_class.parse_return_type_override("rigor:v1:return: positive-int"))
        .to eq(Rigor::Type::Combinator.positive_int)
      expect(described_class.parse_return_type_override("rigor:v1:return: non-negative-int"))
        .to eq(Rigor::Type::Combinator.non_negative_int)
    end

    it "returns nil for an unknown refinement name" do
      expect(described_class.parse_return_type_override("rigor:v1:return: frobinator-string"))
        .to be_nil
    end

    it "returns nil for non-`return:` directives" do
      expect(described_class.parse_return_type_override("rigor:v1:assert value is String"))
        .to be_nil
      expect(described_class.parse_return_type_override("steep:foo:bar"))
        .to be_nil
    end

    it "tolerates extra whitespace around the refinement name" do
      type = described_class.parse_return_type_override("rigor:v1:return:    non-empty-string   ")
      expect(type).to eq(Rigor::Type::Combinator.non_empty_string)
    end

    it "resolves parameterised refinements through the new tokeniser" do
      expect(described_class.parse_return_type_override("rigor:v1:return: non-empty-array[Integer]"))
        .to eq(Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("Integer")))
      expect(described_class.parse_return_type_override("rigor:v1:return: non-empty-hash[Symbol, Integer]"))
        .to eq(Rigor::Type::Combinator.non_empty_hash(
                 Rigor::Type::Combinator.nominal_of("Symbol"),
                 Rigor::Type::Combinator.nominal_of("Integer")
               ))
      expect(described_class.parse_return_type_override("rigor:v1:return: int<5, 10>"))
        .to eq(Rigor::Type::Combinator.integer_range(5, 10))
    end

    it "returns nil for malformed parameterised payloads" do
      expect(described_class.parse_return_type_override("rigor:v1:return: non-empty-array[")).to be_nil
      expect(described_class.parse_return_type_override("rigor:v1:return: int<5, 10")).to be_nil
    end
  end

  describe ".parse_param_annotation" do
    it "parses a bare kebab-case payload" do
      override = described_class.parse_param_annotation("rigor:v1:param: id is non-empty-string")
      expect(override).to be_a(Rigor::RbsExtended::ParamOverride)
      expect(override.param_name).to eq(:id)
      expect(override.type).to eq(Rigor::Type::Combinator.non_empty_string)
    end

    it "tolerates the `is` glue word being absent" do
      # The grammar is `param: <name> <payload>`; the existing
      # surface in the codebase keeps `<name> <payload>` rather
      # than requiring a dedicated `is` keyword. Accept either.
      expect(described_class.parse_param_annotation("rigor:v1:param: id non-empty-string"))
        .to be_a(Rigor::RbsExtended::ParamOverride)
    end

    it "parses parameterised payloads through the refinement parser" do
      override = described_class.parse_param_annotation("rigor:v1:param: ids non-empty-array[Integer]")
      expect(override.param_name).to eq(:ids)
      expect(override.type).to eq(
        Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("Integer"))
      )
    end

    it "parses int<min, max> parameterised payloads" do
      override = described_class.parse_param_annotation("rigor:v1:param: idx int<5, 10>")
      expect(override.type).to eq(Rigor::Type::Combinator.integer_range(5, 10))
    end

    it "returns nil for non-`param:` directives" do
      expect(described_class.parse_param_annotation("rigor:v1:return: non-empty-string")).to be_nil
      expect(described_class.parse_param_annotation("rigor:v1:assert id is String")).to be_nil
      expect(described_class.parse_param_annotation("steep:foo:bar")).to be_nil
    end

    it "returns nil for unknown refinement names" do
      expect(described_class.parse_param_annotation("rigor:v1:param: id frobinator-string")).to be_nil
    end

    it "returns nil for malformed payloads" do
      expect(described_class.parse_param_annotation("rigor:v1:param:")).to be_nil
      expect(described_class.parse_param_annotation("rigor:v1:param: id")).to be_nil
    end
  end

  describe "refinement payloads on assert / predicate-if-* (v0.0.4)" do
    it "parses an assert directive with a kebab-case refinement payload" do
      effect = described_class.parse_assert_annotation("rigor:v1:assert value is non-empty-string")
      expect(effect.refinement?).to be(true)
      expect(effect.refinement_type).to eq(Rigor::Type::Combinator.non_empty_string)
      expect(effect.class_name).to be_nil
      expect(effect).not_to be_negative
    end

    it "parses an assert-if-true directive with a parameterised payload" do
      effect = described_class.parse_assert_annotation("rigor:v1:assert-if-true ids is non-empty-array[Integer]")
      expect(effect.condition).to eq(:if_truthy_return)
      expect(effect.refinement_type).to eq(
        Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("Integer"))
      )
    end

    it "parses a predicate-if-true directive with a refinement payload" do
      effect = described_class.parse_predicate_annotation("rigor:v1:predicate-if-true s is lowercase-string")
      expect(effect.refinement?).to be(true)
      expect(effect.refinement_type).to eq(Rigor::Type::Combinator.lowercase_string)
    end

    it "preserves the class-name path for Capitalised RHSes" do
      effect = described_class.parse_assert_annotation("rigor:v1:assert value is String")
      expect(effect.refinement?).to be(false)
      expect(effect.refinement_type).to be_nil
      expect(effect.class_name).to eq("String")
    end

    it "drops directives whose refinement payload is unparseable" do
      expect(described_class.parse_assert_annotation("rigor:v1:assert value is frobinator-string")).to be_nil
      expect(described_class.parse_predicate_annotation("rigor:v1:predicate-if-true v is uint<0, 5>")).to be_nil
    end
  end

  describe ".read_param_type_overrides + .param_type_override_map" do
    def with_param_demo
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig/normaliser.rbs"), <<~RBS)
          class ParamDemo
            %a{rigor:v1:param: id is non-empty-string}
            %a{rigor:v1:param: count is positive-int}
            def normalise: (::String id, ::Integer count) -> String
          end
        RBS
        env = Rigor::Environment.for_project(root: dir)
        method_def = env.rbs_loader.instance_method(class_name: "ParamDemo", method_name: :normalise)
        yield method_def
      end
    end

    it "returns one ParamOverride per recognised annotation" do
      with_param_demo do |method_def|
        overrides = described_class.read_param_type_overrides(method_def)
        expect(overrides.map(&:param_name)).to contain_exactly(:id, :count)
        expect(overrides.map(&:type)).to contain_exactly(
          Rigor::Type::Combinator.non_empty_string,
          Rigor::Type::Combinator.positive_int
        )
      end
    end

    it "exposes the overrides as a name → type Hash via param_type_override_map" do
      with_param_demo do |method_def|
        map = described_class.param_type_override_map(method_def)
        expect(map[:id]).to eq(Rigor::Type::Combinator.non_empty_string)
        expect(map[:count]).to eq(Rigor::Type::Combinator.positive_int)
        expect(map[:other]).to be_nil
        expect(map).to be_frozen
      end
    end

    it "returns [] / {} for a nil method def" do
      expect(described_class.read_param_type_overrides(nil)).to eq([])
      expect(described_class.param_type_override_map(nil)).to eq({})
    end
  end
end
