# frozen_string_literal: true

require "prism"
require "rigor/plugin"
require "rigor/source/literals"

module Rigor
  module Plugin
    # Example plugin: validates state-machine references.
    # Demonstrates the **two-pass DSL analysis** pattern many
    # plugins reuse:
    #
    #   1. **Collect pass.** Walk the file once to gather every
    #      state name declared inside a `state_machine do ... end`
    #      block (`state :draft`, `state :submitted`, ...).
    #   2. **Validate pass.** Walk the file again, validating each
    #      `transition_to(:sym)` and `event :sym` reference against
    #      the collected state set. Levenshtein distance ≤ 3 drives
    #      the did-you-mean suggestions.
    #
    # Useful for `aasm` / `statesman` / hand-rolled DSLs and any
    # framework where declarations and uses live in the same
    # file. The same skeleton lifts to GraphQL types,
    # ActiveModel validations, route declarations — anywhere a
    # declarative DSL produces a closed namespace and the rest
    # of the file references that namespace by literal symbol.
    #
    # ## Configuration
    #
    # Defaults match the `Statesman::Machine` API; override via
    # `.rigor.yml` if your DSL uses different names:
    #
    #     plugins:
    #       - gem: rigor-statesman
    #         config:
    #           dsl_method: state_machine    # the do-block opener
    #           state_method: state          # state declaration inside the block
    #           transition_method: transition_to  # call-site under check
    #
    # ## Diagnostics
    #
    # | Event                                    | Severity | Rule              |
    # | ---                                      | ---      | ---               |
    # | `transition_to(:known_state)`            | `:info`  | `known-state`     |
    # | `transition_to(:typo)` (close match)     | `:error` | `unknown-state` (with did-you-mean) |
    # | `transition_to(:typo)` (no close match)  | `:error` | `unknown-state`   |
    # | file declares no state machine           | silent   | —                 |
    class Statesman < Rigor::Plugin::Base
      manifest(
        id: "statesman",
        version: "0.1.0",
        description: "Validates state-machine transition references against declared states.",
        config_schema: {
          "dsl_method" => :string,
          "state_method" => :string,
          "transition_method" => :string
        }
      )

      DEFAULT_DSL_METHOD = "state_machine"
      DEFAULT_STATE_METHOD = "state"
      DEFAULT_TRANSITION_METHOD = "transition_to"

      def init(_services)
        @dsl_method = config.fetch("dsl_method", DEFAULT_DSL_METHOD).to_sym
        @state_method = config.fetch("state_method", DEFAULT_STATE_METHOD).to_sym
        @transition_method = config.fetch("transition_method", DEFAULT_TRANSITION_METHOD).to_sym
      end

      # ADR-37 — the two-pass shape made explicit. The collect pass
      # (pass 1) runs once per file as the node-rule file context: it
      # MUST complete before validation because a `transition_to` may
      # precede the `state` that declares its target, so it cannot be a
      # per-node rule in the engine's single forward walk. The validate
      # pass (pass 2) is then a per-`CallNode` rule over the
      # engine-owned walk — no hand-rolled traversal.
      node_file_context do |root, _scope|
        collect_states(root)
      end

      node_rule Prism::CallNode do |node, _scope, path, states|
        next [] if states.nil? || states.empty?
        next [] unless transition_call?(node)

        sym = literal_symbol_arg(node, 0)
        next [] if sym.nil? # not a literal — defer to runtime

        [build_diagnostic(path, node, sym, states)]
      end

      private

      # Pass 1 — every `state :foo` declaration inside a
      # `<dsl_method> do ... end` block on the file. Returns a
      # frozen Set of state name Symbols. Walks via the engine's
      # shared `Source::NodeWalker` rather than a hand-rolled traversal.
      def collect_states(root)
        states = Set.new
        Source::NodeWalker.each(root) do |node|
          next unless dsl_call?(node)

          Source::NodeWalker.each(node.block) do |inner|
            next unless state_declaration?(inner)

            sym = literal_symbol_arg(inner, 0)
            states << sym if sym
          end
        end
        states.freeze
      end

      def build_diagnostic(path, node, sym, states)
        if states.include?(sym)
          diagnostic(
            node, path: path,
                  severity: :info,
                  rule: "known-state",
                  message: "#{@transition_method}(:#{sym}) — declared state"
          )
        else
          hint = Rigor::Plugin::Base.suggest(sym, states)
          message = "unknown state :#{sym}"
          message += " (did you mean :#{hint}?)" if hint
          diagnostic(node, path: path, severity: :error, rule: "unknown-state", message: message)
        end
      end

      def dsl_call?(node)
        node.is_a?(Prism::CallNode) &&
          node.name == @dsl_method &&
          node.block
      end

      def state_declaration?(node)
        node.is_a?(Prism::CallNode) &&
          node.name == @state_method &&
          !node.arguments.nil?
      end

      def transition_call?(node)
        node.is_a?(Prism::CallNode) &&
          node.name == @transition_method &&
          !node.arguments.nil?
      end

      def literal_symbol_arg(call, index)
        Rigor::Source::Literals.symbol(call.arguments.arguments[index])
      end
    end

    Rigor::Plugin.register(Statesman)
  end
end
