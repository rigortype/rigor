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
  end
end
