# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Actionmailer < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for `<MailerClass>.<action>(...)` calls and validates each
      # against the {MailerIndex}. Recognises both:
      #
      # - `UserMailer.welcome(user)` — direct action call (the call returns a `Mail::Message` ready for
      #   `.deliver_now` / `.deliver_later`).
      # - `UserMailer.with(user: u).welcome` — parametrized action call. The `.with(...)` call is
      #   treated as a pass-through; the action's argument shape is validated on the trailing `.welcome`
      #   invocation even though the receiver is a method-call chain rather than a constant.
      #
      # The analyzer is purely syntactic: it does not look at runtime mailer state. Constants that don't
      # appear in the index are silently ignored — the rule has no opinion on non-mailer call shapes.
      module Analyzer
        # `.with(...)` is recognised as a forwarding step: the receiver of `.with(...)` is the mailer
        # class, so the trailing action-method call's class context is the same.
        WITH_METHODS = %i[with].freeze

        # Ruby method names that ActionMailer reserves on the class itself. We don't validate against
        # these as actions even if a mailer happens to override them — the user almost certainly meant
        # the framework method, not their own action.
        RESERVED_CLASS_METHODS = %i[
          new allocate name superclass class
          deliver_later deliver_now deliver_later! deliver_now!
          mail headers attachments default
          with parameters
          respond_to? respond_to_missing? method_defined?
          public_send send __send__ public_method
          method instance_method methods
        ].freeze

        # One mailer-call observation. Carries no path/location — the caller (the `node_rule` block)
        # positions it via `Plugin::Base#diagnostic`.
        Violation = Struct.new(:rule, :severity, :message, keyword_init: true)

        module_function

        # The mailer-call violations for a single call node (0..2), or `[]` when it is not a
        # `<Mailer>.action(...)` call on a known mailer. ADR-37: the engine owns the walk.
        def violations_for(call_node:, mailer_index:)
          return [] unless call_node.is_a?(Prism::CallNode) && action_call_candidate?(call_node)

          class_name = mailer_class_for_call(call_node)
          return [] if class_name.nil?
          return [] if RESERVED_CLASS_METHODS.include?(call_node.name)

          # `MailerIndex#find` de-roots the query itself (#621) — a `::UserMailer.welcome` receiver and a
          # plain `UserMailer.welcome` reach the same entry with no retry arm here.
          class_entry = mailer_index.find(class_name)
          return [] if class_entry.nil?

          action_entry = class_entry.find_action(call_node.name)
          if action_entry.nil?
            # Skip `unknown-action` when the mailer's include set has any unresolved module — it may
            # legitimately define the action (gem-shipped concern, dynamically loaded extension).
            return [] if class_entry.unresolved_includes?

            return [unknown_action_violation(call_node, class_entry)]
          end

          violations = [action_call_info(call_node, class_entry, action_entry)]
          arity = arity_violation(call_node, class_entry, action_entry)
          violations << arity if arity
          violations
        end

        def action_call_candidate?(node)
          # Skip anything that doesn't look like a mailer action call: no receiver, or a non-constant /
          # non-`.with(...)` receiver.
          return false if node.receiver.nil?

          mailer_class_for_call(node) ? true : false
        end

        # Extracts the mailer class name when the call's receiver is either:
        # - A constant (`UserMailer.welcome(...)`), or
        # - A `.with(...)` call whose receiver is a constant (`UserMailer.with(user: u).welcome`).
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

        def action_call_info(_call_node, class_entry, action_entry)
          Violation.new(
            severity: :info,
            rule: "mailer-call",
            message: "`#{class_entry.class_name}.#{action_entry.method_name}` " \
                     "matches mailer action (arity #{action_entry.arity_label})"
          )
        end

        def arity_violation(call_node, class_entry, action_entry)
          args = call_node.arguments&.arguments || []
          actual = args.size
          return nil if action_entry.accepts?(actual)

          # Trailing keyword-hash relaxation. `Notify.foo(uid, gid, success_count: 5)` is 3 positional
          # args from Prism's perspective (2 + a KeywordHashNode); the action's `def foo(uid, gid,
          # success_count:)` has arity 2. When the call's trailing arg is a kwargs hash, allow `(actual
          # - 1) ≤ max_arity` so kwargs-carrying calls don't surface as wrong-arity.
          return nil if args.last.is_a?(Prism::KeywordHashNode) && action_entry.accepts?(actual - 1)

          Violation.new(
            severity: :error,
            rule: "wrong-arity",
            message: "`#{class_entry.class_name}.#{action_entry.method_name}` " \
                     "expects #{action_entry.arity_label} argument(s), got #{actual}"
          )
        end

        def unknown_action_violation(call_node, class_entry)
          known = class_entry.actions.keys.sort.join(", ")
          known_part = known.empty? ? "no actions defined" : "known actions: #{known}"
          Violation.new(
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
