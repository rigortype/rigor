# frozen_string_literal: true

require "did_you_mean"
require "prism"

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # Per-file walker — the controller's parsed AST is searched
      # for `*_path` / `*_url` calls and each is validated against
      # the helper table the upstream `rigor-rails-routes` plugin
      # publishes via `services.fact_store`.
      #
      # The recogniser keys on call-method-name suffix:
      #
      # - `users_path`, `edit_user_path(@user)` → `_path` family.
      # - `users_url`, `edit_user_url(@user)` → `_url` family.
      #
      # Any call whose name doesn't end in `_path` / `_url` is
      # silently passed through. Calls with an explicit non-self
      # receiver (`other_helper.users_path`) are also skipped —
      # the helper is implicit-self in real controllers, and a
      # custom-receiver call is almost certainly someone's own
      # method that happens to share the suffix.
      module Analyzer
        SUFFIXES = %w[_path _url].freeze

        Diagnostic = Data.define(:path, :line, :column, :message, :severity, :rule)

        module_function

        # @param path [String] absolute path to the file being
        #   analysed (used for diagnostic locations).
        # @param root [Prism::Node] the parsed AST root.
        # @param helper_table [Hash{String => Hash}] the value
        #   `services.fact_store.read(plugin_id: "rails-routes",
        #   name: :helper_table)` returns. Each entry carries
        #   `name`, `arity`, `path`, `http_method`, `action`.
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, helper_table:)
          diagnostics = []
          known_names = helper_table.keys.freeze
          spell_checker = DidYouMean::SpellChecker.new(dictionary: known_names)

          walk(root) do |call_node|
            entry, suggestion = lookup(call_node, helper_table, spell_checker)
            diagnostics << diagnostic_for(path, call_node, entry, suggestion)
          end

          diagnostics
        end

        # Walk the AST yielding only call nodes whose method
        # name ends in `_path` / `_url` and whose receiver is
        # implicit-self (no explicit receiver). Constants are
        # skipped — `Rails.application.routes.url_helpers` is
        # not what Phase 4 validates.
        def walk(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode) && helper_suffix?(node.name) && node.receiver.nil?
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        def helper_suffix?(name)
          name_str = name.to_s
          SUFFIXES.any? { |suffix| name_str.end_with?(suffix) && name_str.length > suffix.length }
        end

        # Returns `[entry, suggestion]`:
        #
        # - `[entry, nil]` — known helper.
        # - `[nil, nil]` — unknown helper, no spell-checker match.
        # - `[nil, "user_path"]` — unknown helper, did-you-mean
        #   suggestion to surface in the diagnostic.
        def lookup(call_node, helper_table, spell_checker)
          name = call_node.name.to_s
          entry = helper_table[name]
          return [entry, nil] if entry

          [nil, spell_checker.correct(name).first]
        end

        # Builds the diagnostic. `entry == nil` → unknown helper.
        # `entry != nil` and arity matches → info. Otherwise
        # arity mismatch.
        def diagnostic_for(path, call_node, entry, suggestion)
          return unknown_helper_diagnostic(path, call_node, suggestion) if entry.nil?

          actual_arity = positional_arg_count(call_node)
          expected = entry[:arity]
          return wrong_arity_diagnostic(path, call_node, entry, actual_arity) if actual_arity != expected

          helper_call_diagnostic(path, call_node, entry)
        end

        def positional_arg_count(call_node)
          args = call_node.arguments&.arguments || []
          # Drop a trailing `KeywordHashNode` so call sites that
          # pass `users_path(format: :json)` don't get counted as
          # arity 1. Same convention rigor-rails-routes' helper-
          # table arity uses (positional only).
          args = args[0..-2] if args.last.is_a?(Prism::KeywordHashNode)
          args.size
        end

        def location(call_node)
          call_node.message_loc || call_node.location
        end

        def helper_call_diagnostic(path, call_node, entry)
          loc = location(call_node)
          method = entry[:http_method] ? entry[:http_method].to_s.upcase : "(any)"
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: "Action Pack helper `#{call_node.name}` → #{method} #{entry[:path]} (action: #{entry[:action]}).",
            severity: :info, rule: "helper-call"
          )
        end

        def unknown_helper_diagnostic(path, call_node, suggestion)
          loc = location(call_node)
          base = "Unknown route helper `#{call_node.name}` — not registered in `config/routes.rb`."
          message = suggestion ? "#{base} Did you mean `#{suggestion}`?" : base
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: message, severity: :error, rule: "unknown-helper"
          )
        end

        def wrong_arity_diagnostic(path, call_node, entry, actual_arity)
          loc = location(call_node)
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: "Route helper `#{call_node.name}` expects #{entry[:arity]} positional " \
                     "argument(s) but the call passes #{actual_arity}.",
            severity: :error, rule: "wrong-helper-arity"
          )
        end
      end
    end
  end
end
