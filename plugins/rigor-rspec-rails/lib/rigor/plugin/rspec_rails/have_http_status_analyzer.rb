# frozen_string_literal: true

require "prism"

require_relative "http_status_codes"

module Rigor
  module Plugin
    class RspecRails < Rigor::Plugin::Base
      # Validates `expect(response).to have_http_status(arg)` / the negated `.not_to have_http_status(arg)`
      # and the bare matcher form `should have_http_status(arg)`.
      #
      # Recognised argument shapes:
      #
      # - **IntegerNode**: must be in `100..599`. Numbers outside that range fire
      #   `have_http_status.out-of-range`.
      # - **SymbolNode**: must be one of the known `Rack::Utils::SYMBOL_TO_STATUS_CODE` keys OR a Rails
      #   status-group alias (`:success` / `:successful` / `:missing` / `:redirect` / `:error` /
      #   `:client_error` / `:server_error` / `:informational`). Unknown symbols fire
      #   `have_http_status.unknown-symbol` (typo-flavoured).
      # - **StringNode**: passed through silently (a literal `"200"` is accepted by Rails at runtime; we
      #   don't second-guess the user's intent for the String form).
      # - **Anything else** (variable, method call, computed expression): skipped — the plugin can't
      #   statically prove the runtime value.
      #
      # Walks every `Prism::CallNode` looking for matcher invocations rather than only the
      # `expect(...).to ...` chain because `have_http_status` is also used as a plain matcher inside Rails'
      # `assert_response` shim and in shared-context bodies; the diagnostic is the same regardless of the
      # surrounding chain.
      module HaveHttpStatusAnalyzer
        # One matcher violation: the kebab-case `rule` and the human-readable `message`. Carries no
        # location/path — the caller (the `node_rule` block) positions the diagnostic at the matcher's
        # `message_loc` via `Plugin::Base#diagnostic`.
        Violation = Struct.new(:rule, :message, keyword_init: true)

        MATCHER_NAME = :have_http_status

        module_function

        # The matcher violation for a single CallNode, or nil when the node is not a
        # `have_http_status(<int|symbol>)` matcher or its argument is statically valid. ADR-37: the engine
        # owns the walk, so this is per-node logic — no traversal here.
        #
        # @param call_node [Prism::Node]
        # @return [Violation, nil]
        def violation_for(call_node)
          return nil unless call_to_matcher?(call_node)

          diagnostic_for(call_node)
        end

        # `have_http_status` is a matcher — called either with no receiver (`have_http_status(200)` inside
        # `.to(...)`) or with a receiver chain we don't care about here. Either way we want the call node
        # whose name is `have_http_status` and that carries exactly one positional argument.
        def call_to_matcher?(node)
          node.is_a?(Prism::CallNode) &&
            node.name == MATCHER_NAME &&
            single_positional?(node)
        end

        def single_positional?(call_node)
          args = call_node.arguments&.arguments || []
          args.size == 1
        end

        def diagnostic_for(call_node)
          arg = call_node.arguments.arguments.first
          case arg
          when Prism::IntegerNode then integer_violation(arg)
          when Prism::SymbolNode then symbol_violation(arg)
          end
        end

        def integer_violation(integer_node)
          value = integer_node.value
          return nil if HttpStatusCodes::VALID_NUMERIC_RANGE.cover?(value)

          Violation.new(
            rule: "have_http_status.out-of-range",
            message: "have_http_status(#{value}) is outside the valid HTTP status " \
                     "range #{HttpStatusCodes::VALID_NUMERIC_RANGE}"
          )
        end

        def symbol_violation(symbol_node)
          sym = symbol_node.unescaped.to_sym
          known = HttpStatusCodes.known_symbols
          # ADR-39: Rack unavailable → the accepted symbol set is unknowable, so decline rather than flag
          # from a guess.
          return nil if known.nil?
          return nil if known.include?(sym)

          Violation.new(
            rule: "have_http_status.unknown-symbol",
            message: "have_http_status(:#{sym}) is not a recognised HTTP status symbol " \
                     "(see Rack::Utils::SYMBOL_TO_STATUS_CODE) or Rails status-group " \
                     "alias (:success / :successful / :missing / :redirect / :error / " \
                     ":client_error / :server_error / :informational)"
          )
        end
      end
    end
  end
end
