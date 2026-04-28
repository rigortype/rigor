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
    # Prism::CallNode (routed through Rigor::Inference::MethodDispatcher),
    # Prism::ArgumentsNode (a non-value position whose children are typed
    # individually by the CallNode handler), constant references resolved
    # through Rigor::Environment::ClassRegistry, hash and interpolated
    # string/symbol literals, definition expressions (def/class/module),
    # and explicit handlers for parameter, block, splat, instance/class/
    # global-variable, and self positions. Many of those handlers return
    # Dynamic[Top] silently because they are non-value or out-of-scope
    # positions for Slice 2; later slices refine them in place. Every
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
        # Literals
        Prism::IntegerNode => :type_of_literal_value,
        Prism::FloatNode => :type_of_literal_value,
        Prism::SymbolNode => :symbol_type_for,
        Prism::StringNode => :string_type_for,
        Prism::TrueNode => :type_of_true,
        Prism::FalseNode => :type_of_false,
        Prism::NilNode => :type_of_nil,
        # Locals
        Prism::LocalVariableReadNode => :local_read,
        Prism::LocalVariableWriteNode => :type_of_assignment_write,
        # Containers and pass-throughs
        Prism::ArrayNode => :array_type_for,
        Prism::ParenthesesNode => :parentheses_type_for,
        Prism::StatementsNode => :type_of_statements_node,
        Prism::ProgramNode => :type_of_program,
        # Calls
        Prism::CallNode => :call_type_for,
        Prism::ArgumentsNode => :type_of_non_value,
        # Constants
        Prism::ConstantReadNode => :type_of_constant_read,
        Prism::ConstantPathNode => :type_of_constant_path,
        Prism::ConstantWriteNode => :type_of_assignment_write,
        Prism::ConstantPathWriteNode => :type_of_assignment_write,
        Prism::ConstantOperatorWriteNode => :type_of_assignment_write,
        Prism::ConstantOrWriteNode => :type_of_assignment_write,
        Prism::ConstantAndWriteNode => :type_of_assignment_write,
        Prism::ConstantPathOperatorWriteNode => :type_of_assignment_write,
        Prism::ConstantPathOrWriteNode => :type_of_assignment_write,
        Prism::ConstantPathAndWriteNode => :type_of_assignment_write,
        # Self and instance/class/global variables
        Prism::SelfNode => :type_of_dynamic_top,
        Prism::InstanceVariableReadNode => :type_of_dynamic_top,
        Prism::InstanceVariableWriteNode => :type_of_assignment_write,
        Prism::InstanceVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::InstanceVariableOrWriteNode => :type_of_assignment_write,
        Prism::InstanceVariableAndWriteNode => :type_of_assignment_write,
        Prism::ClassVariableReadNode => :type_of_dynamic_top,
        Prism::ClassVariableWriteNode => :type_of_assignment_write,
        Prism::ClassVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::ClassVariableOrWriteNode => :type_of_assignment_write,
        Prism::ClassVariableAndWriteNode => :type_of_assignment_write,
        Prism::GlobalVariableReadNode => :type_of_dynamic_top,
        Prism::GlobalVariableWriteNode => :type_of_assignment_write,
        Prism::GlobalVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::GlobalVariableOrWriteNode => :type_of_assignment_write,
        Prism::GlobalVariableAndWriteNode => :type_of_assignment_write,
        # Compound writes that share the .value rvalue protocol
        Prism::LocalVariableOperatorWriteNode => :type_of_assignment_write,
        Prism::LocalVariableOrWriteNode => :type_of_assignment_write,
        Prism::LocalVariableAndWriteNode => :type_of_assignment_write,
        Prism::IndexOperatorWriteNode => :type_of_assignment_write,
        Prism::IndexOrWriteNode => :type_of_assignment_write,
        Prism::IndexAndWriteNode => :type_of_assignment_write,
        Prism::MultiWriteNode => :type_of_assignment_write,
        Prism::LocalVariableTargetNode => :type_of_non_value,
        # Hashes and interpolation
        Prism::HashNode => :type_of_hash,
        Prism::KeywordHashNode => :type_of_hash,
        Prism::AssocNode => :type_of_non_value,
        Prism::AssocSplatNode => :type_of_non_value,
        Prism::InterpolatedStringNode => :type_of_interpolated_string,
        Prism::InterpolatedSymbolNode => :type_of_interpolated_symbol,
        Prism::EmbeddedStatementsNode => :type_of_embedded_statements,
        Prism::EmbeddedVariableNode => :type_of_dynamic_top,
        # Definitions
        Prism::DefNode => :type_of_def,
        Prism::ClassNode => :type_of_class_or_module,
        Prism::ModuleNode => :type_of_class_or_module,
        Prism::SingletonClassNode => :type_of_class_or_module,
        Prism::AliasMethodNode => :type_of_nil_value,
        Prism::AliasGlobalVariableNode => :type_of_nil_value,
        Prism::UndefNode => :type_of_nil_value,
        Prism::ForwardingSuperNode => :type_of_dynamic_top,
        Prism::BlockArgumentNode => :type_of_non_value,
        # Parameters and blocks (non-value positions)
        Prism::ParametersNode => :type_of_non_value,
        Prism::RequiredParameterNode => :type_of_non_value,
        Prism::OptionalParameterNode => :type_of_non_value,
        Prism::RequiredKeywordParameterNode => :type_of_non_value,
        Prism::OptionalKeywordParameterNode => :type_of_non_value,
        Prism::KeywordRestParameterNode => :type_of_non_value,
        Prism::RestParameterNode => :type_of_non_value,
        Prism::BlockParameterNode => :type_of_non_value,
        Prism::BlockParametersNode => :type_of_non_value,
        Prism::ForwardingParameterNode => :type_of_non_value,
        Prism::NoKeywordsParameterNode => :type_of_non_value,
        Prism::ImplicitRestNode => :type_of_non_value,
        Prism::BlockNode => :type_of_dynamic_top,
        Prism::SplatNode => :type_of_non_value
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

      # All `*WriteNode` flavours expose a `.value` rvalue child. Their type
      # is the type of that rvalue. Binding the result back into the scope
      # is the responsibility of the statement-level evaluator (Slice 3),
      # never of `type_of` itself.
      def type_of_assignment_write(node)
        type_of(node.value)
      end

      def type_of_statements_node(node)
        statements_type_for(node)
      end

      def type_of_program(node)
        statements_type_for(node.statements)
      end

      # Recognised position that does not produce a value: parameter lists
      # and individual parameter declarations, splats inside argument
      # lists, key-value pairs in hashes, and the implicit-rest token
      # inside destructuring. Returning Dynamic[Top] silently keeps these
      # off the unrecognised list without faking a value type.
      def type_of_non_value(_node)
        dynamic_top
      end

      # Recognised value-bearing position the Slice 2 engine does not yet
      # narrow: self, instance/class/global variable reads, block bodies.
      # Slice 3+ refines these in place; for now we acknowledge the node
      # class so the coverage scanner stops flagging it without recording
      # a fail-soft event for every occurrence.
      def type_of_dynamic_top(_node)
        dynamic_top
      end

      def type_of_constant_read(node)
        nominal = scope.environment.class_registry.nominal_for_name(node.name)
        return nominal if nominal

        fallback_for(node, family: :prism)
      end

      def type_of_constant_path(node)
        full_name = build_constant_path_name(node)
        if full_name
          nominal = scope.environment.class_registry.nominal_for_name(full_name)
          return nominal if nominal
        end

        fallback_for(node, family: :prism)
      end

      # Builds the dotted-colon name for a `Foo`, `Foo::Bar`, or `::Foo`
      # path. Returns nil when an inner segment is not itself a constant
      # reference (for example `expr::Foo`), so the caller can fall back.
      def build_constant_path_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent
          return node.name.to_s if parent.nil?

          parent_name = build_constant_path_name(parent)
          return nil if parent_name.nil?

          "#{parent_name}::#{node.name}"
        end
      end

      def type_of_hash(_node)
        Type::Combinator.nominal_of(Hash)
      end

      def type_of_interpolated_string(_node)
        Type::Combinator.nominal_of(String)
      end

      def type_of_interpolated_symbol(_node)
        Type::Combinator.nominal_of(Symbol)
      end

      def type_of_embedded_statements(node)
        statements_type_for(node.statements)
      end

      def type_of_def(node)
        Type::Combinator.constant_of(node.name)
      end

      # `class Foo; body; end`, `module Foo; body; end`, and `class << x;
      # body; end` evaluate to the value of the body's last expression,
      # or `nil` when the body is empty. We do not track class/module
      # scope yet, so the body is typed in the surrounding scope and
      # that result is returned.
      def type_of_class_or_module(node)
        body = node.body
        return Type::Combinator.constant_of(nil) if body.nil?

        type_of(body)
      end

      # `alias x y`, `alias $x $y`, and `undef foo` all evaluate to nil at
      # runtime; the constant carrier captures that exactly.
      def type_of_nil_value(_node)
        Type::Combinator.constant_of(nil)
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
