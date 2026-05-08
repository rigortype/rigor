# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Activejob < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for
      # `<JobClass>.perform_later(...)` /
      # `.perform_now(...)` / `.perform(...)` calls and
      # validates each against the {JobIndex}.
      #
      # The plugin recognises a call as job-shaped when the
      # receiver is a `ConstantReadNode` / `ConstantPathNode`
      # whose resolved name appears in the index, and the
      # method name is one of the three ActiveJob entry
      # points.
      module Analyzer
        # Methods that delegate to the job's `#perform`. All
        # three accept the same argument shape — `perform_later`
        # is the most common (queues for later execution),
        # `perform_now` runs synchronously, and `perform` is
        # the bare execution path.
        ENTRY_METHODS = %i[perform_later perform_now perform].freeze

        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @param job_index [JobIndex]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, job_index:)
          diagnostics = []
          walk(root) do |call_node|
            class_name = constant_receiver_name(call_node.receiver)
            next if class_name.nil?

            entry = job_index.find(class_name) || job_index.find("::#{class_name}")
            next if entry.nil?

            diagnostics << info_diagnostic(path, call_node, entry)
            arity = arity_check(path, call_node, entry)
            diagnostics << arity if arity
          end
          diagnostics
        end

        def walk(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode) && entry_call?(node)
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        def entry_call?(node)
          ENTRY_METHODS.include?(node.name) &&
            (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode))
        end

        def info_diagnostic(path, call_node, entry)
          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :info,
            rule: "job-call",
            message: "`#{entry.class_name}.#{call_node.name}` matches `#perform` (arity #{entry.arity_label})"
          )
        end

        def arity_check(path, call_node, entry)
          actual = (call_node.arguments&.arguments || []).size
          return nil if entry.accepts?(actual)

          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "wrong-arity",
            message: "`#{entry.class_name}.#{call_node.name}` expects #{entry.arity_label} argument(s), got #{actual}"
          )
        end

        # Renders a constant-path receiver as a String.
        # Mirrors the helpers in rigor-activerecord /
        # rigor-rails-routes for parity.
        def constant_receiver_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name(node)
          end
        end

        def constant_path_name(node)
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
