# frozen_string_literal: true

require "did_you_mean"
require "prism"

module Rigor
  module Plugin
    class Pundit < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for Pundit
      # entry-point calls and validates each against the
      # {PolicyIndex}.
      #
      # Recognised shapes:
      #
      # - `authorize(record, :action)` — record's inferred
      #   type → `<Type>Policy#<action>?` lookup. Both the
      #   policy class and the predicate must exist.
      # - `authorize(record)` — without an action argument,
      #   we only validate that `<Type>Policy` exists. The
      #   action name is determined at runtime from the
      #   controller's current action; static validation
      #   isn't possible without controller context.
      # - `policy(record)` / `policy_scope(scope)` — same
      #   `<Type>Policy` existence check.
      #
      # When the first argument's inferred type is NOT a
      # `Nominal[T]` (e.g. an untyped local variable), the
      # call is silently passed through. The plugin only
      # validates what it can prove from the static type
      # carrier.
      module Analyzer
        ENTRY_METHODS = %i[authorize policy policy_scope].freeze

        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @param policy_index [PolicyIndex]
        # @param scope [Rigor::Inference::Scope, nil]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, policy_index:, scope:)
          diagnostics = []
          walk(root) do |call_node|
            record_node = call_node.arguments&.arguments&.first
            next if record_node.nil?

            policy_class_name = derive_policy_class_name(record_node, scope)
            next if policy_class_name.nil?

            policy_entry = policy_index.find(policy_class_name)
            if policy_entry.nil?
              diagnostics << unknown_policy_class_diagnostic(path, call_node, policy_class_name, policy_index)
              next
            end

            diagnostics << policy_call_info(path, call_node, policy_class_name)

            next unless call_node.name == :authorize

            action_diag = action_check(path, call_node, policy_entry)
            diagnostics << action_diag if action_diag
          end
          diagnostics
        end

        def walk(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode) && entry_call?(node)
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        def entry_call?(node)
          ENTRY_METHODS.include?(node.name) && node.receiver.nil?
        end

        # Resolves the first-argument expression to a policy
        # class name. The candidates are:
        # - `Foo` (a constant) → `FooPolicy`
        # - `Foo.method(...)` whose inferred type is
        #   `Nominal[Bar]` → `BarPolicy`
        # - any other expression whose inferred type is
        #   `Nominal[Bar]` → `BarPolicy`
        # Returns `nil` when the type isn't statically
        # determinable.
        def derive_policy_class_name(record_node, scope)
          if record_node.is_a?(Prism::ConstantReadNode) || record_node.is_a?(Prism::ConstantPathNode)
            constant_name = constant_receiver_name(record_node)
            return "#{constant_name.delete_prefix('::')}Policy" if constant_name
          end

          return nil if scope.nil?

          type = safe_type_of(scope, record_node)
          return nil unless type.is_a?(Rigor::Type::Nominal)

          "#{type.class_name.to_s.delete_prefix('::')}Policy"
        end

        def safe_type_of(scope, node)
          scope.type_of(node)
        rescue StandardError
          nil
        end

        def policy_call_info(path, call_node, policy_class_name)
          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :info,
            rule: "policy-call",
            message: "`#{call_node.name}(...)` resolves to `#{policy_class_name}`"
          )
        end

        def unknown_policy_class_diagnostic(path, call_node, policy_class_name, policy_index)
          location = call_node.location
          suggestions = DidYouMean::SpellChecker.new(dictionary: policy_index.names).correct(policy_class_name)
          suggestion_part = suggestions.empty? ? "" : " (did you mean `#{suggestions.first}`?)"
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "unknown-policy-class",
            message: "no policy class `#{policy_class_name}` for `#{call_node.name}` call#{suggestion_part}"
          )
        end

        # Validates the `authorize(record, :action)` form.
        # Returns nil when the call has no second argument
        # (the runtime infers it from the controller — out
        # of scope here) or when the second argument isn't
        # a literal symbol / string.
        def action_check(path, call_node, policy_entry)
          args = call_node.arguments&.arguments || []
          return nil if args.size < 2

          action_node = args[1]
          action_name = literal_symbol_or_string(action_node)
          return nil if action_name.nil?

          predicate = policy_entry.normalize(action_name)
          return nil if policy_entry.includes_method?(predicate)

          location = call_node.location
          dictionary = policy_entry.predicate_methods.map(&:to_s)
          suggestions = DidYouMean::SpellChecker.new(dictionary: dictionary).correct(predicate.to_s)
          suggestion_part = suggestions.empty? ? "" : " (did you mean `:#{suggestions.first.delete_suffix('?')}`?)"
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "unknown-policy-method",
            message: "`#{policy_entry.policy_class_name}##{predicate}` is not defined " \
                     "(known: #{policy_entry.known_methods.join(', ')})#{suggestion_part}"
          )
        end

        def literal_symbol_or_string(node)
          case node
          when Prism::SymbolNode then node.unescaped
          when Prism::StringNode then node.unescaped
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
