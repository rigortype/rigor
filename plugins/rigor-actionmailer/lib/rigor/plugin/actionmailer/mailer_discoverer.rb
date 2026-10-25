# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"
require "rigor/source/literals"

require_relative "mailer_index"

module Rigor
  module Plugin
    class Actionmailer < Rigor::Plugin::Base
      # Walks the configured mailer-search paths via the plugin's `IoBoundary`, parses each `.rb` file
      # with Prism, and collects classes whose immediate superclass is one of the configured base
      # classes.
      #
      # For each discovered class, the discoverer:
      #
      # - Reads the instance-side `def` nodes and records each one as an action method, capturing the
      #   arity envelope.
      # - For each (class, action) pair, attempts to read every candidate view template under
      #   `app/views/<mailer_underscore>/<action>.{html,text}.{erb,haml,slim}`. Existing templates feed the
      #   IoBoundary's cache descriptor (so the cache invalidates when the template changes); missing
      #   templates are recorded so the plugin can surface a diagnostic on the action's `def`.
      #
      # Limitations (intentional for v0.1.0):
      #
      # - Direct-superclass match only. `class CustomerMailer < BaseMailer` where `BaseMailer <
      #   ApplicationMailer` is NOT discovered. Add `BaseMailer` to `mailer_base_classes` if needed.
      # - Action methods are read from the syntactic instance-side `def` list. Methods built via
      #   `define_method`, `private`, or non-action helpers (e.g. methods starting with `_`) are out of
      #   scope. The discoverer filters obvious non-actions (`initialize`, names prefixed with `_`).
      class MailerDiscoverer
        DEFAULT_VIEWS_ROOT = "app/views"
        VIEW_FORMATS = %w[html text].freeze
        VIEW_EXTENSIONS = %w[erb haml slim].freeze

        # @param search_paths — absolute or project-relative paths to scan for mailers.
        # @param base_classes — direct superclasses that mark a class as a mailer.
        # @param views_root — absolute or project-relative path to the views directory (typically
        #   `app/views`).
        def initialize(io_boundary:, search_paths:, base_classes:, views_root: DEFAULT_VIEWS_ROOT)
          @io_boundary = io_boundary
          @search_paths = search_paths
          # De-rooted for the same reason superclass names are ({#visit_class}): the match is by exact
          # spelling, so a configured `mailer_base_classes: ["::ApplicationMailer"]` would otherwise never
          # match anything a declaration can render.
          @base_classes = base_classes.to_set { |name| strip_root(name.to_s) }
          @views_root = views_root
        end

        def discover
          # Two-pass: first collect every module's defs (for the include-following step), then build
          # per-class entries that pull in actions from include'd modules. GitLab's `Notify` mailer
          # derives every action from `Emails::*` concerns under `app/mailers/emails/`.
          module_actions = {} # fully-qualified module name => its action entries, keyed by method name
          class_visits = []   # collected (class_name, path, def_nodes, includes, view_exempt)

          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_mailers(tree, []) do |class_name, def_nodes, includes, view_exempt|
              class_visits << [class_name, path, def_nodes, includes, view_exempt]
            end
            collect_module_actions(tree, [], module_actions)
          end

          entries = class_visits.map do |class_name, path, def_nodes, includes, view_exempt|
            build_class_entry(class_name, path, def_nodes, includes, module_actions, view_exempt)
          end
          MailerIndex.new(entries)
        end

        private

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        def ruby_files_under(roots)
          roots.flat_map do |root|
            absolute = File.expand_path(root)
            # ADR-45 WD1b (#613) — boundary-probed: a root that appears later invalidates the warm run.
            next [] unless @io_boundary.directory?(absolute)

            Dir.glob("**/*.rb", base: absolute).map { |path| File.join(absolute, path) }
          end
        end

        def walk_for_mailers(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.rigor_each_child { |child| walk_for_mailers(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = declared_constant_name(class_local_name, lexical_path)
          superclass = strip_root(constant_path_name(node.superclass)) if node.superclass
          if superclass && @base_classes.include?(superclass)
            def_nodes, view_exempt = collect_action_defs(node.body)
            includes = collect_includes(node.body)
            yield full_name, def_nodes, includes, view_exempt
          end

          walk_for_mailers(node.body, [full_name], &) if node.body
        end

        # Collects qualified-constant names passed to `include X` calls inside the class body. Used to
        # look up concern-module action definitions (GitLab's `Notify` mailer derives every action from
        # `Emails::Issues`, `Emails::MergeRequests`, etc.).
        def collect_includes(body)
          return [] if body.nil?

          names = []
          body.rigor_each_child do |node|
            next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :include

            (node.arguments&.arguments || []).each do |arg|
              name = strip_root(constant_path_name(arg))
              names << name if name
            end
          end
          names
        end

        # Walks the AST collecting every module's instance-side def nodes by fully-qualified module
        # name. The same `collect_action_defs` filter applies (private / `_`-prefixed skipped; callback targets
        # stay actions and carry the view exemption).
        def collect_module_actions(node, lexical_path, accumulator)
          return if node.nil?

          case node
          when Prism::ModuleNode
            local_name = constant_path_name(node.constant_path)
            return if local_name.nil?

            full_name = declared_constant_name(local_name, lexical_path)
            if node.body
              def_nodes, view_exempt = collect_action_defs(node.body)
              entries = def_nodes.to_h do |def_node|
                [def_node.name, build_action_entry(def_node, view_exempt.include?(def_node.name))]
              end
              # UNIONed, never assigned: a concern module reopened in a second file adds actions rather
              # than replacing the ones the first declaration spelled (same rule as {MailerIndex}'s
              # per-class merge).
              accumulator[full_name] = (accumulator[full_name] || {}).merge(entries) unless entries.empty?
              collect_module_actions(node.body, [full_name], accumulator)
            end
          when Prism::ClassNode
            local_name = constant_path_name(node.constant_path)
            inner = local_name ? [declared_constant_name(local_name, lexical_path)] : lexical_path
            collect_module_actions(node.body, inner, accumulator) if node.body
          else
            node.rigor_each_child { |child| collect_module_actions(child, lexical_path, accumulator) }
          end
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = [declared_constant_name(module_local_name, lexical_path)]
          walk_for_mailers(node.body, inner_path, &) if node.body
        end

        # The full constant name a `class` / `module` declaration defines, given the rendered local name
        # and the enclosing lexical path. A ROOTED local name (`class ::UserMailer`) names the top-level
        # constant whatever the nesting, so the lexical path is dropped and the `::` with it; otherwise the
        # name is appended to the path (`class UserMailer` inside `module Admin` → `Admin::UserMailer`).
        def declared_constant_name(local_name, lexical_path)
          return strip_root(local_name) if local_name.start_with?("::")

          (lexical_path + [local_name]).join("::")
        end

        # `::UserMailer` → `UserMailer`; a name without the root marker is returned unchanged (nil stays nil).
        def strip_root(name)
          name&.delete_prefix("::")
        end

        # Renders a constant-path node as a String, KEEPING the leading `::` of a rooted path —
        # {#declared_constant_name} reads it as "reset the lexical path" before the marker is dropped.
        def constant_path_name(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
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

        # Returns the instance-side `def` nodes that look like mailer actions. Filters non-actions:
        # - `initialize`
        # - methods starting with `_` (Ruby convention for private/internal)
        # - `def self.<name>` (singleton-side)
        # - methods that are not public at the end of the class body, read in source order: after a bare
        #   `private` / `protected` (until a `public` switches back), named by `private :foo` /
        #   `protected :foo`, or defined inline (`private def foo`) — Rails builds `action_methods` from the
        #   public instance methods. `public :foo` after a `protected` section makes `foo` an action again.
        # Methods named by a callback or `helper_method` macro (see {#collect_callback_names}) stay actions:
        # Rails dispatches any public instance method, so `Mailer.target` still runs. They are returned as the
        # view-exempt names, which exempt them from the missing-view check only.
        #
        # Pre-fix, Mastodon's `AdminMailer#process_params` / `set_instance` / `set_locale` /
        # `set_important_headers!` all surfaced as missing-view because the bare `private` keyword
        # wasn't honoured. ~19 false positives across Mastodon's mailers.
        VISIBILITY_KEYWORDS = %i[public private protected module_function].freeze
        private_constant :VISIBILITY_KEYWORDS

        # Returns `[action_def_nodes, view_exempt_names]`. The view-exempt names are the callback and
        # `helper_method` targets of the body: they remain actions, and only the missing-view check skips them.
        def collect_action_defs(body)
          return [[], Set[]] if body.nil?

          callback_names = collect_callback_names(body)
          def_nodes, final_visibility = scan_visibility(body)

          actions = def_nodes.select do |node|
            next false if node.receiver.is_a?(Prism::SelfNode)
            next false if node.name == :initialize
            next false if node.name.to_s.start_with?("_")

            # Rails builds `action_methods` from the PUBLIC instance methods, so only a method whose final
            # visibility is public is an action.
            final_visibility[node.name] == :public
          end
          [actions, callback_names]
        end

        # Symbol arguments to the macros the manifest's `per_invocation_non_action_macros` lists (`before_action
        # :setup`, `after_deliver :record`, `helper_method :fmt`). The `skip_*` forms are left out, since
        # `skip_before_action :x` names a callback a parent defined and does not exempt `x` from anything (#2319).
        def collect_callback_names(body)
          macros = Actionmailer.manifest.per_invocation_non_action_macros.reject { |macro| macro.start_with?("skip_") }
          names = []
          body.rigor_each_child do |node|
            next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && macros.include?(node.name)

            (node.arguments&.arguments || []).each do |arg|
              symbol = Rigor::Source::Literals.symbol(arg)
              names << symbol if symbol
            end
          end
          names.to_set
        end

        # Walks the class body in source order and returns `[def_nodes, final_visibility]`: every `def` the body
        # spells (a direct statement or the inline argument of a visibility call, `private def x`), and the
        # visibility each method name ends with. A bare `public` / `private` / `protected` / `module_function` sets
        # the default for the defs after it; `private :x` / `public :x` / `protected def x` set that one method, whichever side of
        # its `def` they fall on in the source, and the last statement to name a method wins.
        def scan_visibility(body)
          def_nodes = []
          final_visibility = {}
          default = :public

          body.compact_child_nodes.each do |node|
            case node
            when Prism::DefNode
              def_nodes << node
              final_visibility[node.name] = default
            when Prism::CallNode
              default = apply_visibility_call(node, default, def_nodes, final_visibility)
            end
          end

          [def_nodes, final_visibility]
        end

        # Applies one receiverless `public` / `private` / `protected` / `module_function` call and returns the
        # (possibly new) default.
        def apply_visibility_call(node, default, def_nodes, final_visibility)
          return default unless node.receiver.nil? && VISIBILITY_KEYWORDS.include?(node.name)

          args = node.arguments&.arguments || []
          return node.name if args.empty?

          args.flat_map { |arg| arg.is_a?(Prism::ArrayNode) ? arg.elements : [arg] }.each do |arg|
            if arg.is_a?(Prism::DefNode)
              def_nodes << arg
              final_visibility[arg.name] = node.name
            elsif (name = Rigor::Source::Literals.symbol_or_string(arg))
              final_visibility[name] = node.name
            end
          end
          default
        end

        def build_class_entry(class_name, file_path, def_nodes, includes = [], module_actions = {}, view_exempt = Set[])
          actions = def_nodes.to_h do |def_node|
            entry = build_action_entry(def_node, view_exempt.include?(def_node.name))
            [entry.method_name, entry]
          end

          # Merge actions from include'd modules (pre-collected in `module_actions` keyed by
          # fully-qualified name). Unresolvable includes are tracked; `unresolved_includes?` (consumed
          # by the analyzer) downgrades `unknown-action` to silence when any include remains unresolved.
          unresolved_includes = []
          includes.each do |include_name|
            inc_actions = module_actions[include_name]
            if inc_actions.nil?
              unresolved_includes << include_name
              next
            end

            inc_actions.each do |method_name, entry|
              actions[method_name] ||= entry
            end
          end

          missing_views = actions.reject { |_, entry| entry.view_exempt }.keys.reject { |action| view_exists?(class_name, action) }

          MailerIndex::ClassEntry.new(
            class_name: class_name,
            file_path: file_path,
            actions: actions,
            missing_views: missing_views,
            unresolved_includes: unresolved_includes.freeze
          )
        end

        def build_action_entry(def_node, view_exempt = false)
          parameters = def_node.parameters
          location = def_node.name_loc

          if parameters.nil?
            return MailerIndex::ActionEntry.new(
              method_name: def_node.name,
              min_arity: 0, max_arity: 0,
              def_line: location.start_line,
              def_column: location.start_column + 1,
              view_exempt: view_exempt
            )
          end

          required_count = (parameters.requireds || []).size
          optional_count = (parameters.optionals || []).size
          rest_present = !parameters.rest.nil?

          MailerIndex::ActionEntry.new(
            method_name: def_node.name,
            min_arity: required_count,
            max_arity: rest_present ? Float::INFINITY : required_count + optional_count,
            def_line: location.start_line,
            def_column: location.start_column + 1,
            view_exempt: view_exempt
          )
        end

        # Checks whether *any* template under
        # `app/views/<underscore>/<action>.{html,text}.{erb,haml,slim}` exists, by attempting to read
        # each candidate via the IoBoundary. Successful reads are recorded by the boundary; failed reads
        # (missing file or access denied) are swallowed.
        def view_exists?(class_name, action_name)
          views_root_absolute = File.expand_path(@views_root)
          # ADR-39: the real ActiveSupport::Inflector resolves the mailer's view directory
          # (`Foo::BarMailer` → `foo/bar_mailer`), so a divergence from Rails' real underscore can't
          # point the missing-view check at the wrong directory.
          # `class_name` is already de-rooted ({#declared_constant_name}), so no root marker can reach the
          # inflection.
          underscore_path = Rigor::Plugin::Inflector.underscore(class_name)
          mailer_dir = File.join(views_root_absolute, underscore_path)

          VIEW_FORMATS.any? do |format|
            VIEW_EXTENSIONS.any? do |ext|
              candidate = File.join(mailer_dir, "#{action_name}.#{format}.#{ext}")
              read_safely(candidate)
            end
          end
        end
      end
    end
  end
end
