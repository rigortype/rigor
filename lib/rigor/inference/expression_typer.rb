# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../ast"
require_relative "fallback"
require_relative "method_dispatcher"

module Rigor
  module Inference
    # Translates AST nodes into Rigor::Type values, consulting the surrounding
    # Rigor::Scope for local-variable bindings and the environment registry
    # for nominal-type resolution. Pure: never mutates the receiver scope.
    #
    # Accepts both real Prism nodes and synthetic Rigor::AST::Node
    # instances; the synthetic family lets callers and plugins ask
    # "what would the analyzer infer if a value of type T appeared here?"
    # without building a real Prism expression.
    #
    # Slice 1 recognises literal expressions, local-variable reads/writes,
    # shallow Array literals, and Rigor::AST::TypeNode. Slice 2 adds
    # Prism::CallNode (routed through Rigor::Inference::MethodDispatcher)
    # and Prism::ArgumentsNode (recognised as a non-value position whose
    # children are typed individually by the CallNode handler). Every
    # other node falls back to Dynamic[Top] per the fail-soft policy in
    # docs/internal-spec/inference-engine.md. The optional tracer is a
    # Rigor::Inference::FallbackTracer (or any object answering
    # #record_fallback) that receives a Fallback event for each fallback;
    # the tracer MUST NOT change the return value of type_of.
    # rubocop:disable Metrics/ClassLength
    class ExpressionTyper
      # Hash-based dispatch keeps `type_of` linear and lets future slices add
      # node kinds without growing a single case statement past RuboCop's
      # cyclomatic budget. Anonymous Prism subclasses are not expected.
      PRISM_DISPATCH = {
        Prism::IntegerNode => :type_of_literal_value,
        Prism::FloatNode => :type_of_literal_value,
        Prism::SymbolNode => :symbol_type_for,
        Prism::StringNode => :string_type_for,
        Prism::TrueNode => :type_of_true,
        Prism::FalseNode => :type_of_false,
        Prism::NilNode => :type_of_nil,
        Prism::LocalVariableReadNode => :local_read,
        Prism::LocalVariableWriteNode => :type_of_local_write,
        Prism::ArrayNode => :array_type_for,
        Prism::ParenthesesNode => :parentheses_type_for,
        Prism::StatementsNode => :type_of_statements_node,
        Prism::ProgramNode => :type_of_program,
        Prism::CallNode => :call_type_for,
        Prism::ArgumentsNode => :type_of_arguments
      }.freeze
      private_constant :PRISM_DISPATCH

      def initialize(scope:, tracer: nil)
        @scope = scope
        @tracer = tracer
      end

      def type_of(node)
        return type_of_virtual(node) if node.is_a?(AST::Node)

        handler = PRISM_DISPATCH[node.class]
        return send(handler, node) if handler

        fallback_for(node, family: :prism)
      end

      private

      attr_reader :scope, :tracer

      def dynamic_top
        Type::Combinator.untyped
      end

      def type_of_literal_value(node)
        Type::Combinator.constant_of(node.value)
      end

      def type_of_true(_node)
        Type::Combinator.constant_of(true)
      end

      def type_of_false(_node)
        Type::Combinator.constant_of(false)
      end

      def type_of_nil(_node)
        Type::Combinator.constant_of(nil)
      end

      def type_of_local_write(node)
        type_of(node.value)
      end

      def type_of_statements_node(node)
        statements_type_for(node)
      end

      def type_of_program(node)
        statements_type_for(node.statements)
      end

      def type_of_arguments(_node)
        dynamic_top
      end

      def type_of_virtual(node)
        case node
        when AST::TypeNode then node.type
        else
          fallback_for(node, family: :virtual)
        end
      end

      def fallback_for(node, family:)
        inner = dynamic_top
        record_fallback(node, family: family, inner_type: inner)
        inner
      end

      def record_fallback(node, family:, inner_type:)
        return unless tracer

        location = node.respond_to?(:location) ? node.location : nil
        event = Fallback.new(
          node_class: node.class,
          location: location,
          family: family,
          inner_type: inner_type
        )
        tracer.record_fallback(event)
      end

      def symbol_type_for(node)
        raw = node.value
        return Type::Combinator.nominal_of(Symbol) if raw.nil?

        Type::Combinator.constant_of(raw.to_sym)
      end

      def string_type_for(node)
        unescaped = node.unescaped
        return Type::Combinator.nominal_of(String) if unescaped.nil?

        Type::Combinator.constant_of(unescaped)
      end

      def local_read(node)
        scope.local(node.name) || dynamic_top
      end

      def array_type_for(node)
        elements = node.elements
        return empty_array_type if elements.empty?

        element_types = elements.map { |e| type_of(e) }
        element_union = Type::Combinator.union(*element_types)
        array_of(element_union)
      end

      def empty_array_type
        array_of(Type::Combinator.bot)
      end

      # Slice 1 represents Array literals as Array (the bare nominal)
      # without preserving element-type or tuple precision. Tuple inference
      # and Array[T] generic carriage land in Slice 4 alongside the
      # Tuple/HashShape/Record dedicated classes.
      def array_of(_element_type)
        Type::Combinator.nominal_of(Array)
      end

      def parentheses_type_for(node)
        body = node.body
        return Type::Combinator.constant_of(nil) if body.nil?

        type_of(body)
      end

      def statements_type_for(statements_node)
        return Type::Combinator.constant_of(nil) if statements_node.nil?

        body = statements_node.body
        return Type::Combinator.constant_of(nil) if body.empty?

        type_of(body.last)
      end

      # Slice 2 routes call expressions through `MethodDispatcher`. The
      # receiver and every argument are typed first, then the dispatcher is
      # asked for a result type. A nil result triggers the fail-soft fallback
      # for the CallNode itself (the inner type_of calls already record
      # their own fallbacks for unrecognised receivers/args, so the tracer
      # captures both the immediate dispatch miss and the deeper cause).
      def call_type_for(node)
        receiver = node.receiver ? type_of(node.receiver) : nil
        arg_types = call_arg_types(node)

        result = MethodDispatcher.dispatch(
          receiver_type: receiver,
          method_name: node.name,
          arg_types: arg_types
        )
        return result if result

        fallback_for(node, family: :prism)
      end

      def call_arg_types(node)
        arguments_node = node.arguments
        return [] if arguments_node.nil?

        arguments_node.arguments.map { |argument| type_of(argument) }
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
