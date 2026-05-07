# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Units < Rigor::Plugin::Base
      # Walks a single Ruby file, evaluates every expression
      # against the {MethodTable} dispatch surface, and tracks
      # local-variable bindings so dimensions flow through
      # subsequent reads.
      #
      # The walker is intentionally simple — no path-sensitive
      # branching, no method-body scoping — because the demo's
      # value is "what the plugin sees at the top level". An
      # `if` / `else` body is recursed into for diagnostics, but
      # any binding it writes is global to the analyser; there
      # is no scope stack. That keeps the example small without
      # surprising users with partial control-flow precision.
      class Analyzer
        DIMENSIONS = %i[distance time speed acceleration].freeze

        attr_reader :diagnostics

        def initialize(path:)
          @path = path
          @bindings = {}
          @diagnostics = []
        end

        def analyze(root)
          evaluate(root)
          self
        end

        private

        # Returns the dimension Symbol for a node, or `nil` when
        # the analyzer cannot — or chooses not to — type it.
        # Recursing down a tree always uses `evaluate`; the
        # diagnostics each node owns fire as a side-effect of
        # evaluating it, exactly once per node.
        def evaluate(node)
          return nil if node.nil?

          case node
          when Prism::IntegerNode, Prism::FloatNode then :numeric
          when Prism::TrueNode, Prism::FalseNode then :bool
          when Prism::StringNode, Prism::InterpolatedStringNode then :string
          when Prism::SymbolNode then :symbol
          when Prism::LocalVariableReadNode then @bindings[node.name]
          when Prism::LocalVariableWriteNode then evaluate_local_write(node)
          when Prism::ParenthesesNode then evaluate(node.body)
          when Prism::StatementsNode then evaluate_statements(node)
          when Prism::CallNode then evaluate_call(node)
          else
            node.compact_child_nodes.each { |child| evaluate(child) }
            nil
          end
        end

        def evaluate_local_write(node)
          dimension = evaluate(node.value)
          @bindings[node.name] = dimension
          if DIMENSIONS.include?(dimension)
            emit_info(
              node, "local `#{node.name}` inferred as #{MethodTable.label(dimension)}",
              rule: "inferred-binding"
            )
          end
          dimension
        end

        def evaluate_statements(node)
          last = nil
          node.compact_child_nodes.each { |child| last = evaluate(child) }
          last
        end

        def evaluate_call(node)
          receiver_dim = evaluate(node.receiver)
          arg_dims = call_argument_dimensions(node)

          dispatch = MethodTable.dispatch(receiver: receiver_dim, method: node.name, args: arg_dims)
          return nil if dispatch.nil?

          if dispatch.error
            emit_error(node, dispatch.error, rule: rule_for_method(node.name))
            return nil
          end

          if in_query?(node.name) && dispatch.dimension == :float
            emit_info(
              node,
              "`#{render_call(node)}` returns Float (#{MethodTable.label(receiver_dim)} → " \
              "#{node.name.to_s.delete_prefix('in_').tr('_', ' ')})",
              rule: "in-method-result"
            )
          end

          dispatch.dimension
        end

        def call_argument_dimensions(node)
          return [] if node.arguments.nil?

          node.arguments.arguments.map { |arg| evaluate(arg) }
        end

        def in_query?(method)
          method.to_s.start_with?("in_")
        end

        def rule_for_method(method)
          if in_query?(method)
            "in-method-mismatch"
          else
            "dimension-mismatch"
          end
        end

        def render_call(node)
          if node.receiver
            "#{render_receiver(node.receiver)}.#{node.name}"
          else
            node.name.to_s
          end
        end

        def render_receiver(node)
          case node
          when Prism::LocalVariableReadNode then node.name.to_s
          when Prism::IntegerNode, Prism::FloatNode then node.slice
          when Prism::CallNode
            base = render_call(node)
            node.arguments ? "#{base}(...)" : base
          else
            "<...>"
          end
        end

        def emit_info(node, message, rule:)
          push_diagnostic(node, severity: :info, message: message, rule: rule)
        end

        def emit_error(node, message, rule:)
          push_diagnostic(node, severity: :error, message: message, rule: rule)
        end

        def push_diagnostic(node, severity:, message:, rule:)
          location = node.location
          @diagnostics << Rigor::Analysis::Diagnostic.new(
            path: @path,
            line: location.start_line,
            column: location.start_column + 1,
            message: message,
            severity: severity,
            rule: rule
          )
        end
      end
    end
  end
end
