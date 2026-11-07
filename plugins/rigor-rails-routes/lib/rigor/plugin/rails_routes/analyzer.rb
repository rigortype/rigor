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

        # The route-helper violations for a single call node (0..2), or `[]` when the node is not an
        # implicit `*_path` / `*_url` helper call, is shadowed by a same-file binding, or is in a
        # suppressed directory. ADR-37: the engine owns the walk; the same-file `shadowing` set is built
        # once as the node-rule file context.
        def violations_for(call_node:, helper_table:, shadowing:, path:, scope: nil, context: nil)
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
          elsif self_resolves_method?(name, scope, context)
            []
          else
            [unknown_helper_violation(name, helper_table)]
          end
        end

        # True when `name` is already a method on the call's `self`, asked of the engine rather than a
        # plugin-side name list: the project's discovered methods (`def`, `attr_*`, the singleton side) through
        # the project's own ancestry, then the RBS ancestry. A truncated project walk (`maybe`) declines too —
        # a definer past the budget cannot be ruled out, and a false positive outranks a missed typo.
        #
        # `self` is read from the node's lexical ancestors (`NodeContext#ancestors`), because the scope a
        # `node_rule` receives is the file's, not the call site's. {#call_site_selves} returns the candidate
        # `[class_name, kind]` pairs, `:undetermined` where `self` cannot be named (a block in a class body, a
        # `def obj.m`), and `[]` outside any class or module, which leaves the route-table verdict as it was.
        def self_resolves_method?(name, scope, context)
          return false if scope.nil? || context.nil?

          selves = call_site_selves(context.ancestors)
          return true if selves == :undetermined

          selves.any? do |class_name, kind|
            !Rigor::Reflection.project_method_defined(class_name, name, kind: kind, source: :either,
                                                                        scope: scope).no? ||
              rbs_ancestor_defines?(class_name, name, kind, scope) || framework_ancestor_defines?(class_name, name, kind, scope)
          end
        end

        # Rails' own `*_path` / `*_url` methods on a controller or mailer, read from the Rails source (rails/rails
        # main, 1105756f42). They are instance methods (or class methods, for `controller_path` and the view-path
        # writers) of the framework base classes, and a project without that framework's RBS cannot see them
        # through the ancestry, so a class that reaches one of these bases declines for exactly these names:
        #
        # - `controller_path`: actionpack/lib/abstract_controller/base.rb:157 (instance), :117 (class).
        # - `append_view_path` / `prepend_view_path`: actionview/lib/action_view/view_paths.rb:113, :124 (instance),
        #   :46, :57 (class); mixed into `AbstractController::Base` through `ActionView::ViewPaths`.
        # - `helpers_path`: actionpack/lib/action_controller/metal/helpers.rb:64 (class accessor).
        # - `edit_` / `new_` `polymorphic_path` / `polymorphic_url`: actionpack/lib/action_dispatch/routing/
        #   polymorphic_routes.rb:163-166 (`polymorphic_path` / `polymorphic_url` are in {BUILTIN_PASSTHROUGH}).
        FRAMEWORK_METHOD_NAMES = %w[
          controller_path append_view_path prepend_view_path helpers_path
          edit_polymorphic_path edit_polymorphic_url new_polymorphic_path new_polymorphic_url
        ].freeze

        # The classes that define {FRAMEWORK_METHOD_NAMES}: `AbstractController::Base`
        # (actionpack/lib/abstract_controller/base.rb:35) and what inherits from it, `ActionController::Metal`
        # (actionpack/lib/action_controller/metal.rb:185), `::Base` (action_controller/base.rb:206), `::API`
        # (action_controller/api.rb:91) and `ActionMailer::Base` (actionmailer/lib/action_mailer/base.rb:479).
        FRAMEWORK_BASES = %w[
          AbstractController::Base ActionController::Metal ActionController::Base ActionController::API
          ActionMailer::Base
        ].freeze

        # RBS declares `name` on `class_name` or on an ancestor its project ancestry reaches. A project class is
        # rarely in RBS itself, so this walks its `ResolutionChain` to the entries RBS knows (every candidate
        # spelling of an external one) and asks RBS of each on the side the entry sits; RBS's definition of an
        # ancestor already includes what it inherits. A truncated chain declines (true): a definer past the budget
        # cannot be ruled out.
        def rbs_ancestor_defines?(class_name, name, kind, scope)
          chain = Rigor::Scope::ResolutionChain.for(scope, class_name.to_s, kind, :methods)
          found = chain.search(scope) do |entry|
            chain_entry_names(entry).any? { |candidate| !rbs_method_definition(candidate, name, entry.side, scope).nil? }
          end
          found ? true : chain.truncated?
        end

        # True when `class_name`'s ancestry reaches a Rails framework base and `name` is one of the methods the
        # framework defines ({FRAMEWORK_METHOD_NAMES}), whether or not RBS for it is loaded.
        def framework_ancestor_defines?(class_name, name, kind, scope)
          return false unless FRAMEWORK_METHOD_NAMES.include?(name)

          chain = Rigor::Scope::ResolutionChain.for(scope, class_name.to_s, kind, :methods)
          hit = chain.search(scope) do |entry|
            chain_entry_names(entry).any? { |candidate| FRAMEWORK_BASES.include?(candidate.to_s.delete_prefix("::")) }
          end
          !hit.nil?
        end

        def rbs_method_definition(class_name, name, side, scope)
          if side == :singleton
            Rigor::Reflection.singleton_method_definition(class_name, name, scope: scope)
          else
            Rigor::Reflection.instance_method_definition(class_name, name, scope: scope)
          end
        end

        def chain_entry_names(entry)
          entry.external? ? entry.candidates : [entry.name]
        end

        # Candidate `[class_name, kind]` selves for a node under `ancestors` (outermost first), `[]` when the
        # node is in no class or module, `:undetermined` when its `self` cannot be named syntactically.
        def call_site_selves(ancestors)
          owner_index = ancestors.rindex { |n| n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode) }
          return [] if owner_index.nil?

          kind = self_kind(ancestors[(owner_index + 1)..])
          return :undetermined if kind.nil?

          names = owner_names(ancestors, owner_index)
          return :undetermined if names.empty?

          names.map { |class_name| [class_name, kind] }
        end

        # `:instance` / `:singleton` for the `self` of a node under the nodes between its class and itself, or
        # nil when undeterminable. The nearest `def` decides (blocks inside a method keep its `self`); with no
        # `def`, a block or lambda in the class body may run on another object (`included do`, `scope`,
        # `Class.new`), and a bare body is the class object itself.
        def self_kind(inner)
          def_index = inner.rindex { |n| n.is_a?(Prism::DefNode) }
          if def_index
            node = inner[def_index]
            return nil if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
            return :singleton if node.receiver

            return inner[0...def_index].any?(Prism::SingletonClassNode) ? :singleton : :instance
          end
          return nil if inner.any? { |n| block_scope?(n) }
          return nil if inner.any? { |n| n.is_a?(Prism::SingletonClassNode) && !n.expression.is_a?(Prism::SelfNode) }

          :singleton
        end

        def block_scope?(node)
          node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)
        end

        # The names the enclosing class or module can be known by. A bare `class Foo` is nested under the
        # enclosing modules; `class Foo::Bar` may name `Foo` lexically or at the root, so both are tried. A
        # rooted declaration (`class ::Foo`) names the root constant alone.
        def owner_names(ancestors, owner_index)
          chain = ancestors[0..owner_index].select { |n| n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode) }
          names = [""]
          chain.each do |decl|
            local = declared_name(decl.constant_path)
            return [] if local.nil?

            names = if local.start_with?("::")
                      [local.delete_prefix("::")]
                    else
                      names.flat_map { |prefix| [prefix.empty? ? local : "#{prefix}::#{local}", local] }.uniq
                    end
          end
          names
        end

        def declared_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            return "::#{node.name}" if node.parent.nil?

            parent = declared_name(node.parent)
            parent && "#{parent}::#{node.name}"
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
          # ADR-39 / boilerplate 0c — the shared DidYouMean-backed suggester.
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
