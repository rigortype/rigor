# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Sidekiq < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for
      # `<WorkerClass>.perform_async(...)` /
      # `.perform_inline(...)` / `.perform_in(time, ...)` /
      # `.perform_at(time, ...)` calls and validates each
      # against the {WorkerIndex}.
      #
      # Argument-shape rules:
      #
      # - `perform_async` / `perform_inline` — every
      #   argument is forwarded to `#perform`. Validate
      #   `actual == #perform.arity`.
      # - `perform_in(interval, ...args)` /
      #   `perform_at(time, ...args)` — the FIRST argument
      #   is the schedule (a Time / Integer / ActiveSupport
      #   duration); the rest are forwarded to `#perform`.
      #   Validate `actual_args - 1 == #perform.arity`.
      module Analyzer
        # Methods that delegate to `#perform` 1:1.
        DIRECT_ENTRY_METHODS = %i[perform_async perform_inline].freeze

        # Methods whose first argument is a schedule (the
        # remaining args are forwarded to `#perform`).
        SCHEDULED_ENTRY_METHODS = %i[perform_in perform_at].freeze

        ENTRY_METHODS = (DIRECT_ENTRY_METHODS + SCHEDULED_ENTRY_METHODS).freeze

        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @param worker_index [WorkerIndex]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, worker_index:)
          diagnostics = []
          walk(root) do |call_node|
            class_name = constant_receiver_name(call_node.receiver)
            next if class_name.nil?

            entry = worker_index.find(class_name) || worker_index.find("::#{class_name}")
            next if entry.nil?

            diagnostics << info_diagnostic(path, call_node, entry)
            arity_diag = arity_check(path, call_node, entry)
            diagnostics << arity_diag if arity_diag
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
            rule: "worker-call",
            message: "`#{entry.class_name}.#{call_node.name}` matches `#perform` " \
                     "(arity #{entry.arity_label})"
          )
        end

        def arity_check(path, call_node, entry)
          all_args = (call_node.arguments&.arguments || []).size
          # Scheduled entries consume the first arg as the
          # schedule; the rest are forwarded.
          forwarded_count = SCHEDULED_ENTRY_METHODS.include?(call_node.name) ? all_args - 1 : all_args

          if SCHEDULED_ENTRY_METHODS.include?(call_node.name) && all_args.zero?
            return missing_schedule_diagnostic(path, call_node, entry)
          end

          return nil if forwarded_count.negative?
          return nil if entry.accepts?(forwarded_count)

          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "wrong-arity",
            message: "`#{entry.class_name}.#{call_node.name}` expects " \
                     "#{describe_expected(entry, call_node.name)} forwarded to `#perform` " \
                     "(arity #{entry.arity_label}), got #{forwarded_count}"
          )
        end

        def missing_schedule_diagnostic(path, call_node, entry)
          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "missing-schedule",
            message: "`#{entry.class_name}.#{call_node.name}` requires a schedule " \
                     "(time / interval) as its first argument, got 0 arguments"
          )
        end

        def describe_expected(entry, method_name)
          if SCHEDULED_ENTRY_METHODS.include?(method_name)
            "#{entry.arity_label} argument(s) (after the schedule)"
          else
            "#{entry.arity_label} argument(s)"
          end
        end

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
