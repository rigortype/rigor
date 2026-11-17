# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — the helpers {CheckRules::OverrideSupport} gives the three Liskov override rules and the
# return-type-mismatch rule, called directly. The walk itself (`resolve_authored_override`, the nearest-ancestor and
# generic-instantiation reads) is pinned through the three rules in `override_visibility_spec.rb`,
# `override_return_widened_spec.rb` and `override_param_narrowed_spec.rb`, whose examples all run it.
#
# Mutation-proved together with those three specs: each guard line of this module was blanked in turn and an example in
# one of the four files failed, except these, which no input distinguishes (one line on what was tried each):
#
# - `return nil if scope.nil?` and `return nil unless self_type.respond_to?(:class_name)` in `resolve_authored_override`
#   and in `ancestor_instantiation_type_vars`: every `def` of an indexed snippet has a scope whose self type is a class.
# - `type.respond_to?(:top?) && type.top?.yes?` in `dynamic_top?`: no `Type` class defines `top?` today, so the
#   clause is false for every input; a bug for the coordinator, not changed here (a pure move).
# - `return nil if translated.empty?` in `declared_return_union`: a method with no method type does not exist.
# - `return nil unless defined_on?(override_method, class_name)` in `resolve_authored_override`: an override that only
#   inherits a declaration compares that declaration with its own source, and no rule verdict differs (tried an
#   inherited declaration wider than the grandparent's, and a generic one).
# - `return nil if from.nil?` in `nearest_ancestor_method_def` and the same in `overridden_ancestors_start`'s callers:
#   a class absent from its own chain; the snippet's classes are all on it.
# - `return RBS_ONLY_OWNER unless owner && scope.discovered_classes.key?(...)`: a project class inheriting the
#   declaration of an RBS-only owner (`class Mid < Array`) was tried; the walk ends silent either way.
# - `return false if defined_in.nil?` in `defined_on?`: an RBS method definition always has a declaring class.
# - the `return {} ...` lines of `ancestor_instantiation_type_vars` (`args.nil? || args.empty?`, arity disagreement,
#   `translated.any?(&:nil?)`) and `return nil if definition.nil?` in `ancestor_instantiation_args`: each is covered
#   by the next line or needs a signature the loader rejects (an arity-mismatched `Container[Integer]`).
# - `rescue StandardError` in `safe_instance_method_definition`, in `ancestor_instantiation_args` and around the
#   translate in `ancestor_instantiation_type_vars`: they stand for an RBS build failure, which a signature the loader
#   accepts does not produce (a broken one is rejected before any rule runs).
RSpec.describe Rigor::Analysis::CheckRules::OverrideSupport do
  let(:instance) { Rigor::Type::Combinator }

  def method_def_for(sig, class_name, method_name)
    environment = Rigor::Environment.for_project(signature_paths: [RunnerHelpers.materialise_sig("demo.rbs" => sig)])
    scope = Rigor::Scope.empty(environment: environment)
    [Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope), environment]
  end

  describe "LIFECYCLE_HOOKS" do
    it "lists the four hooks a parent-typed reference never calls, frozen" do
      expect([described_class::LIFECYCLE_HOOKS, described_class::LIFECYCLE_HOOKS.frozen?])
        .to eq([%i[initialize initialize_copy initialize_dup initialize_clone], true])
    end
  end

  describe ".dynamic_top?" do
    it "is true for a Dynamic, and false for a concrete type" do
      expect([instance.untyped, instance.nominal_of("Integer"), instance.constant_of(1)]
        .map { |type| described_class.dynamic_top?(type) }).to eq([true, false, false])
    end
  end

  describe ".declared_return_union" do
    let(:sig) do
      "class Demo[T]\n  def one: () -> Integer\n  def two: () -> Integer | (Integer) -> String\n  " \
        "def gen: () -> T\nend\n"
    end

    it "answers the single return of a one-arm method" do
      method_def, environment = method_def_for(sig, "Demo", :one)

      expect(described_class.declared_return_union(method_def, environment).describe(:short)).to eq("Integer")
    end

    it "unions the returns of an overloaded method" do
      method_def, environment = method_def_for(sig, "Demo", :two)

      expect(described_class.declared_return_union(method_def, environment).describe(:short)).to eq("Integer | String")
    end

    it "translates a type variable at the substitution it is given, and to `untyped` without one" do
      method_def, environment = method_def_for(sig, "Demo", :gen)
      bound = described_class.declared_return_union(method_def, environment,
                                                    type_vars: { T: instance.nominal_of("Integer") })
      unbound = described_class.declared_return_union(method_def, environment)

      expect([bound.describe(:short), described_class.dynamic_top?(unbound)]).to eq(["Integer", true])
    end
  end

  describe ".defined_on?" do
    let(:with_defined_in) { Struct.new(:defined_in) }

    it "is true when the declaration lives on the class itself, whatever the leading `::`" do
      expect([described_class.defined_on?(with_defined_in.new(RBS::TypeName.parse("::Foo")), "Foo"),
              described_class.defined_on?(with_defined_in.new(RBS::TypeName.parse("::Foo")),
                                          "::Foo")]).to eq([true, true])
    end

    it "is false for another class, and for a method with no declaring class" do
      expect([described_class.defined_on?(with_defined_in.new(RBS::TypeName.parse("::Foo")), "Bar"),
              described_class.defined_on?(with_defined_in.new(nil), "Foo")]).to eq([false, false])
    end
  end

  describe "declared_by?" do
    let(:pair) { Struct.new(:defined_in, :implemented_in) }

    def type_name(text) = RBS::TypeName.parse(text)

    it "is true for a declaration on the ancestor's own body" do
      expect(described_class.send(:declared_by?, pair.new(type_name("::Foo"), type_name("::Foo")), "Foo")).to be(true)
    end

    it "is true for an interface the ancestor includes itself, and false for one another class includes" do
      iface = type_name("::_Iface")

      expect([described_class.send(:declared_by?, pair.new(iface, type_name("::Foo")), "Foo"),
              described_class.send(:declared_by?, pair.new(iface, type_name("::Baz")), "Foo")]).to eq([true, false])
    end

    it "is false for a declaration inherited from a class that is not an interface" do
      expect(described_class.send(:declared_by?, pair.new(type_name("::Base"), type_name("::Foo")), "Foo")).to be(false)
    end
  end

  describe "normalize_class_name" do
    it "drops one leading `::` and leaves a plain name, whatever it is given as" do
      expect(%w[::Foo Foo ::A::B].map { |name| described_class.send(:normalize_class_name, name) })
        .to eq(%w[Foo Foo A::B])
    end

    it "reads a Symbol and an RBS name by their text" do
      expect([:Foo, RBS::TypeName.parse("::Foo")].map { |name| described_class.send(:normalize_class_name, name) })
        .to eq(%w[Foo Foo])
    end
  end
end
