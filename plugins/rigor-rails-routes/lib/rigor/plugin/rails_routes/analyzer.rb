# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for `*_path` /
      # `*_url` calls and validates each against the
      # plugin's {HelperTable}. Emits info diagnostics for
      # recognised helpers and error diagnostics for typos /
      # arity mismatches.
      module Analyzer
        DID_YOU_MEAN_DISTANCE = 3

        # Built-in Rails helpers we don't want to flag as
        # unknown. The plugin's HelperTable describes
        # user-declared routes; Rails ships built-in helpers
        # (`url_for`, `polymorphic_path`, …) the plugin
        # deliberately ignores.
        BUILTIN_PASSTHROUGH = %w[
          url_for_path url_for_url
          polymorphic_path polymorphic_url
        ].freeze

        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        module_function

        # @param path [String] file being analysed
        # @param root [Prism::Node]
        # @param helper_table [HelperTable]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, helper_table:)
          diagnostics = []
          walk(root) do |call_node|
            name = call_node.name.to_s
            next unless name.end_with?("_path") || name.end_with?("_url")
            next if BUILTIN_PASSTHROUGH.include?(name)

            entry = helper_table.find(name)
            if entry
              diagnostics << info_diagnostic(path, call_node, entry)
              arity_diagnostic = arity_check(path, call_node, entry)
              diagnostics << arity_diagnostic if arity_diagnostic
            else
              diagnostics << unknown_helper_diagnostic(path, call_node, name, helper_table)
            end
          end
          diagnostics
        end

        def walk(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode) && implicit_helper_call?(node)
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        # `*_path` / `*_url` calls without an explicit
        # receiver. Calls like `obj.users_path` or
        # `Foo::users_path` are NOT route-helper invocations
        # in Rails — controllers / views call helpers
        # implicitly.
        def implicit_helper_call?(node)
          node.receiver.nil? && (node.name.to_s.end_with?("_path") || node.name.to_s.end_with?("_url"))
        end

        def info_diagnostic(path, call_node, entry)
          location = call_node.location
          method_label = entry.http_method ? entry.http_method.to_s.upcase : "*"
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :info,
            rule: "helper",
            message: "`#{entry.name}` → #{method_label} #{entry.path}"
          )
        end

        def arity_check(path, call_node, entry)
          actual = (call_node.arguments&.arguments || []).size
          return nil if actual == entry.arity

          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "wrong-arity",
            message: "`#{entry.name}` expects #{entry.arity} argument(s), got #{actual}"
          )
        end

        def unknown_helper_diagnostic(path, call_node, name, helper_table)
          location = call_node.location
          suggestion = did_you_mean(name, helper_table.names)
          message = "no route helper `#{name}`"
          message += " (did you mean `#{suggestion}`?)" if suggestion

          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "unknown-helper",
            message: message
          )
        end

        # Levenshtein-style nearest neighbour. Returns the
        # closest known helper within {DID_YOU_MEAN_DISTANCE}
        # edits, or nil.
        def did_you_mean(name, candidates)
          best = nil
          best_distance = DID_YOU_MEAN_DISTANCE + 1
          candidates.each do |candidate|
            d = levenshtein(name, candidate)
            if d < best_distance
              best = candidate
              best_distance = d
            end
          end
          best
        end

        # Standard iterative Levenshtein. Lifted from
        # rigor-routes' equivalent helper for parity.
        def levenshtein(left, right)
          return right.length if left.empty?
          return left.length if right.empty?

          rows = Array.new(left.length + 1) { Array.new(right.length + 1, 0) }
          (0..left.length).each { |i| rows[i][0] = i }
          (0..right.length).each { |j| rows[0][j] = j }

          (1..left.length).each do |i|
            (1..right.length).each do |j|
              cost = left[i - 1] == right[j - 1] ? 0 : 1
              rows[i][j] = [
                rows[i - 1][j] + 1,
                rows[i][j - 1] + 1,
                rows[i - 1][j - 1] + cost
              ].min
            end
          end
          rows[left.length][right.length]
        end
      end
    end
  end
end
