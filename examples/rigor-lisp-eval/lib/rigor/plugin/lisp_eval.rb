# frozen_string_literal: true

require "rigor/plugin"

require_relative "lisp_eval/interpreter"

module Rigor
  module Plugin
    # Example plugin: types the return value of `Lisp.eval` calls whose argument is a literal Lisp-style expression
    # tree. Demonstrates the v0.1.0 plugin authoring surface — manifest, services, AST walking, diagnostic emission —
    # without depending on any private analyzer internals.
    #
    # Usage in `.rigor.yml`:
    #
    #   plugins:
    #     - rigor-lisp-eval
    #
    # Optional configuration:
    #
    #   plugins:
    #     - gem: rigor-lisp-eval
    #       config:
    #         module_name: "Lisp"   # default; the namespace whose `eval` is typed
    #         method_name: "eval"   # default
    #         severity: "info"      # info|warning — severity for the inferred-type note
    #
    # This plugin emits an `:info` diagnostic AND contributes a precise return type at the call site via
    # `dynamic_return` (ADR-52 slice 4). The diagnostic serves as a user-facing trace per the README's "info-diagnostic"
    # pattern; the same Interpreter walk feeds both channels.
    class LispEval < Rigor::Plugin::Base
      manifest(
        id: "lisp-eval",
        version: "0.1.0",
        description: "Types the return value of literal `Lisp.eval(...)` calls.",
        config_schema: {
          "module_name" => { kind: :string, default: "Lisp" },
          "method_name" => { kind: :string, default: "eval" },
          "severity" => { kind: :string, default: "info" }
        }
      )

      # Only the severity fallback needs a constant now — ADR-40 merges the `module_name` / `method_name` / `severity`
      # defaults from the manifest, but `severity` is additionally allow-list-validated, so a bad value falls back here
      # rather than to the merged default.
      DEFAULT_SEVERITY = :info
      ALLOWED_SEVERITIES = %i[info warning].freeze

      def init(_services)
        @module_name = config["module_name"]
        @method_name = config["method_name"].to_sym
        configured_severity = config["severity"].to_sym
        @severity = ALLOWED_SEVERITIES.include?(configured_severity) ? configured_severity : DEFAULT_SEVERITY
        @interpreter = Interpreter.new
      end

      # ADR-37 — per-call trace over the engine-owned walk. `eval_call?` (receiver + method-name match) is the gate the
      # old hand-rolled walker applied, so the plugin no longer ships its own traversal; the `Walker` retains only the
      # receiver-matching helper that this gate and `#dynamic_return` block share.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless eval_call?(node)

        found = analyse_call(path, node)
        found ? [found] : []
      end

      # ADR-52 slice 4 — return-type contribution via the compiled dispatch DSL. The `methods:` callable resolves after
      # `#init` so `@method_name` is available. The block re-checks `eval_call?` for the AST receiver guard, then
      # delegates to the Interpreter; the engine wraps the bare `Rigor::Type` return in a `FlowContribution`
      # automatically.
      dynamic_return methods: -> { [@method_name] } do |call_node, _scope|
        next nil unless eval_call?(call_node)

        argument = first_argument(call_node)
        next nil if argument.nil?

        result = @interpreter.evaluate(argument)
        next nil if result.is_a?(Interpreter::TypeError) || result.is_a?(Interpreter::UnknownExpression)

        return_type = type_for_result(result)
        next nil if return_type.nil?

        return_type
      end

      private

      def analyse_call(path, call_node)
        argument = first_argument(call_node)
        return nil if argument.nil?

        result = @interpreter.evaluate(argument)
        case result
        when Interpreter::TypeError
          diagnostic_for_error(path, result)
        when Interpreter::UnknownExpression
          # Stay silent on call sites whose argument we cannot statically interpret — they are well-formed Ruby that
          # just is not a literal Lisp expression.
          nil
        else
          diagnostic_for_inferred_type(path, call_node, result)
        end
      end

      def eval_call?(call_node)
        return false unless call_node.is_a?(Prism::CallNode)
        return false unless call_node.name == @method_name

        Walker.receiver_matches?(call_node.receiver, @module_name)
      end

      def type_for_result(result)
        case result
        when Array
          members = result.filter_map { |r| type_for_result(r) }
          return nil if members.empty?

          Rigor::Type::Combinator.union(*members)
        when Interpreter::Result
          if result.value
            Rigor::Type::Combinator.constant_of(result.value)
          else
            tag_to_nominal(result.tag)
          end
        end
      end

      def tag_to_nominal(tag)
        case tag
        when Interpreter::INTEGER then Rigor::Type::Combinator.nominal_of("Integer")
        when Interpreter::FLOAT then Rigor::Type::Combinator.nominal_of("Float")
        when Interpreter::BOOL
          Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.constant_of(true),
            Rigor::Type::Combinator.constant_of(false)
          )
        end
      end

      def first_argument(call_node)
        arguments = call_node.arguments
        return nil if arguments.nil?

        arguments.arguments.first
      end

      def diagnostic_for_inferred_type(path, call_node, result)
        diagnostic(
          call_node, path: path,
                     message: "#{@module_name}.#{@method_name} return type inferred as #{render_result(result)}",
                     severity: @severity,
                     rule: "inferred-return-type"
        )
      end

      def diagnostic_for_error(path, error)
        diagnostic(
          error.node, path: path,
                      message: error.message,
                      severity: :error,
                      rule: "type-error"
        )
      end

      def render_result(result)
        case result
        when Array
          result.map { |member| render_result(member) }.join(" | ")
        when Interpreter::Result
          if result.value
            "Constant<#{result.value.inspect}>"
          else
            render_tag(result.tag)
          end
        else result.inspect
        end
      end

      def render_tag(tag)
        case tag
        when :integer then "Integer"
        when :float then "Float"
        when :bool then "bool"
        else tag.inspect
        end
      end

      # Receiver-matching helper shared by `#eval_call?` and the `dynamic_return` block. The AST walk itself is
      # engine-owned via `node_rule`; Walker holds only the receiver-comparison logic so the integration spec can
      # exercise it directly.
      module Walker
        module_function

        def receiver_matches?(receiver, module_name)
          case receiver
          when Prism::ConstantReadNode
            receiver.name.to_s == module_name
          when Prism::ConstantPathNode
            [module_name, "::#{module_name}"].include?(constant_path_name(receiver))
          else
            false
          end
        end

        def constant_path_name(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          joined = parts.join("::")
          if current.nil?
            "::#{joined}"
          elsif current.is_a?(Prism::ConstantReadNode)
            "#{current.name}::#{joined}"
          else
            joined
          end
        end
      end
    end

    Rigor::Plugin.register(LispEval)
  end
end
