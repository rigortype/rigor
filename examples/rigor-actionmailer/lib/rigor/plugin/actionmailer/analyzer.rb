# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Actionmailer < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for
      # `<MailerClass>.<action>(...)` calls and validates
      # each against the {MailerIndex}. Recognises both:
      #
      # - `UserMailer.welcome(user)` — direct action call
      #   (the call returns a `Mail::Message` ready for
      #   `.deliver_now` / `.deliver_later`).
      # - `UserMailer.with(user: u).welcome` — parametrized
      #   action call. The `.with(...)` call is treated as a
      #   pass-through; the action's argument shape is
      #   validated on the trailing `.welcome` invocation
      #   even though the receiver is a method-call chain
      #   rather than a constant.
      #
      # The analyzer is purely syntactic: it does not look
      # at runtime mailer state. Constants that don't appear
      # in the index are silently ignored — the rule has no
      # opinion on non-mailer call shapes.
      module Analyzer
        # `.with(...)` is recognised as a forwarding step:
        # the receiver of `.with(...)` is the mailer class,
        # so the trailing action-method call's class context
        # is the same.
        WITH_METHODS = %i[with].freeze

        # Ruby method names that ActionMailer reserves on the
        # class itself. We don't validate against these as
        # actions even if a mailer happens to override them
        # — the user almost certainly meant the framework
        # method, not their own action.
        RESERVED_CLASS_METHODS = %i[
          new allocate name superclass class
          deliver_later deliver_now deliver_later! deliver_now!
          mail headers attachments default
          with parameters
        ].freeze

        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @param mailer_index [MailerIndex]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, mailer_index:)
          diagnostics = []
          walk(root) do |call_node|
            class_name = mailer_class_for_call(call_node)
            next if class_name.nil?
            next if RESERVED_CLASS_METHODS.include?(call_node.name)

            class_entry = mailer_index.find(class_name) || mailer_index.find("::#{class_name}")
            next if class_entry.nil?

            action_entry = class_entry.find_action(call_node.name)
            if action_entry.nil?
              diagnostics << unknown_action_diagnostic(path, call_node, class_entry)
              next
            end

            diagnostics << action_call_info(path, call_node, class_entry, action_entry)
            arity_diag = arity_check(path, call_node, class_entry, action_entry)
            diagnostics << arity_diag if arity_diag
          end
          diagnostics
        end

        # Walks the tree yielding every CallNode whose receiver
        # resolves (directly or through `.with(...)`) to a
        # constant.
        def walk(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode) && action_call_candidate?(node)
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        def action_call_candidate?(node)
          # Skip anything that doesn't look like a mailer
          # action call: no receiver, or a non-constant /
          # non-`.with(...)` receiver.
          return false if node.receiver.nil?

          mailer_class_for_call(node) ? true : false
        end

        # Extracts the mailer class name when the call's
        # receiver is either:
        # - A constant (`UserMailer.welcome(...)`), or
        # - A `.with(...)` call whose receiver is a constant
        #   (`UserMailer.with(user: u).welcome`).
        def mailer_class_for_call(node)
          receiver = node.receiver
          case receiver
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            constant_receiver_name(receiver)
          when Prism::CallNode
            return nil unless WITH_METHODS.include?(receiver.name)

            constant_receiver_name(receiver.receiver)
          end
        end

        def action_call_info(path, call_node, class_entry, action_entry)
          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :info,
            rule: "mailer-call",
            message: "`#{class_entry.class_name}.#{action_entry.method_name}` " \
                     "matches mailer action (arity #{action_entry.arity_label})"
          )
        end

        def arity_check(path, call_node, class_entry, action_entry)
          actual = (call_node.arguments&.arguments || []).size
          return nil if action_entry.accepts?(actual)

          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "wrong-arity",
            message: "`#{class_entry.class_name}.#{action_entry.method_name}` " \
                     "expects #{action_entry.arity_label} argument(s), got #{actual}"
          )
        end

        def unknown_action_diagnostic(path, call_node, class_entry)
          location = call_node.location
          known = class_entry.actions.keys.sort.join(", ")
          known_part = known.empty? ? "no actions defined" : "known actions: #{known}"
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "unknown-action",
            message: "`#{class_entry.class_name}.#{call_node.name}` is not a defined " \
                     "mailer action (#{known_part})"
          )
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
