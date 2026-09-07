# frozen_string_literal: true

require "prism"
require "rigor/source/literals"

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for `*_path` / `*_url` calls and validates each against the
      # plugin's {HelperTable}. Emits info diagnostics for recognised helpers and error diagnostics for
      # typos / arity mismatches.
      module Analyzer
        # Built-in Rails helpers we don't want to flag as unknown. The plugin's HelperTable describes
        # user-declared routes; Rails (and a small set of widely-used asset gems) ship built-in helpers
        # (`url_for`, `polymorphic_path`, vite_ruby's `vite_asset_path`, …) the plugin deliberately ignores.
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

        # One route-helper observation. Carries no path/location — the caller (the `node_rule` block)
        # positions it via `Plugin::Base#diagnostic`.
        Violation = Struct.new(:rule, :severity, :message, keyword_init: true)

        module_function

        # RSpec / Minitest DSL methods that DECLARE a memoized local — `let(:foo) { ... }`, `subject(:foo)
        # { ... }`, plus the bang and let_it_be variants. The first positional Symbol argument is the local
        # name. A bare `subject { ... }` (no arg) defines `:subject` itself.
        SHADOWING_DSL = %i[
          let let! let_it_be let_it_be!
          subject subject!
        ].freeze

        # Paths under which `unknown-helper` is suppressed. Route helpers are not customarily resolved
        # through these directories, so a bare `shared_inbox_url` call inside `app/models/account.rb` (the
        # call-site is the `accounts.shared_inbox_url` AR column accessor — same name as a hypothetical
        # route helper) or a `default_url` inside `lib/paperclip/url_generator_extensions.rb` (the
        # call-site is `Paperclip::UrlGenerator#default_url`, a gem-side instance method) would be a false
        # positive. The core engine's `call.undefined-method` still catches a genuinely unreachable
        # receiver. Cheap path-prefix check; no AR-column / gem-include analysis required.
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
        # The route-helper violations for a single call node (0..2), or `[]` when the node is not an
        # implicit `*_path` / `*_url` helper call, is shadowed by a same-file binding, or is in a
        # suppressed directory. ADR-37: the engine owns the walk; the same-file `shadowing` set is built
        # once as the node-rule file context.
        def violations_for(call_node:, helper_table:, shadowing:, path:)
          return [] unless call_node.is_a?(Prism::CallNode) && implicit_helper_call?(call_node)

          name = call_node.name.to_s
          return [] if BUILTIN_PASSTHROUGH.include?(name)
          return [] if shadowing.include?(name)

          # The SKIP set silences both `unknown-helper` and `wrong-arity`: a `group_path` inside
          # `app/services/...` is more likely the file's own method (an `attr_accessor`) than a route helper.
          suppress_unknown = SKIP_UNKNOWN_HELPER_PATHS.any? { |re| path.match?(re) }

          entry = helper_table.find(name)
          if entry
            return [] if suppress_unknown

            violations = [info_violation(entry)]
            arity = arity_violation(call_node, entry, helper_table, path)
            violations << arity if arity
            violations
          elsif helper_table.recognised?(name) || suppress_unknown
            # Recognised custom / dynamic helper (no arity to check), or a directory where helpers aren't
            # customarily resolved.
            []
          else
            [unknown_helper_violation(name, helper_table)]
          end
        end

        # Walks the AST once and returns the Set of names that shadow a route helper for this file. Includes:
        #
        # - `def name` declarations (any level — the per-method-scope visibility model Ruby uses means a
        #   local `def` shadows the helper at every call site reachable from where it is defined; we
        #   approximate "reachable" with "anywhere in the same file").
        # - RSpec `let` / `let!` / `let_it_be` / `let_it_be!` / `subject` / `subject!` declarations.
        # - Local assignments at any scope (`foo_url = "..."`).
        def collect_shadowing_names(root)
          names = Set.new
          Source::NodeWalker.each(root) do |node|
            case node
            when Prism::DefNode
              names << node.name.to_s if node.receiver.nil?
            when Prism::LocalVariableWriteNode
              names << node.name.to_s
            when Prism::CallNode
              record_let_like_name(node, names)
            end
          end
          names
        end

        def record_let_like_name(call_node, names)
          return unless call_node.receiver.nil?
          return unless SHADOWING_DSL.include?(call_node.name)

          arg = call_node.arguments&.arguments&.first
          name = Rigor::Source::Literals.symbol_name(arg)
          if name
            names << name
          elsif call_node.name == :subject && call_node.arguments.nil?
            # Bare `subject { ... }` defines `:subject` itself.
            names << "subject"
          end
        end

        # `*_path` / `*_url` calls without an explicit receiver. Calls like `obj.users_path` or
        # `Foo::users_path` are NOT route-helper invocations in Rails — controllers / views call helpers
        # implicitly.
        def implicit_helper_call?(node)
          node.receiver.nil? && (node.name.to_s.end_with?("_path") || node.name.to_s.end_with?("_url"))
        end

        # Paths where the implicit-params-fill pattern is idiomatic — controllers / mailers / views
        # routinely call `*_path` / `*_url` helpers with fewer args than the route's static placeholder
        # count because Rails fills `:foo_id` segments from `request.params` at runtime (controllers /
        # views) or from the call's polymorphic-friendly receiver (mailers).
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

        def info_violation(entry)
          method_label = entry.http_method ? entry.http_method.to_s.upcase : "*"
          Violation.new(
            severity: :info,
            rule: "helper",
            message: "`#{entry.name}` → #{method_label} #{entry.path}"
          )
        end

        def arity_violation(call_node, entry, helper_table, path)
          args = call_node.arguments&.arguments || []
          actual = args.size
          # Uncountable nouns (`news` / `series` / `media`) cause Rails to register two entries under the
          # same helper name — `news_path` accepts both arity 0 (index) and arity 1 (show). The HelperTable
          # multimap stores both; accepts_arity? checks the full set.
          return nil if helper_table.accepts_arity?(entry.name, actual)

          # Rails accepts a kwargs-only call shape that supplies route segments by name:
          #   short_account_status_url(account_username: u, id: i)
          # for the route `/@:account_username/:id` (arity 2). Our positional-arg count is 1 (the
          # KeywordHashNode), so the strict check rejects — but Rails would resolve every segment from the
          # hash. When the call has a trailing KeywordHashNode AND the positional count (excluding it) is
          # `<= expected_arity`, accept — the kwargs may carry the missing segments.
          if args.last.is_a?(Prism::KeywordHashNode)
            positional = actual - 1
            return nil if helper_table.acceptable_arities(entry.name).any? { |exp| positional <= exp }
          end

          # Underflow tolerance for controllers / mailers / views. A `redirect_to
          # namespace_project_milestones_path` inside `Projects::MilestonesController` legitimately passes
          # 0 args — Rails fills the missing `:namespace_id` / `:project_id` segments from `request.params`
          # at runtime. Mailers reach helpers polymorphically too (`project_commit_url(commit)` resolves
          # project from commit.project). Silence when `actual < min_arity` AND the call site is in a
          # controller / mailer / view directory (where the implicit-params-fill pattern is idiomatic).
          # Overflow (`actual > max_arity`) still fires — that's almost always a typo.
          arities_set = helper_table.acceptable_arities(entry.name)
          min_arity = arities_set.min
          return nil if actual < min_arity && implicit_fill_path?(path)

          arities = arities_set.sort
          expected = arities.length == 1 ? arities.first.to_s : "#{arities.first}..#{arities.last}"
          Violation.new(
            severity: :error,
            rule: "wrong-arity",
            message: "`#{entry.name}` expects #{expected} argument(s), got #{actual}"
          )
        end

        def unknown_helper_violation(name, helper_table)
          # ADR-39 / boilerplate 0c — the shared DidYouMean-backed suggester replaces the hand-rolled
          # Levenshtein this module used to carry.
          suggestion = Rigor::Plugin::Base.suggest(name, helper_table.names)
          message = "no route helper `#{name}`"
          message += " (did you mean `#{suggestion}`?)" if suggestion

          Violation.new(
            severity: :error,
            rule: "unknown-helper",
            message: message
          )
        end
      end
    end
  end
end
