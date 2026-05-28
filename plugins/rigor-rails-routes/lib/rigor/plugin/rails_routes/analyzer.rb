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
        # user-declared routes; Rails (and a small set of
        # widely-used asset gems) ship built-in helpers
        # (`url_for`, `polymorphic_path`, vite_ruby's
        # `vite_asset_path`, …) the plugin deliberately ignores.
        BUILTIN_PASSTHROUGH = %w[
          url_for_path url_for_url
          polymorphic_path polymorphic_url
          vite_asset_path vite_asset_url
          expose_path expose_url
          asset_path asset_url
          image_path image_url
          javascript_path javascript_url
          stylesheet_path stylesheet_url
          font_path font_url
          video_path video_url
          audio_path audio_url
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

        # Paths under which `unknown-helper` is suppressed. Route
        # helpers are not customarily resolved through these
        # directories, so a bare `shared_inbox_url` call inside
        # `app/models/account.rb` (the call-site is the
        # `accounts.shared_inbox_url` AR column accessor — same
        # name as a hypothetical route helper) or a `default_url`
        # inside `lib/paperclip/url_generator_extensions.rb` (the
        # call-site is `Paperclip::UrlGenerator#default_url`, a
        # gem-side instance method) would be a false positive.
        # The core engine's `call.undefined-method` still catches
        # a genuinely unreachable receiver. Cheap path-prefix
        # check; no AR-column / gem-include analysis required.
        SKIP_UNKNOWN_HELPER_PATHS = [
          %r{(?:\A|/)app/models/},
          %r{(?:\A|/)app/services/},
          %r{(?:\A|/)app/workers/},
          %r{(?:\A|/)app/finders/},
          %r{(?:\A|/)app/policies/},
          %r{(?:\A|/)app/validators/},
          %r{(?:\A|/)app/uploaders/},
          %r{(?:\A|/)lib/},
          %r{(?:\A|/)db/},
          %r{(?:\A|/)config/}
        ].freeze

        # @param path [String] file being analysed
        # @param root [Prism::Node]
        # @param helper_table [HelperTable]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, helper_table:)
          suppress_unknown = SKIP_UNKNOWN_HELPER_PATHS.any? { |re| path.match?(re) }
          # Same SKIP set silences `wrong-arity` too. A call
          # like `group_path` inside `app/services/groups/nested_
          # create_service.rb` is almost certainly the service's
          # own instance method (`attr_accessor :group_path`) —
          # both the unknown-helper check and the arity check
          # against a registered route helper would FP.
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
              # When the file is in a `SKIP_UNKNOWN_HELPER_PATHS`
              # directory (models / services / workers / lib /
              # …), don't emit the info or arity diagnostic
              # against a registered helper either — the call
              # is more likely the file's own instance method
              # (e.g. `group_path` as an `attr_accessor`) that
              # happens to share a name with a registered
              # route helper. The unknown-helper suppression
              # already silences the inverse case.
              next if suppress_unknown

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
            elsif suppress_unknown
              # File is in a directory where route helpers are
              # not customarily resolved (models / lib / db /
              # config). Skip `unknown-helper` to avoid false
              # positives on AR column accessors / gem-side
              # instance methods that happen to end in `_url` /
              # `_path`.
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

        # Paths where the implicit-params-fill pattern is
        # idiomatic — controllers / mailers / views routinely
        # call `*_path` / `*_url` helpers with fewer args than
        # the route's static placeholder count because Rails
        # fills `:foo_id` segments from `request.params` at
        # runtime (controllers / views) or from the call's
        # polymorphic-friendly receiver (mailers).
        IMPLICIT_FILL_PATHS = [
          %r{(?:\A|/)app/controllers/},
          %r{(?:\A|/)app/mailers/},
          %r{(?:\A|/)app/views/},
          %r{(?:\A|/)app/components/},
          %r{(?:\A|/)app/helpers/}
        ].freeze

        def implicit_fill_path?(path)
          IMPLICIT_FILL_PATHS.any? { |re| path.match?(re) }
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

          # Underflow tolerance for controllers / mailers /
          # views. A `redirect_to namespace_project_milestones_path`
          # inside `Projects::MilestonesController` legitimately
          # passes 0 args — Rails fills the missing `:namespace_id`
          # / `:project_id` segments from `request.params` at
          # runtime. Mailers reach helpers polymorphically too
          # (`project_commit_url(commit)` resolves project from
          # commit.project). Silence when `actual < min_arity`
          # AND the call site is in a controller / mailer / view
          # directory (where the implicit-params-fill pattern is
          # idiomatic). Overflow (`actual > max_arity`) still
          # fires — that's almost always a typo.
          arities_set = helper_table.acceptable_arities(entry.name)
          min_arity = arities_set.min
          return nil if actual < min_arity && implicit_fill_path?(path)

          arities = arities_set.sort
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
