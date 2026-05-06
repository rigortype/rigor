# frozen_string_literal: true

require "rigor/plugin"

require_relative "lisp_eval/interpreter"

module Rigor
  module Plugin
    # Example plugin: types the return value of `Lisp.eval`
    # calls whose argument is a literal Lisp-style expression
    # tree. Demonstrates the v0.1.0 plugin authoring surface —
    # manifest, services, AST walking, diagnostic emission —
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
    # This plugin only emits diagnostics. It cannot — yet —
    # replace the analyzer's inferred return type for the call
    # site (the plugin contribution surface for return-type
    # narrowing is queued for v0.1.x). The diagnostic that
    # surfaces on every typed call site is therefore the most
    # idiomatic v0.1.0 demonstration of plugin-authored
    # static reasoning over user-defined DSLs.
    class LispEval < Rigor::Plugin::Base
      manifest(
        id: "lisp-eval",
        version: "0.1.0",
        description: "Types the return value of literal `Lisp.eval(...)` calls.",
        config_schema: {
          "module_name" => :string,
          "method_name" => :string,
          "severity" => :string
        }
      )

      DEFAULT_MODULE_NAME = "Lisp"
      DEFAULT_METHOD_NAME = "eval"
      DEFAULT_SEVERITY = :info
      ALLOWED_SEVERITIES = %i[info warning].freeze

      def init(_services)
        @module_name = config.fetch("module_name", DEFAULT_MODULE_NAME)
        @method_name = config.fetch("method_name", DEFAULT_METHOD_NAME).to_sym
        configured_severity = config.fetch("severity", DEFAULT_SEVERITY.to_s).to_sym
        @severity = ALLOWED_SEVERITIES.include?(configured_severity) ? configured_severity : DEFAULT_SEVERITY
        @interpreter = Interpreter.new
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        diagnostics = []
        Walker.each_eval_call(root, module_name: @module_name, method_name: @method_name) do |call_node|
          diagnostic = analyse_call(path, call_node)
          diagnostics << diagnostic if diagnostic
        end
        diagnostics
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
          # Stay silent on call sites whose argument we cannot
          # statically interpret — they are well-formed Ruby
          # that just is not a literal Lisp expression.
          nil
        else
          diagnostic_for_inferred_type(path, call_node, result)
        end
      end

      def first_argument(call_node)
        arguments = call_node.arguments
        return nil if arguments.nil?

        arguments.arguments.first
      end

      def diagnostic_for_inferred_type(path, call_node, type_tag)
        location = call_node.location
        rendered = render_type_tag(type_tag)
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: location.start_line,
          column: location.start_column + 1,
          message: "#{@module_name}.#{@method_name} return type inferred as #{rendered}",
          severity: @severity,
          rule: "inferred-return-type"
        )
      end

      def diagnostic_for_error(path, error)
        location = error.node.location
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: location.start_line,
          column: location.start_column + 1,
          message: error.message,
          severity: :error,
          rule: "type-error"
        )
      end

      def render_type_tag(tag)
        case tag
        when Array
          tag.map { |member| render_type_tag(member) }.join(" | ")
        when :integer then "Integer"
        when :float then "Float"
        when :bool then "bool"
        else tag.inspect
        end
      end

      # AST walker scoped to the configured module / method
      # pair. Public class on the plugin so the integration
      # spec can drive it directly without spinning up an
      # analyser run.
      module Walker
        module_function

        # Yields every `<module_name>.<method_name>(...)` /
        # `<module_name>::<method_name>(...)` call node found
        # under `root`. The receiver match is name-based and
        # tolerates a single optional outer `::` qualifier
        # (`::Lisp.eval(...)`).
        def each_eval_call(root, module_name:, method_name:, &block)
          return enum_for(__method__, root, module_name: module_name, method_name: method_name) unless block

          walk(root) do |node|
            next unless node.is_a?(Prism::CallNode)
            next unless node.name == method_name
            next unless receiver_matches?(node.receiver, module_name)

            yield node
          end
        end

        def walk(node, &)
          return if node.nil?

          yield node
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

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
