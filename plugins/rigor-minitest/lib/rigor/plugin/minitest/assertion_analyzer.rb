# frozen_string_literal: true

require "prism"
require "rigor/type"
require "rigor/flow_contribution"
require "rigor/flow_contribution/fact"

module Rigor
  module Plugin
    class Minitest < Rigor::Plugin::Base
      # Recognises the four shapes of Minitest / Test::Unit assertions and emits a `post_return_fact` that
      # narrows the named local on the post-call edge.
      #
      # ## Recognised call shapes
      #
      # ### (1) Minitest / Test::Unit `assert_*` (positive) ###
      #
      #   assert_kind_of(T, x)        →  narrow x to T
      #   assert_instance_of(T, x)    →  narrow x to T
      #   assert_nil(x)               →  narrow x to Constant<nil>
      #   assert_equal(literal, x)    →  narrow x to Constant<literal>
      #   assert_match(regex, x)      →  narrow x to String
      #
      # ### (2) Minitest / Test::Unit `refute_*` / `assert_not_*` (negative) ###
      #
      #   refute_kind_of(T, x)        →  narrow x AWAY from T
      #   refute_instance_of(T, x)    →  narrow x AWAY from T
      #   refute_nil(x)               →  narrow x AWAY from nil
      #   refute_equal(literal, x)    →  narrow x AWAY from Constant<literal>
      #
      # Test::Unit's `assert_not_nil(x)` / `assert_not_equal(...)` / `assert_not_kind_of(...)` /
      # `assert_not_instance_of(...)` share the recognizer with `refute_*` (they're aliases).
      #
      # ### (3) Minitest/spec `_(x).must_*` (positive) ###
      #
      #   _(x).must_be_kind_of(T)     →  narrow x to T
      #   _(x).must_be_instance_of(T) →  narrow x to T
      #   _(x).must_be_nil            →  narrow x to Constant<nil>
      #   _(x).must_equal(literal)    →  narrow x to Constant<literal>
      #   _(x).must_match(regex)      →  narrow x to String
      #
      # The legacy bare `x.must_be_kind_of(T)` form (Minitest < 6.0 monkey-patched onto Object) is
      # intentionally NOT recognised — the receiver is the value itself rather than a wrapping `_(value)`,
      # so the analyzer has nothing to narrow against. Users who still rely on the legacy form should
      # migrate to `_(x).must_*`.
      #
      # ### (4) Minitest/spec `_(x).wont_*` (negative) ###
      #
      #   _(x).wont_be_kind_of(T)     →  narrow x AWAY from T
      #   _(x).wont_be_nil            →  narrow x AWAY from nil
      #   _(x).wont_equal(literal)    →  narrow x AWAY from Constant<literal>
      #
      # ## Not yet recognised
      #
      # `assert_predicate(x, :foo?)` (custom predicate) / `assert_respond_to(x, :method)` / `assert_includes`
      # / `assert_operator` / `assert_throws` / `assert_raises(T) { ... }` etc. — each either needs a
      # carrier Rigor doesn't model today (predicate-state, respond-to-set) or a multi-edge fact that the
      # `post_return_facts` slot can't express. Queued for follow-up slices.
      module AssertionAnalyzer
        module_function

        # @return [Rigor::FlowContribution, nil]
        def contribution_for(call_node, environment:)
          return nil unless call_node.is_a?(Prism::CallNode)

          fact =
            assert_form_fact(call_node, environment: environment) ||
            spec_form_fact(call_node, environment: environment)
          return nil if fact.nil?

          Rigor::FlowContribution.new(post_return_facts: [fact])
        end

        # --- assert_* / refute_* / assert_not_* form ---

        # Maps each recognised assertion name to a tuple `[shape, negative]`. `shape` is one of:
        #
        # - :class_then_local   — `assert_kind_of(T, x)`, T at args[0], local at args[1].
        # - :nil_local          — `assert_nil(x)`, local at args[0].
        # - :literal_then_local — `assert_equal(literal, x)`, literal at args[0], local at args[1].
        # - :regex_then_local   — `assert_match(regex, x)`, regex at args[0], local at args[1].
        ASSERT_FORM = {
          assert_kind_of: [:class_then_local, false],
          assert_instance_of: [:class_then_local, false],
          refute_kind_of: [:class_then_local, true],
          refute_instance_of: [:class_then_local, true],
          assert_not_kind_of: [:class_then_local, true],
          assert_not_instance_of: [:class_then_local, true],
          assert_nil: [:nil_local, false],
          refute_nil: [:nil_local, true],
          assert_not_nil: [:nil_local, true],
          assert_equal: [:literal_then_local, false],
          refute_equal: [:literal_then_local, true],
          assert_not_equal: [:literal_then_local, true],
          assert_match: [:regex_then_local, false]
        }.freeze
        private_constant :ASSERT_FORM

        def assert_form_fact(call_node, environment:)
          return nil unless call_node.receiver.nil?

          shape_negative = ASSERT_FORM[call_node.name]
          return nil if shape_negative.nil?

          shape, negative = shape_negative
          args = call_node.arguments&.arguments || []
          fact_for_shape(shape, args, negative: negative, environment: environment)
        end

        # --- _(x).must_* / .wont_* form ---

        # Maps the spec-style matcher names to `[shape, negative]`. `shape`:
        # - :class_arg   — `_(x).must_be_kind_of(T)`, T at args[0].
        # - :no_arg_nil  — `_(x).must_be_nil`, no args.
        # - :literal_arg — `_(x).must_equal(literal)`, literal at args[0].
        # - :regex_arg   — `_(x).must_match(regex)`, regex at args[0].
        SPEC_MATCHER_FORM = {
          must_be_kind_of: [:class_arg, false],
          must_be_instance_of: [:class_arg, false],
          must_be_a: [:class_arg, false],
          must_be_an_instance_of: [:class_arg, false],
          wont_be_kind_of: [:class_arg, true],
          wont_be_instance_of: [:class_arg, true],
          must_be_nil: [:no_arg_nil, false],
          wont_be_nil: [:no_arg_nil, true],
          must_equal: [:literal_arg, false],
          wont_equal: [:literal_arg, true],
          must_match: [:regex_arg, false]
        }.freeze
        private_constant :SPEC_MATCHER_FORM

        # ADR-37 slice 2 — the method names this analyzer narrows on, for the plugin's
        # `narrowing_facts methods:` gate.
        SUPPORTED_METHODS = (ASSERT_FORM.keys + SPEC_MATCHER_FORM.keys).freeze

        def spec_form_fact(call_node, environment:)
          shape_negative = SPEC_MATCHER_FORM[call_node.name]
          return nil if shape_negative.nil?

          target_local = spec_receiver_local(call_node)
          return nil if target_local.nil?

          shape, negative = shape_negative
          args = call_node.arguments&.arguments || []
          fact_for_spec_shape(shape, target_local, args, negative: negative, environment: environment)
        end

        # `_(x)` returns a `Minitest::Expectation` wrapping x. Some specs use `value(x)` or `expect(x)`
        # interchangeably (Minitest provides all three as aliases). Recognises the local-variable arg in
        # any of those receiver-call shapes.
        SPEC_WRAPPER_NAMES = %i[_ value expect].freeze
        private_constant :SPEC_WRAPPER_NAMES

        def spec_receiver_local(matcher_call)
          recv = matcher_call.receiver
          return nil unless recv.is_a?(Prism::CallNode)
          return nil unless recv.receiver.nil? && SPEC_WRAPPER_NAMES.include?(recv.name)

          args = recv.arguments&.arguments || []
          return nil unless args.size == 1
          return nil unless args.first.is_a?(Prism::LocalVariableReadNode)

          args.first.name
        end

        # --- shape resolvers ---

        def fact_for_shape(shape, args, negative:, environment:)
          case shape
          when :class_then_local
            return nil unless args.size == 2
            return nil unless args[1].is_a?(Prism::LocalVariableReadNode)

            type = nominal_type_for(args[0], environment: environment)
            fact_for(args[1].name, type, negative: negative)
          when :nil_local
            return nil unless args.size == 1
            return nil unless args[0].is_a?(Prism::LocalVariableReadNode)

            fact_for(args[0].name, Rigor::Type::Combinator.constant_of(nil), negative: negative)
          when :literal_then_local
            return nil unless args.size == 2
            return nil unless args[1].is_a?(Prism::LocalVariableReadNode)

            literal = literal_value_for(args[0])
            return nil if literal.equal?(NO_LITERAL)

            fact_for(args[1].name, Rigor::Type::Combinator.constant_of(literal), negative: negative)
          when :regex_then_local
            return nil unless args.size == 2
            return nil unless args[1].is_a?(Prism::LocalVariableReadNode)
            return nil unless regex_literal?(args[0])

            fact_for(args[1].name, Rigor::Type::Combinator.nominal_of("String"), negative: negative)
          end
        end

        def fact_for_spec_shape(shape, target_local, args, negative:, environment:)
          case shape
          when :class_arg
            return nil unless args.size == 1

            type = nominal_type_for(args[0], environment: environment)
            fact_for(target_local, type, negative: negative)
          when :no_arg_nil
            return nil unless args.empty?

            fact_for(target_local, Rigor::Type::Combinator.constant_of(nil), negative: negative)
          when :literal_arg
            return nil unless args.size == 1

            literal = literal_value_for(args[0])
            return nil if literal.equal?(NO_LITERAL)

            fact_for(target_local, Rigor::Type::Combinator.constant_of(literal), negative: negative)
          when :regex_arg
            return nil unless args.size == 1
            return nil unless regex_literal?(args[0])

            fact_for(target_local, Rigor::Type::Combinator.nominal_of("String"), negative: negative)
          end
        end

        def fact_for(local_name, type, negative:)
          return nil if type.nil?

          Rigor::FlowContribution::Fact.new(
            target_kind: :local,
            target_name: local_name,
            type: type,
            negative: negative
          )
        end

        # --- helpers shared with rigor-rspec MatcherAnalyzer ---

        def nominal_type_for(node, environment:)
          class_name = constant_path_name(node)
          return nil if class_name.nil?

          if environment
            environment.nominal_for_name(class_name) ||
              Rigor::Type::Combinator.nominal_of(class_name)
          else
            Rigor::Type::Combinator.nominal_of(class_name)
          end
        end

        NO_LITERAL = Object.new.freeze
        private_constant :NO_LITERAL

        def literal_value_for(node)
          case node
          when Prism::IntegerNode then node.value
          when Prism::FloatNode then node.value
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          when Prism::NilNode then nil
          when Prism::StringNode then node.unescaped
          when Prism::SymbolNode then node.unescaped.to_sym
          else NO_LITERAL
          end
        end

        def regex_literal?(node)
          node.is_a?(Prism::RegularExpressionNode) ||
            node.is_a?(Prism::InterpolatedRegularExpressionNode)
        end

        def constant_path_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end
      end
    end
  end
end
