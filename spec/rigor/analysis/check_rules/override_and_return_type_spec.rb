# frozen_string_literal: true

require "spec_helper"

# The return-type + Liskov-override family of `Analysis::CheckRules` — `def.return-type-mismatch`
# (ADR-8) and the three ADR-35 override rules (`def.override-visibility-reduced`,
# `def.override-return-widened`, `def.override-param-narrowed`), together with the ancestry and
# RBS-signature helpers they share (`body_last_expression`, `declared_return_union`,
# `each_project_ancestor`, `ancestor_class_names`, `resolve_override_ancestor_name`, `defined_on?`,
# `ancestor_instantiation_type_vars`).
#
# Authored from a mutation-recon pass over `check_rules.rb`, which found this the densest surviving
# family in the file: every one of the four diagnostic builders and the whole generic-ancestor
# instantiation path could be mutated without a covering example failing. The examples below are
# therefore written as *observations* — each pins the rule id, the severity, the exact source
# location the builder points at, and the load-bearing message content (the two type names on either
# side of the comparison, and which ancestor was resolved as the parent). Location assertions are
# deliberately exact: all four builders use `Diagnostic.from_name_loc`, so they report at the
# method's NAME span rather than at the `def` keyword, and a silent swap to `from_node` would move
# every column left without changing anything else that is observed.
RSpec.describe "return-type and Liskov override rules", type: :runner do
  def diags_for(result, rule)
    result.diagnostics.select { |d| d.rule == rule }
  end

  describe "def.return-type-mismatch" do
    def return_diags(result)
      diags_for(result, "def.return-type-mismatch")
    end

    let(:demo_sig) do
      { "demo.rbs" => <<~RBS }
        class Demo
          def returns_string: () -> String
          def self.build: () -> String
        end
      RBS
    end

    describe "build_return_type_mismatch_diagnostic" do
      it "reports at the method NAME span, carrying both compared type names" do
        # The builder's `from_name_loc` puts the diagnostic on `returns_string` (column 7 under a
        # two-space indent); `from_node` would report the `def` keyword at column 3 instead.
        result = analyze(<<~RUBY, sig: demo_sig)
          class Demo
            def returns_string
              42
            end
          end
        RUBY
        diag = return_diags(result).first
        expect(diag).not_to be_nil
        expect([diag.line, diag.column]).to eq([2, 7])
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to eq("return-type mismatch on `returns_string': declared String, inferred 42")
      end

      it "keeps its structured `method_name` across the severity re-stamp" do
        # This rule is the re-stamping path: it is authored `:error` and the default `balanced` profile
        # resolves it to `:warning`, so `SeverityStamp.stamp` rebuilds the Diagnostic rather than
        # returning it unchanged. The rebuild used to forward only path/line/column/message/severity/
        # rule/source_family, dropping `method_name` / `receiver_type` / `project_definition_site` — a
        # profile-dependent loss (issue #308, fixed in PR #312). The three override rules below are
        # authored at the severity the profile resolves to and never re-stamp, so they exercise the
        # other arm; this example is the one that covers the rebuild.
        result = analyze(<<~RUBY, sig: demo_sig)
          class Demo
            def returns_string
              42
            end
          end
        RUBY
        expect(return_diags(result).first&.method_name).to eq("returns_string")
      end

      it "reports past `self.` on a singleton def" do
        # `declared_return_type` routes a def with a receiver through
        # `Reflection.singleton_method_definition`; the name span is then `build` alone, so the
        # column clears the `self.` prefix.
        result = analyze(<<~RUBY, sig: demo_sig)
          class Demo
            def self.build
              42
            end
          end
        RUBY
        diag = return_diags(result).first
        expect(diag).not_to be_nil
        expect([diag.line, diag.column]).to eq([2, 12])
        expect(diag.message).to include("on `build'")
      end
    end

    describe "body_last_expression" do
      it "types the LAST statement of a multi-statement body" do
        # The helper takes `body.body.last`; reading the first statement instead would type the
        # conforming `"fine"` here and stay silent.
        result = analyze(<<~RUBY, sig: demo_sig)
          class Demo
            def returns_string
              "fine"
              42
            end
          end
        RUBY
        expect(return_diags(result).first&.message).to include("inferred 42")
      end

      it "ignores a non-final statement that would mismatch" do
        result = analyze(<<~RUBY, sig: demo_sig)
          class Demo
            def returns_string
              42
              "fine"
            end
          end
        RUBY
        expect(return_diags(result)).to be_empty
      end

      it "unwraps a def-level rescue (BeginNode) to reach the implicit return" do
        # Without the `BeginNode` recursion the whole begin node is typed and the rule cannot see
        # the body's last expression at all.
        result = analyze(<<~RUBY, sig: demo_sig)
          class Demo
            def returns_string
              42
            rescue StandardError
              "recovered"
            end
          end
        RUBY
        expect(return_diags(result).first&.message).to include("inferred 42")
      end

      it "types an endless def's bare-expression body" do
        # The `else` arm of the case: the body is neither a StatementsNode nor a BeginNode, and is
        # returned as-is.
        result = analyze(<<~RUBY, sig: { "demo.rbs" => "class Demo\n  def name: () -> String\nend\n" })
          class Demo
            def name = 42
          end
        RUBY
        expect(return_diags(result).first&.message).to include("declared String, inferred 42")
      end
    end

    describe "declared_return_union (overload arms)" do
      let(:overload_sig) do
        { "demo.rbs" => <<~RBS }
          class Demo
            def multi: () -> String
                     | () -> Integer
          end
        RBS
      end

      it "unions every arm, so one satisfying arm silences the rule" do
        # Taking only the first translated arm (`String`) would fire on this Integer body.
        result = analyze(<<~RUBY, sig: overload_sig)
          class Demo
            def multi
              42
            end
          end
        RUBY
        expect(return_diags(result)).to be_empty
      end

      it "describes the declared side as the union when no arm accepts the body" do
        result = analyze(<<~RUBY, sig: overload_sig)
          class Demo
            def multi
              :sym
            end
          end
        RUBY
        expect(return_diags(result).first&.message)
          .to eq("return-type mismatch on `multi': declared Integer | String, inferred :sym")
      end
    end

    describe "declared_return_union (alias-declared returns, issue #529)" do
      # An alias-declared return used to translate to untyped, so the rule was structurally silent on
      # it. With the check side handing the loader to the translator, the declared side compares at the
      # expanded type — the must-fire / must-still-succeed pair below discriminates the wiring.
      let(:alias_sig) do
        { "alias_demo.rbs" => <<~RBS }
          type demo_id = ::Integer

          class AliasDemo
            def id: () -> demo_id
          end
        RBS
      end

      it "fires when the body contradicts the expanded alias" do
        result = analyze(<<~RUBY, sig: alias_sig)
          class AliasDemo
            def id
              "not-an-integer"
            end
          end
        RUBY
        expect(return_diags(result).first&.message)
          .to eq("return-type mismatch on `id': declared Integer, inferred \"not-an-integer\"")
      end

      it "stays silent when the body satisfies the expanded alias" do
        result = analyze(<<~RUBY, sig: alias_sig)
          class AliasDemo
            def id
              42
            end
          end
        RUBY
        expect(return_diags(result)).to be_empty
      end
    end

    describe "compare_return / dynamic_top? (fires only on a proven :no)" do
      it "stays silent when the body types as Dynamic[top]" do
        result = analyze(<<~RUBY, sig: demo_sig)
          class Demo
            def returns_string
              some_unknown_helper
            end
          end
        RUBY
        expect(return_diags(result)).to be_empty
      end

      it "stays silent on a :maybe verdict (a supertype body against a user-class declaration)" do
        # `compare_return` returns a severity only for `result.no?`. A user-only hierarchy orders as
        # `:maybe`, which the FP-discipline envelope keeps silent — promoting `:maybe` to a firing
        # verdict is exactly the regression this watches for.
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Shape
          end

          class Circle < Shape
          end

          class Demo
            def make
              Shape.new
            end
          end
        RUBY
          class Shape
          end

          class Circle < Shape
          end

          class Demo
            def make: () -> Circle
          end
        RBS
        expect(return_diags(result)).to be_empty
      end
    end
  end

  describe "def.override-visibility-reduced" do
    def vis_diags(result)
      diags_for(result, "def.override-visibility-reduced")
    end

    describe "build_override_visibility_diagnostic" do
      it "reports at the overriding def's NAME span, naming both visibilities and the parent" do
        # `from_name_loc` again: the override `def greet` sits on line 10 under a two-space indent,
        # so the name span starts at column 7.
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def greet
              "hello"
            end
          end
        RUBY
        diag = vis_diags(result).first
        expect(diag).not_to be_nil
        expect([diag.line, diag.column]).to eq([10, 7])
        expect(diag.severity).to eq(:warning)
        expect(diag.method_name).to eq("greet")
        expect(diag.message).to eq(
          "visibility of `greet' reduced from public to private (overrides Base#greet); breaks substitutability"
        )
      end
    end

    describe "each_project_ancestor (the transitive walk)" do
      let(:three_level_source) do
        <<~RUBY
          class Base
            def greet
              "hi"
            end
          end

          class Mid < Base
          end

          class Sub < Mid
            private

            def greet
              "hello"
            end
          end
        RUBY
      end

      let(:nearest_wins_source) do
        <<~RUBY
          class Base
            def greet
              "b"
            end
          end

          class Mid < Base
            protected

            def greet
              "m"
            end
          end

          class Sub < Mid
            private

            def greet
              "s"
            end
          end
        RUBY
      end

      it "reaches a grandparent through an intermediate class that defines nothing" do
        # The walk re-enqueues each visited ancestor's own ancestors. Drop that enqueue and the
        # queue holds only `Mid` — which declares no `greet` — so the rule goes silent.
        diag = vis_diags(analyze(three_level_source)).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("overrides Base#greet")
      end

      it "stops at the NEAREST defining ancestor rather than the furthest" do
        # Breadth-first, nearest-first, first-truthy-wins: `Sub`'s parent side must be `Mid`
        # (protected), not the further `Base` (public) — which would also change the reported
        # "reduced from" visibility.
        messages = vis_diags(analyze(nearest_wins_source)).map(&:message)
        expect(messages).to include(a_string_matching(/from protected to private \(overrides Mid#greet\)/))
        expect(messages).to include(a_string_matching(/from public to protected \(overrides Base#greet\)/))
      end

      it "walks a module chain through an ancestor known only by its own includes" do
        # `known_user_class?` admits `Mid` on `discovered_includes` alone (it declares no method and
        # has no superclass); the walk then pushes Mid's includes to reach `Deep`.
        result = analyze(<<~RUBY)
          module Deep
            def greet
              "deep"
            end
          end

          module Mid
            include Deep
          end

          class Host
            include Mid

            private

            def greet
              "host"
            end
          end
        RUBY
        expect(vis_diags(result).first&.message).to include("overrides Deep#greet")
      end
    end

    describe "ancestor_class_names / resolve_override_ancestor_name" do
      it "orders included modules ahead of the superclass" do
        # Both `Mixin` and `Base` define `tag`; the includes are collected first, so the
        # breadth-first walk resolves the module as the parent.
        result = analyze(<<~RUBY)
          module Mixin
            def tag
              "m"
            end
          end

          class Base
            def tag
              "b"
            end
          end

          class Sub < Base
            include Mixin

            private

            def tag
              "s"
            end
          end
        RUBY
        expect(vis_diags(result).first&.message).to include("overrides Mixin#tag")
      end

      it "resolves an as-written ancestor name against the subclass's lexical nesting" do
        # The resolver walks the subclass's namespace segments outward, so the bare `Base` in
        # `class Sub < Base` reports fully qualified as `NS::Base`.
        result = analyze(<<~RUBY)
          module NS
            class Base
              def greet
                "hi"
              end
            end

            class Sub < Base
              private

              def greet
                "hello"
              end
            end
          end
        RUBY
        expect(vis_diags(result).first&.message).to include("overrides NS::Base#greet")
      end
    end
  end

  describe "def.override-return-widened" do
    def widen_diags(result)
      diags_for(result, "def.override-return-widened")
    end

    let(:base_sub_source) do
      <<~RUBY
        class Base
          def value
            1
          end
        end

        class Sub < Base
          def value
            Object.new
          end
        end
      RUBY
    end

    describe "build_override_return_widened_diagnostic" do
      it "reports at the overriding def's NAME span, naming both returns and the parent" do
        result = analyze(base_sub_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def value: () -> Integer
          end

          class Sub < Base
            def value: () -> Object
          end
        RBS
        diag = widen_diags(result).first
        expect(diag).not_to be_nil
        expect([diag.line, diag.column]).to eq([8, 7])
        expect(diag.severity).to eq(:warning)
        expect(diag.method_name).to eq("value")
        expect(diag.message).to eq(
          "return type of `value' widened from Integer to Object (overrides Base#value); breaks substitutability"
        )
      end
    end

    describe "resolve_authored_override / defined_on?" do
      it "stays silent when the override's own class declares no RBS signature" do
        # `Reflection.instance_method_definition("Sub", :value)` still resolves — to the INHERITED
        # `Base#value`. `defined_on?` is the gate that rejects it, so an inference-only override is
        # never compared against the signature it inherits.
        result = analyze(base_sub_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def value: () -> Integer
          end
        RBS
        expect(widen_diags(result)).to be_empty
      end
    end

    # The generic-ancestor path is the one this family had no coverage of at all: nothing drove an
    # override check against an RBS ancestor that is generic, so the whole substitution build could
    # be mutated silently.
    describe "ancestor_instantiation_type_vars (generic RBS ancestor)" do
      let(:container_source) do
        <<~RUBY
          class Container
            def fetch
              1
            end
          end

          class IntContainer < Container
            def fetch
              Object.new
            end
          end
        RUBY
      end

      it "compares the parent contract at the type the subclass binds" do
        # `class IntContainer < Container[Integer]` supplies the instantiation args; the parent's
        # declared type-parameter names are looked up and zipped against them, so the parent's
        # `-> T` is compared as `-> Integer`. With no substitution the bare `T` degrades to
        # `Dynamic[Top]`, which accepts everything and keeps the rule silent.
        result = analyze(container_source, sig: { "demo.rbs" => <<~RBS })
          class Container[T]
            def fetch: () -> T
          end

          class IntContainer < Container[Integer]
            def fetch: () -> Object
          end
        RBS
        diag = widen_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("widened from Integer to Object")
        expect(diag.message).to include("overrides Container#fetch")
      end

      it "zips type-parameter names against instantiation args POSITIONALLY" do
        # `Pair[K, V]` instantiated as `Pair[String, Integer]`, with the method returning `V`. Only
        # a positional, same-order zip binds `V` to `Integer`; any misalignment binds it to
        # `String` and the message says so. This is why the parameter names are asserted through
        # the resulting type name rather than through a count.
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Pair
            def value
              1
            end
          end

          class IntPair < Pair
            def value
              Object.new
            end
          end
        RUBY
          class Pair[K, V]
            def value: () -> V
          end

          class IntPair < Pair[String, Integer]
            def value: () -> Object
          end
        RBS
        expect(widen_diags(result).first&.message).to include("widened from Integer to Object")
      end

      it "degrades to silence when the subclass propagates the type variable instead of binding it" do
        # `class OpenContainer[T] < Container[T]` passes its own unbound `T` through, so the
        # translated arg is itself a variable and the parent return stays `Dynamic[Top]`. This is
        # the FP-safety half of the contract: substitution may only ever add precision.
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Container
            def fetch
              1
            end
          end

          class OpenContainer < Container
            def fetch
              Object.new
            end
          end
        RUBY
          class Container[T]
            def fetch: () -> T
          end

          class OpenContainer[T] < Container[T]
            def fetch: () -> Object
          end
        RBS
        expect(widen_diags(result)).to be_empty
      end
    end
  end

  describe "def.override-param-narrowed" do
    def narrow_diags(result)
      diags_for(result, "def.override-param-narrowed")
    end

    let(:consume_source) do
      <<~RUBY
        class Base
          def consume(value)
          end
        end

        class Sub < Base
          def consume(value)
          end
        end
      RUBY
    end

    describe "build_override_param_narrowed_diagnostic" do
      it "reports at the overriding def's NAME span, naming the 1-based parameter position" do
        result = analyze(consume_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def consume: (Numeric) -> void
          end

          class Sub < Base
            def consume: (Integer) -> void
          end
        RBS
        diag = narrow_diags(result).first
        expect(diag).not_to be_nil
        expect([diag.line, diag.column]).to eq([7, 7])
        expect(diag.severity).to eq(:warning)
        expect(diag.method_name).to eq("consume")
        expect(diag.message).to eq(
          "parameter 1 of `consume' narrowed from Numeric to Integer (overrides Base#consume); " \
          "breaks substitutability"
        )
      end
    end

    describe "generic parent parameters" do
      it "compares a parent parameter at the type the subclass binds" do
        # The same substitution map as the return side, applied to the parameter list: `(T)`
        # instantiated at `Numeric` is what the override's `(Integer)` fails to accept.
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Sink
            def accept(value)
              value
            end
          end

          class NumSink < Sink
            def accept(value)
              value
            end
          end
        RUBY
          class Sink[T]
            def accept: (T) -> void
          end

          class NumSink < Sink[Numeric]
            def accept: (Integer) -> void
          end
        RBS
        expect(narrow_diags(result).first&.message).to include("narrowed from Numeric to Integer")
      end
    end
  end
end
