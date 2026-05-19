# frozen_string_literal: true

require "prism"

require_relative "http_status_codes"

module Rigor
  module Plugin
    class RspecRails < Rigor::Plugin::Base
      # Validates `expect(response).to have_http_status(arg)` /
      # the negated `.not_to have_http_status(arg)` and the
      # bare matcher form `should have_http_status(arg)`.
      #
      # Recognised argument shapes:
      #
      # - **IntegerNode**: must be in `100..599`. Numbers outside
      #   that range fire `have_http_status.out-of-range`.
      # - **SymbolNode**: must be one of the known
      #   `Rack::Utils::SYMBOL_TO_STATUS_CODE` keys OR a Rails
      #   status-group alias (`:success` / `:successful` /
      #   `:missing` / `:redirect` / `:error` / `:client_error` /
      #   `:server_error` / `:informational`). Unknown symbols
      #   fire `have_http_status.unknown-symbol` (typo-flavoured).
      # - **StringNode**: passed through silently (a literal
      #   `"200"` is accepted by Rails at runtime; we don't
      #   second-guess the user's intent for the String form).
      # - **Anything else** (variable, method call, computed
      #   expression): skipped — the plugin can't statically
      #   prove the runtime value.
      #
      # Walks every `Prism::CallNode` looking for matcher
      # invocations rather than only the `expect(...).to ...`
      # chain because `have_http_status` is also used as a
      # plain matcher inside Rails' `assert_response` shim and
      # in shared-context bodies; the diagnostic is the same
      # regardless of the surrounding chain.
      module HaveHttpStatusAnalyzer
        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        MATCHER_NAME = :have_http_status

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:)
          diagnostics = []
          walk(root) do |call_node|
            diagnostic = diagnostic_for(call_node, path)
            diagnostics << diagnostic if diagnostic
          end
          diagnostics
        end

        def walk(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if call_to_matcher?(node)
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        # `have_http_status` is a matcher — called either with
        # no receiver (`have_http_status(200)` inside `.to(...)`)
        # or with a receiver chain we don't care about here.
        # Either way we want the call node whose name is
        # `have_http_status` and that carries exactly one
        # positional argument.
        def call_to_matcher?(node)
          node.is_a?(Prism::CallNode) &&
            node.name == MATCHER_NAME &&
            single_positional?(node)
        end

        def single_positional?(call_node)
          args = call_node.arguments&.arguments || []
          args.size == 1
        end

        def diagnostic_for(call_node, path)
          arg = call_node.arguments.arguments.first
          case arg
          when Prism::IntegerNode then integer_diagnostic(call_node, path, arg)
          when Prism::SymbolNode then symbol_diagnostic(call_node, path, arg)
          end
        end

        def integer_diagnostic(call_node, path, integer_node)
          value = integer_node.value
          return nil if HttpStatusCodes::VALID_NUMERIC_RANGE.cover?(value)

          build_diagnostic(
            call_node, path,
            rule: "have_http_status.out-of-range",
            message: "have_http_status(#{value}) is outside the valid HTTP status " \
                     "range #{HttpStatusCodes::VALID_NUMERIC_RANGE}"
          )
        end

        def symbol_diagnostic(call_node, path, symbol_node)
          sym = symbol_node.unescaped.to_sym
          return nil if HttpStatusCodes::KNOWN_SYMBOLS.include?(sym)

          build_diagnostic(
            call_node, path,
            rule: "have_http_status.unknown-symbol",
            message: "have_http_status(:#{sym}) is not a recognised HTTP status symbol " \
                     "(see Rack::Utils::SYMBOL_TO_STATUS_CODE) or Rails status-group " \
                     "alias (:success / :successful / :missing / :redirect / :error / " \
                     ":client_error / :server_error / :informational)"
          )
        end

        def build_diagnostic(call_node, path, rule:, message:)
          location = call_node.message_loc || call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :warning,
            rule: rule,
            message: message
          )
        end
      end
    end
  end
end
