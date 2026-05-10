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

        # Phase 2 — filter-chain DSL methods. Each takes a
        # variadic list of filter names (Symbols / Strings) plus
        # optional `only:` / `except:` / `if:` / `unless:`
        # modifiers. The validation key is the filter NAMES; the
        # modifiers are accepted but their action-name argument
        # is not yet validated (Phase 2.5).
        FILTER_DSL_METHODS = %i[
          before_action after_action around_action
          skip_before_action skip_after_action skip_around_action
          prepend_before_action prepend_after_action prepend_around_action
        ].freeze

        # Phase 3 — render-target template extensions checked
        # in priority order. Limited to the two most common
        # default extensions per the v0.1.x roadmap; users with
        # `.haml` / `.slim` / `.jbuilder` setups need the
        # widening slice that ships configurable template
        # families.
        RENDER_TEMPLATE_EXTENSIONS = %w[.html.erb .text.erb].freeze

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

        # Phase 2 — filter-chain validation. Walks the file's
        # top-level class node, looks it up in the controller
        # index to get the effective method set (including
        # one level of inheritance), and validates that every
        # `before_action :name` reference resolves to a defined
        # method. Files that don't contain a known controller
        # contribute no diagnostics.
        def diagnose_filters(path:, root:, controller_index:)
          class_node = first_class_node(root)
          return [] if class_node.nil?

          class_name = qualified_name_for(class_node.constant_path)
          return [] if class_name.nil?
          return [] unless controller_index.known?(class_name)

          methods = controller_index.effective_methods_for(class_name)
          spell_checker = DidYouMean::SpellChecker.new(dictionary: methods.map(&:to_s))

          collect_filter_diagnostics(path, class_node.body, methods, spell_checker)
        end

        def collect_filter_diagnostics(path, body, methods, spell_checker)
          diagnostics = []
          walk_filter_calls(body) do |call_node|
            filter_name_args(call_node).each do |arg_node|
              filter_name = literal_symbol_or_string(arg_node)
              next if filter_name.nil?

              diag = filter_lookup_diagnostic(path, call_node, arg_node, filter_name, methods, spell_checker)
              diagnostics << diag if diag
            end
          end
          diagnostics
        end

        def filter_lookup_diagnostic(path, call_node, arg_node, filter_name, methods, spell_checker)
          if methods.include?(filter_name.to_sym)
            filter_call_diagnostic(path, call_node, filter_name)
          else
            unknown_filter_diagnostic(path, arg_node, call_node, filter_name, spell_checker)
          end
        end

        def walk_filter_calls(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode) && node.receiver.nil? && FILTER_DSL_METHODS.include?(node.name)
          node.compact_child_nodes.each { |child| walk_filter_calls(child, &) }
        end

        # Drops the trailing keyword hash (`only:` / `except:` /
        # `if:` / `unless:`) so the modifier args don't get
        # treated as filter names.
        def filter_name_args(call_node)
          args = call_node.arguments&.arguments || []
          args = args[0..-2] if args.last.is_a?(Prism::KeywordHashNode)
          args
        end

        def literal_symbol_or_string(node)
          case node
          when Prism::SymbolNode then node.value
          when Prism::StringNode then node.unescaped
          end
        end

        def first_class_node(node)
          return nil unless node.is_a?(Prism::Node)
          return node if node.is_a?(Prism::ClassNode)

          node.compact_child_nodes.each do |child|
            found = first_class_node(child)
            return found if found
          end
          nil
        end

        def qualified_name_for(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent.nil? ? nil : qualified_name_for(node.parent)
            return nil if !node.parent.nil? && parent.nil?

            parent.nil? ? node.name.to_s : "#{parent}::#{node.name}"
          end
        end

        # Phase 3 — render-target validation. For each
        # explicit `render` call inside a controller method,
        # derive the candidate view template path(s) from the
        # controller class name + the render argument shape,
        # then check existence under the configured
        # `view_search_paths` (default `["app/views"]`). Recognised
        # call shapes:
        #
        # - `render :symbol` — `<views>/<controller_path>/<symbol>.html.erb`
        # - `render "string/path"` — `<views>/<string_path>.html.erb`
        # - `render partial: "name"` — `<views>/<controller_path>/_<name>.html.erb`
        # - `render partial: "string/path"` — `<views>/<string_path with _ prefix>.html.erb`
        #
        # `render layout:`, `render plain:`, `render json:`,
        # `render text:`, `render inline:`, `render :nothing
        # => true`, etc. are pass-through (no template
        # lookup). Implicit-render (a controller method that
        # doesn't call `render`) is also skipped — Phase 3
        # validates explicit renders only, since the implicit
        # path would false-positive on `redirect_to` / `head`
        # / early returns.
        def diagnose_renders(path:, root:, view_search_roots:)
          class_node = first_class_node(root)
          return [] if class_node.nil?

          class_name = qualified_name_for(class_node.constant_path)
          return [] if class_name.nil?

          controller_path = controller_path_for(class_name)
          return [] if controller_path.nil?

          collect_render_diagnostics(path, class_node.body, controller_path, view_search_roots)
        end

        def collect_render_diagnostics(path, body, controller_path, view_search_roots)
          diagnostics = []
          walk_render_calls(body) do |call_node|
            target = render_target_for(call_node, controller_path)
            next if target.nil?

            diag = render_diagnostic(path, call_node, target, view_search_roots)
            diagnostics << diag if diag
          end
          diagnostics
        end

        def walk_render_calls(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :render
          node.compact_child_nodes.each { |child| walk_render_calls(child, &) }
        end

        # Returns `[kind, view_relative_path]` where kind is
        # `:template` or `:partial`, and view_relative_path is
        # the path under view_search_roots WITHOUT extension
        # (the extension family is appended at lookup time).
        # Returns nil for shapes Phase 3 doesn't validate
        # (`layout:` / `plain:` / `json:` / `text:` / `inline:`
        # / `:nothing` / no parseable target).
        def render_target_for(call_node, controller_path)
          args = call_node.arguments&.arguments || []
          return nil if args.empty?

          first = args.first
          # `render partial: "..."` — the keyword form.
          return partial_target_from_kwargs(first, controller_path) if first.is_a?(Prism::KeywordHashNode)

          # `render :symbol` / `render "path"`. A trailing
          # KeywordHashNode is allowed (e.g. `render :show,
          # status: :ok`); the leading positional carries the
          # template name.
          template_target_from_positional(first, controller_path)
        end

        def template_target_from_positional(node, controller_path)
          case node
          when Prism::SymbolNode then [:template, "#{controller_path}/#{node.value}"]
          when Prism::StringNode
            stripped = node.unescaped
            stripped.include?("/") ? [:template, stripped] : [:template, "#{controller_path}/#{stripped}"]
          end
        end

        def partial_target_from_kwargs(hash_node, controller_path)
          partial_value = hash_node.elements.find do |elem|
            elem.is_a?(Prism::AssocNode) &&
              elem.key.is_a?(Prism::SymbolNode) &&
              elem.key.value == "partial"
          end&.value
          return nil unless partial_value.is_a?(Prism::StringNode)

          stripped = partial_value.unescaped
          if stripped.include?("/")
            dir, base = File.split(stripped)
            [:partial, "#{dir}/_#{base}"]
          else
            [:partial, "#{controller_path}/_#{stripped}"]
          end
        end

        # `UsersController` → "users".
        # `Admin::WidgetsController` → "admin/widgets".
        # Returns nil for class names that don't end with the
        # `Controller` suffix.
        def controller_path_for(class_name)
          return nil unless class_name.end_with?("Controller")

          stripped = class_name.delete_suffix("Controller")
          stripped.split("::").map { |segment| underscore(segment) }.join("/")
        end

        # Tiny inflector — sufficient for the typical
        # `WordWord` → `word_word` mapping. Doesn't try to
        # handle acronyms (`HTTPController` would inflect to
        # `h_t_t_p`); users with that need can ship a
        # configured override in a follow-up slice.
        def underscore(camel)
          camel.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
               .gsub(/([a-z\d])([A-Z])/, '\1_\2')
               .downcase
        end

        def render_diagnostic(path, call_node, target, view_search_roots)
          kind, relative = target
          existing = locate_template(relative, view_search_roots)
          if existing
            render_target_diagnostic(path, call_node, kind, relative, existing)
          else
            missing_template_diagnostic(path, call_node, kind, relative, view_search_roots)
          end
        end

        def locate_template(relative, view_search_roots)
          view_search_roots.each do |root|
            RENDER_TEMPLATE_EXTENSIONS.each do |ext|
              candidate = File.join(root, "#{relative}#{ext}")
              return candidate if File.file?(candidate)
            end
          end
          nil
        end

        def render_target_diagnostic(path, call_node, kind, relative, located)
          loc = call_node.message_loc || call_node.location
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: "Action Pack render #{kind} `#{relative}` resolved to `#{located}`.",
            severity: :info, rule: "render-target"
          )
        end

        def missing_template_diagnostic(path, call_node, kind, relative, view_search_roots)
          loc = call_node.message_loc || call_node.location
          tried = RENDER_TEMPLATE_EXTENSIONS.map { |ext| "#{relative}#{ext}" }.join(", ")
          roots = view_search_roots.join(", ")
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: "Action Pack render #{kind} `#{relative}` not found under #{roots} " \
                     "(tried #{tried}).",
            severity: :error, rule: "missing-template"
          )
        end

        def filter_call_diagnostic(path, call_node, filter_name)
          loc = call_node.message_loc || call_node.location
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: "Action Pack filter `#{call_node.name} :#{filter_name}` resolves to a defined method.",
            severity: :info, rule: "filter-call"
          )
        end

        def unknown_filter_diagnostic(path, arg_node, call_node, filter_name, spell_checker)
          loc = arg_node.location
          base = "Action Pack filter `#{call_node.name} :#{filter_name}` references no method " \
                 "defined on this controller (or its parent)."
          suggestion = spell_checker.correct(filter_name.to_s).first
          message = suggestion ? "#{base} Did you mean `:#{suggestion}`?" : base
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: message, severity: :error, rule: "unknown-filter-method"
          )
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
