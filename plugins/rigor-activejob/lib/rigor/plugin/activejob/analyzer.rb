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

        # Ruby binds a trailing `k: v` / `**opts` group to keyword parameters, never to positional ones, so
        # when `#perform` takes keywords the group is not counted (the message's "got N" is then the
        # positional count too). A job without keyword parameters keeps counting the group as one positional
        # argument — `NoArgsJob.perform_later(name: 1)` raises at runtime. A `Hash` literal / local stays
        # positional either way (Ruby 3 does not convert it).
        #
        # The call is declined (no report) when its shape is unknown: a `*splat` or `...` argument may supply
        # any number of positionals (or a trailing keyword group), and a keyword group made only of `**opts`
        # arguments sent to a job without keywords may be empty — declined only when the verdict differs
        # between "empty" and "one positional hash" (`NoArgsJob.perform_later(**opts)`).
        def arity_violation(call_node, entry)
          args = call_node.arguments&.arguments || []
          return nil if args.any? { |arg| arg.is_a?(Prism::SplatNode) || arg.is_a?(Prism::ForwardingArgumentsNode) }

          keyword_group = args.last.is_a?(Prism::KeywordHashNode) ? args.last : nil
          return nil if keyword_group && !entry.accepts_keywords && empty_group_decides?(args, keyword_group, entry)

          actual = entry.accepts_keywords && keyword_group ? args.size - 1 : args.size
          return nil if entry.accepts?(actual)

          Violation.new(
            severity: :error,
            rule: "wrong-arity",
            message: "`#{entry.class_name}.#{call_node.name}` expects #{entry.arity_label} argument(s), got #{actual}"
          )
        end

        # True when the group is only `**splat` arguments (so it may be empty) AND the entry's verdict changes
        # between counting it and not counting it.
        def empty_group_decides?(args, keyword_group, entry)
          return false unless keyword_group.elements.all?(Prism::AssocSplatNode)

          entry.accepts?(args.size - 1) != entry.accepts?(args.size)
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
