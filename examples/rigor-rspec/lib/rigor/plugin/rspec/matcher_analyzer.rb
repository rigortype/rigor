# frozen_string_literal: true

require "prism"
require "rigor/type"
require "rigor/flow_contribution"
require "rigor/flow_contribution/fact"

module Rigor
  module Plugin
    class Rspec < Rigor::Plugin::Base
      # Pillar 2 Slice 1 — recognises `expect(x).to MATCHER`
      # patterns at `flow_contribution_for` time and emits
      # `post_return_facts` that narrow the named local on the
      # post-call edge.
      #
      # The supported matchers are the lowest-false-positive
      # floor of the RSpec matcher DSL:
      #
      # - `be_a(T)` / `be_kind_of(T)` — `x is_a?(T)` style class
      #   membership; narrows `x` to `T`.
      # - `be_instance_of(T)` — exact-class match; narrows
      #   `x` to `T` (the engine currently treats Nominal[T]
      #   uniformly, so the distinction with `be_a` is observed
      #   at the carrier level but not the runtime).
      # - `be_nil` — narrows `x` to `Constant<nil>`.
      # - `eq(LITERAL)` for a literal-value argument — narrows
      #   `x` to `Constant<literal>`.
      #
      # The matchers below this floor (`be_truthy` / `be_falsey`
      # / `be_within` / `be > / < / >=` / `include` / `start_with`
      # / `match(regex)` / `raise_error` / receive-style mocks)
      # require either edge-aware fragments (`truthy_facts` /
      # `falsey_facts` rather than `post_return_facts`) or
      # diagnostic-only enforcement; both are queued for follow-up
      # slices.
      #
      # The analyzer fires ONLY when:
      #
      # 1. The call node is `<recv>.to(matcher)` (RSpec's primary
      #    assertion verb; `not_to` / `to_not` produce a negated
      #    fact path that is also queued for follow-up).
      # 2. The receiver of `.to` is `expect(<local_var>)` —
      #    exactly one positional argument that's a
      #    LocalVariableReadNode. Composite receivers
      #    (`expect(foo.bar)`, `expect { ... }.to raise_error`)
      #    fall through.
      # 3. The matcher is one of the recognised forms above.
      module MatcherAnalyzer
        module_function

        # @param call_node [Prism::CallNode] the call whose
        #   contribution we're computing. Returns nil when the
        #   call shape does not match `expect(local).to matcher`.
        # @param environment [Rigor::Environment, nil] the
        #   surrounding environment used to resolve a matcher's
        #   class-name argument to a `Type::Nominal`. When nil,
        #   class-name resolution falls back to a bare
        #   `Nominal[<name>]` carrier (sound — the receiver
        #   constant may be a user class not in RBS).
        # @return [Rigor::FlowContribution, nil]
        def contribution_for(call_node, environment:)
          return nil unless to_call?(call_node)
          return nil unless call_node.receiver.is_a?(Prism::CallNode)

          expect_call = call_node.receiver
          return nil unless expect_call?(expect_call)

          target_local = expect_first_arg_local(expect_call)
          return nil if target_local.nil?

          matcher = matcher_call(call_node)
          return nil if matcher.nil?

          narrowed_type = narrowed_type_for(matcher, environment: environment)
          return nil if narrowed_type.nil?

          fact = Rigor::FlowContribution::Fact.new(
            target_kind: :local,
            target_name: target_local,
            type: narrowed_type
          )
          Rigor::FlowContribution.new(post_return_facts: [fact])
        end

        def to_call?(node)
          node.is_a?(Prism::CallNode) && node.name == :to &&
            node.arguments&.arguments&.size == 1
        end

        def expect_call?(node)
          node.is_a?(Prism::CallNode) && node.name == :expect &&
            node.receiver.nil? && node.arguments&.arguments&.size == 1
        end

        def expect_first_arg_local(expect_call)
          arg = expect_call.arguments.arguments.first
          return nil unless arg.is_a?(Prism::LocalVariableReadNode)

          arg.name
        end

        def matcher_call(to_call)
          to_call.arguments.arguments.first
        end

        # Translates a recognised matcher CallNode into the
        # narrowed type. Returns nil when the matcher is
        # unrecognised or its argument shape does not match the
        # supported envelope.
        def narrowed_type_for(matcher, environment:)
          return nil unless matcher.is_a?(Prism::CallNode) && matcher.receiver.nil?

          case matcher.name
          when :be_a, :be_kind_of, :be_instance_of
            nominal_type_for_class_arg(matcher, environment: environment)
          when :be_nil
            return nil unless empty_args?(matcher)

            Rigor::Type::Combinator.constant_of(nil)
          when :eq, :eql
            constant_type_for_literal_arg(matcher)
          end
        end

        def nominal_type_for_class_arg(matcher, environment:)
          args = matcher.arguments&.arguments || []
          return nil unless args.size == 1

          class_name = constant_path_name(args.first)
          return nil if class_name.nil?

          if environment
            environment.nominal_for_name(class_name) ||
              Rigor::Type::Combinator.nominal_of(class_name)
          else
            Rigor::Type::Combinator.nominal_of(class_name)
          end
        end

        def constant_type_for_literal_arg(matcher)
          args = matcher.arguments&.arguments || []
          return nil unless args.size == 1

          literal_value = literal_value_for(args.first)
          return nil if literal_value.equal?(NO_LITERAL)

          Rigor::Type::Combinator.constant_of(literal_value)
        end

        NO_LITERAL = Object.new.freeze
        private_constant :NO_LITERAL

        # Returns the Ruby value of a literal-AST argument, or
        # `NO_LITERAL` when the node isn't a recognised literal
        # shape. Recognised forms cover the common `eq(literal)`
        # case: integer, float, true/false/nil, string, symbol.
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

        def empty_args?(matcher)
          args = matcher.arguments&.arguments
          args.nil? || args.empty?
        end

        # Renders a `Prism::ConstantReadNode` /
        # `Prism::ConstantPathNode` chain as a `"Foo::Bar"`
        # String. Returns nil when the node isn't a constant
        # reference.
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
