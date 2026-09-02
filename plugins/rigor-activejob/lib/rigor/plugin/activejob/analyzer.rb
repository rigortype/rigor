# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Activejob < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for `<JobClass>.perform_later(...)` / `.perform_now(...)` /
      # `.perform(...)` calls and validates each against the {JobIndex}.
      #
      # The plugin recognises a call as job-shaped when the receiver is a `ConstantReadNode` /
      # `ConstantPathNode` whose resolved name appears in the index, and the method name is one of the
      # three ActiveJob entry points.
      module Analyzer
        # Methods that delegate to the job's `#perform`. All three accept the same argument shape —
        # `perform_later` is the most common (queues for later execution), `perform_now` runs
        # synchronously, and `perform` is the bare execution path.
        ENTRY_METHODS = %i[perform_later perform_now perform].freeze

        # One job-call observation. Carries no path/location — the caller (the `node_rule` block)
        # positions it via `Plugin::Base#diagnostic`.
        Violation = Struct.new(:rule, :severity, :message, keyword_init: true)

        module_function

        # The job-call violations for a single call node (0..2), or `[]` when the node is not a
        # `<Job>.perform_*` entry call on a known job. ADR-37: the engine owns the walk.
        #
        # @param call_node [Prism::Node]
        # @param job_index [JobIndex]
        # @return [Array<Violation>]
        def violations_for(call_node:, job_index:)
          return [] unless call_node.is_a?(Prism::CallNode) && entry_call?(call_node)

          class_name = constant_receiver_name(call_node.receiver)
          return [] if class_name.nil?

          # `JobIndex#find` de-roots the query itself (#621) — a `::WelcomeJob.perform_later` receiver and a
          # plain `WelcomeJob.perform_later` reach the same entry with no retry arm here.
          entry = job_index.find(class_name)
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
            rule: "job-call",
            message: "`#{entry.class_name}.#{call_node.name}` matches `#perform` (arity #{entry.arity_label})"
          )
        end

        def arity_violation(call_node, entry)
          actual = (call_node.arguments&.arguments || []).size
          return nil if entry.accepts?(actual)

          Violation.new(
            severity: :error,
            rule: "wrong-arity",
            message: "`#{entry.class_name}.#{call_node.name}` expects #{entry.arity_label} argument(s), got #{actual}"
          )
        end

        # Renders a constant-path receiver as a String. Mirrors the helpers in rigor-activerecord /
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
