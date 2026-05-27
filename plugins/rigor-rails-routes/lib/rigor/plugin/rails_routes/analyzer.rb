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

        # RSpec / Minitest DSL methods that DECLARE a memoized
        # local — `let(:foo) { ... }`, `subject(:foo) { ... }`,
        # plus the bang and let_it_be variants. The first
        # positional Symbol argument is the local name. A bare
        # `subject { ... }` (no arg) defines `:subject` itself.
        SHADOWING_DSL = %i[
          let let! let_it_be let_it_be!
          subject subject!
        ].freeze

        # @param path [String] file being analysed
        # @param root [Prism::Node]
        # @param helper_table [HelperTable]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, helper_table:)
          diagnostics = []
          # Pre-walk the file to collect every name that
          # shadows a route helper at call time: `let(:foo)`,
          # `subject(:foo)`, `def foo`, and explicit local
          # assignments (`foo_url = "..."`). At the call site
          # `foo` then resolves to the shadowing local, not to
          # the registered route helper — firing `unknown-helper`
          # / `wrong-arity` against the helper would be a false
          # positive against canonical RSpec idioms (Mastodon
          # has 200+ such patterns in `spec/`).
          shadowing = collect_shadowing_names(root)

          walk(root) do |call_node|
            name = call_node.name.to_s
            next unless name.end_with?("_path") || name.end_with?("_url")
            next if BUILTIN_PASSTHROUGH.include?(name)
            next if shadowing.include?(name)

            entry = helper_table.find(name)
            if entry
              diagnostics << info_diagnostic(path, call_node, entry)
              arity_diagnostic = arity_check(path, call_node, entry, helper_table)
              diagnostics << arity_diagnostic if arity_diagnostic
            elsif helper_table.recognised?(name)
              # Custom helper (discovered via
              # `app/helpers/**/*.rb`) or a dynamic-provider
              # Devise OmniAuth helper. We do NOT have an
              # arity / path to validate — the helper is just
              # known-to-exist. Skip the arity / info
              # diagnostic; the absence of an `unknown-helper`
              # error is the user-visible outcome.
              next
            else
              diagnostics << unknown_helper_diagnostic(path, call_node, name, helper_table)
            end
          end
          diagnostics
        end

        # Walks the AST once and returns the Set of names that
        # shadow a route helper for this file. Includes:
        #
        # - `def name` declarations (any level — the
        #   per-method-scope visibility model Ruby uses means a
        #   local `def` shadows the helper at every call site
        #   reachable from where it is defined; we approximate
        #   "reachable" with "anywhere in the same file").
        # - RSpec `let` / `let!` / `let_it_be` / `let_it_be!` /
        #   `subject` / `subject!` declarations.
        # - Local assignments at any scope
        #   (`foo_url = "..."`).
        def collect_shadowing_names(root)
          names = Set.new
          walk_for_shadowing(root, names)
          names
        end

        def walk_for_shadowing(node, names)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::DefNode
            names << node.name.to_s if node.receiver.nil?
          when Prism::LocalVariableWriteNode
            names << node.name.to_s
          when Prism::CallNode
            record_let_like_name(node, names)
          end

          node.compact_child_nodes.each { |child| walk_for_shadowing(child, names) }
        end

        def record_let_like_name(call_node, names)
          return unless call_node.receiver.nil?
          return unless SHADOWING_DSL.include?(call_node.name)

          arg = call_node.arguments&.arguments&.first
          if arg.is_a?(Prism::SymbolNode)
            names << arg.unescaped
          elsif call_node.name == :subject && call_node.arguments.nil?
            # Bare `subject { ... }` defines `:subject` itself.
            names << "subject"
          end
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

        def arity_check(path, call_node, entry, helper_table)
          args = call_node.arguments&.arguments || []
          actual = args.size
          # Uncountable nouns (`news` / `series` / `media`) cause
          # Rails to register two entries under the same helper
          # name — `news_path` accepts both arity 0 (index) and
          # arity 1 (show). The HelperTable multimap stores both;
          # accepts_arity? checks the full set.
          return nil if helper_table.accepts_arity?(entry.name, actual)

          # Rails accepts a kwargs-only call shape that supplies
          # route segments by name:
          #   short_account_status_url(account_username: u, id: i)
          # for the route `/@:account_username/:id` (arity 2).
          # Our positional-arg count is 1 (the KeywordHashNode),
          # so the strict check rejects — but Rails would
          # resolve every segment from the hash. When the call
          # has a trailing KeywordHashNode AND the positional
          # count (excluding it) is `<= expected_arity`, accept
          # — the kwargs may carry the missing segments.
          if args.last.is_a?(Prism::KeywordHashNode)
            positional = actual - 1
            return nil if helper_table.acceptable_arities(entry.name).any? { |exp| positional <= exp }
          end

          arities = helper_table.acceptable_arities(entry.name).sort
          expected = arities.length == 1 ? arities.first.to_s : "#{arities.first}..#{arities.last}"
          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "wrong-arity",
            message: "`#{entry.name}` expects #{expected} argument(s), got #{actual}"
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
