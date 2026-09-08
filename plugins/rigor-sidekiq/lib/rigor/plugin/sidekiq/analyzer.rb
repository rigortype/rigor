# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Sidekiq < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for `<WorkerClass>.perform_async(...)` / `.perform_inline(...)` /
      # `.perform_in(time, ...)` / `.perform_at(time, ...)` calls and validates each against the
      # {WorkerIndex}.
      #
      # Argument-shape rules:
      #
      # - `perform_async` / `perform_inline` — every argument is forwarded to `#perform`. Validate `actual
      #   == #perform.arity`.
      # - `perform_in(interval, ...args)` / `perform_at(time, ...args)` — the FIRST argument is the
      #   schedule (a Time / Integer / ActiveSupport duration); the rest are forwarded to `#perform`.
      #   Validate `actual_args - 1 == #perform.arity`.
      module Analyzer
        # Methods that delegate to `#perform` 1:1.
        DIRECT_ENTRY_METHODS = %i[perform_async perform_inline].freeze

        # Methods whose first argument is a schedule (the remaining args are forwarded to `#perform`).
        SCHEDULED_ENTRY_METHODS = %i[perform_in perform_at].freeze

        ENTRY_METHODS = (DIRECT_ENTRY_METHODS + SCHEDULED_ENTRY_METHODS).freeze

        # One worker-call observation: the kebab-case `rule`, `severity`, and human-readable `message`.
        # Carries no path/location — the caller (the `node_rule` block) positions it via
        # `Plugin::Base#diagnostic`.
        Violation = Struct.new(:rule, :severity, :message, keyword_init: true)

        module_function

        # The worker-call violations for a single call node (0..2), or `[]` when the node is not a
        # `<Worker>.perform_*` entry call on a known worker. ADR-37: the engine owns the walk.
        def violations_for(call_node:, worker_index:)
          return [] unless call_node.is_a?(Prism::CallNode) && entry_call?(call_node)

          class_name = constant_receiver_name(call_node.receiver)
          return [] if class_name.nil?

          # `WorkerIndex#find` de-roots the query itself (#621) — a `::WelcomeWorker.perform_async` receiver
          # and a plain `WelcomeWorker.perform_async` reach the same entry with no retry arm here.
          entry = worker_index.find(class_name)
          return [] if entry.nil?

          violations = [info_violation(call_node, entry)]
          arity = arity_violation(call_node, entry)
          violations << arity if arity
          violations
        end

        def entry_call?(node)
          ENTRY_METHODS.include?(node.name) &&
            (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode))
        end

        def info_violation(call_node, entry)
          Violation.new(
            severity: :info,
            rule: "worker-call",
            message: "`#{entry.class_name}.#{call_node.name}` matches `#perform` " \
                     "(arity #{entry.arity_label})"
          )
        end

        def arity_violation(call_node, entry)
          all_args = (call_node.arguments&.arguments || []).size
          # Scheduled entries consume the first arg as the schedule; the rest are forwarded.
          forwarded_count = SCHEDULED_ENTRY_METHODS.include?(call_node.name) ? all_args - 1 : all_args

          if SCHEDULED_ENTRY_METHODS.include?(call_node.name) && all_args.zero?
            return missing_schedule_violation(call_node, entry)
          end

          return nil if forwarded_count.negative?
          return nil if entry.accepts?(forwarded_count)

          Violation.new(
            severity: :error,
            rule: "wrong-arity",
            message: "`#{entry.class_name}.#{call_node.name}` expects " \
                     "#{describe_expected(entry, call_node.name)} forwarded to `#perform` " \
                     "(arity #{entry.arity_label}), got #{forwarded_count}"
          )
        end

        def missing_schedule_violation(call_node, entry)
          Violation.new(
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
