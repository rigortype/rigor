# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../ast"

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
    # shallow Array literals, and Rigor::AST::TypeNode. Every other node
    # falls back to Dynamic[Top] per the fail-soft policy in
    # docs/internal-spec/inference-engine.md.
    class ExpressionTyper
      def initialize(scope:)
        @scope = scope
      end

      def type_of(node)
        return type_of_virtual(node) if node.is_a?(AST::Node)

        case node
        when Prism::IntegerNode then Type::Combinator.constant_of(node.value)
        when Prism::FloatNode then Type::Combinator.constant_of(node.value)
        when Prism::SymbolNode then symbol_type_for(node)
        when Prism::StringNode then string_type_for(node)
        when Prism::TrueNode then Type::Combinator.constant_of(true)
        when Prism::FalseNode then Type::Combinator.constant_of(false)
        when Prism::NilNode then Type::Combinator.constant_of(nil)
        when Prism::LocalVariableReadNode then local_read(node)
        when Prism::LocalVariableWriteNode then type_of(node.value)
        when Prism::ArrayNode then array_type_for(node)
        when Prism::ParenthesesNode then parentheses_type_for(node)
        when Prism::StatementsNode then statements_type_for(node)
        when Prism::ProgramNode then statements_type_for(node.statements)
        else
          dynamic_top
        end
      end

      private

      attr_reader :scope

      def dynamic_top
        Type::Combinator.untyped
      end

      def type_of_virtual(node)
        case node
        when AST::TypeNode then node.type
        else
          dynamic_top
        end
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
    end
  end
end
