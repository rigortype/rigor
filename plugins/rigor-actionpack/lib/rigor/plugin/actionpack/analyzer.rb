# frozen_string_literal: true

require "did_you_mean"
require "prism"
require "rigor/source/literals"

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # Per-node validators for the Action Pack DSL inside controller
      # files. ADR-37: the engine owns the single AST walk (the plugin
      # declares `node_rule(Prism::CallNode)`), so each method here
      # validates ONE call node and returns location-bearing
      # {Violation}s — the `node_rule` block positions them via
      # `Plugin::Base#diagnostic`. The enclosing-controller context the
      # filter / render phases need is read from the node-rule
      # `NodeContext` ancestors rather than re-derived by a forward walk.
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

        # Phase 3 — render-target template extensions checked in
        # priority order. The first six cover the templating
        # engines used by the projects this plugin is regularly
        # exercised against: ERB (Rails default — `.html.erb`,
        # `.text.erb`), HAML (Mastodon, Solidus admin —
        # `.html.haml`), Slim, and JSON (`.json.jbuilder` plus a
        # raw `.json.erb` for hand-rolled API responses). When a
        # template exists under any of these extensions, the
        # missing-template diagnostic stays silent.
        # Configurable extension list is queued — see the
        # `external-author plugin SKILL` track (v0.2.0). For now
        # this set is wide enough to cover the surveyed real-world
        # projects without leaking FPs.
        RENDER_TEMPLATE_EXTENSIONS = %w[
          .html.erb
          .text.erb
          .html.haml
          .text.haml
          .html.slim
          .json.jbuilder
          .json.erb
          .xml.builder
          .xml.erb
        ].freeze

        # Phase 1 — strong-parameter call shapes that begin a
        # validatable chain. The walker matches the
        # `params.require(:user).permit(:name, :email)` chain
        # by looking for `:permit` call sites whose receiver is
        # `params.require(:symbol)`.
        STRONG_PARAMS_RECEIVER_NAMES = %i[require permit_params strong_params].freeze

        # One Action Pack observation. Carries no path — the caller
        # (the `node_rule` block) positions it via
        # `Plugin::Base#diagnostic`. `location` is the Prism location the
        # diagnostic should point at (a call's `message_loc` for the call
        # itself, or a sub-argument's location for `unknown-*-key`-style
        # diagnostics that point at the offending Symbol).
        Violation = Data.define(:location, :message, :severity, :rule)

        module_function

        # Phase 4 — route-helper consumption. The helper-existence /
        # arity check for ONE call node. Only the **info-level** route
        # resolution (`helper-call`) is the value this plugin adds — it
        # surfaces the resolved HTTP method + path + action alongside the
        # call site, which `rigor-rails-routes` does not. Unknown-helper
        # and wrong-arity diagnostics are produced canonically by
        # `rigor-rails-routes`'s own analyzer (same `:helper_table` source
        # of truth), so emitting them here would double every call-site
        # error. Real-world impact pre-fix: ~301 duplicates on Mastodon and
        # ~119 on Redmine, exactly stacked with the rails-routes
        # diagnostics. Returns `[]` for unknown / arity-mismatch shapes.
        #
        # @param call_node [Prism::Node]
        # @param helper_table [Hash{String => Hash}] each entry carries
        #   `name`, `arity`, `acceptable_arities`, `path`, `http_method`,
        #   `action`.
        # @return [Array<Violation>]
        def helper_violations_for(call_node:, helper_table:)
          return [] unless implicit_helper_call?(call_node)

          entry = helper_table[call_node.name.to_s]
          return [] if entry.nil?

          actual_arity = positional_arg_count(call_node)
          # The `:helper_table` fact entry carries both `:arity` (the
          # first registered entry's arity) and `:acceptable_arities`
          # (the full Array — populated for uncountable-noun resources
          # like `resources :news` which share a helper name across
          # index/show). Honour the full set; fall back to the single
          # arity for consumers compiled against an older fact shape.
          acceptable = entry[:acceptable_arities] || [entry[:arity]]
          return [] unless acceptable.include?(actual_arity)

          [helper_call_violation(call_node, entry)]
        end

        # Phase 2 — filter-chain validation for ONE filter-DSL call
        # (`before_action :name`, …). The enclosing controller is read
        # from the node-rule `NodeContext` ancestors, looked up in the
        # controller index to get the effective method set (including one
        # level of inheritance), and each filter name reference is
        # validated against it. Calls outside a known controller
        # contribute nothing.
        #
        # @param call_node [Prism::Node]
        # @param ancestors [Array<Prism::Node>] the lexical ancestor chain
        # @param controller_index [ControllerIndex]
        # @return [Array<Violation>]
        def filter_violations_for(call_node:, ancestors:, controller_index:)
          return [] unless filter_call?(call_node)

          class_name = enclosing_controller_name(ancestors)
          return [] if class_name.nil?
          return [] unless controller_index.known?(class_name)

          methods = controller_index.effective_methods_for(class_name)
          spell_checker = DidYouMean::SpellChecker.new(dictionary: methods.map(&:to_s))
          # When the controller (or its parent) `include`s a module the
          # discoverer couldn't resolve — typically a gem-shipped concern
          # such as `Devise::Controllers::Helpers` or
          # `Pundit::Authorization` — any `before_action :name` MIGHT be
          # defined in that unresolved module. Suppress
          # `unknown-filter-method` in that case rather than FPing on
          # legitimate gem-provided callback names.
          ambiguous_filters = controller_index.unresolved_include?(class_name)

          filter_name_args(call_node).filter_map do |arg_node|
            filter_name = literal_symbol_or_string(arg_node)
            next if filter_name.nil?

            filter_lookup_violation(
              call_node, arg_node, filter_name, methods, spell_checker,
              ambiguous_filters: ambiguous_filters
            )
          end
        end

        # Phase 1 — strong-parameter validation for ONE `permit` call.
        # Recognises the `params.require(:symbol).permit(:key, :key, ...)`
        # chain and validates each `:key` against the AR model's column
        # list (looked up via the model_index fact published by
        # `rigor-activerecord`). Calls whose `:require` argument is a
        # non-literal Symbol are passed through; namespaced models
        # (`params.require(:admin_user)` → `Admin::User`) are deferred to a
        # Phase 1.5 follow-up.
        #
        # @param call_node [Prism::Node]
        # @param model_index [Hash{String => Hash}]
        # @return [Array<Violation>]
        def permit_violations_for(call_node:, model_index:)
          return [] unless permit_chain?(call_node)

          model_class = model_class_for_permit(call_node)
          entry = model_index[model_class]
          return [] if entry.nil? # unknown model — skip; the model lookup is best-effort.

          columns = entry[:columns]
          spell_checker = DidYouMean::SpellChecker.new(dictionary: columns)
          literal_permit_keys(call_node).map do |key_node, key_name|
            if columns.include?(key_name)
              permit_call_violation(call_node, model_class, key_name)
            else
              unknown_permit_key_violation(key_node, model_class, key_name, spell_checker)
            end
          end
        end

        # Phase 3 — render-target validation for ONE `render` call. Derive
        # the candidate view template path(s) from the controller class
        # name + the render argument shape, then check existence under the
        # configured `view_search_paths` (default `["app/views"]`).
        # Recognised call shapes:
        #
        # - `render :symbol` — `<views>/<controller_path>/<symbol>.html.erb`
        # - `render "string/path"` — `<views>/<string_path>.html.erb`
        # - `render partial: "name"` — `<views>/<controller_path>/_<name>.html.erb`
        # - `render partial: "string/path"` — `<views>/<string_path with _ prefix>.html.erb`
        #
        # `render layout:`, `render plain:`, `render json:`, `render
        # text:`, `render inline:`, `render :nothing => true`, etc. are
        # pass-through (no template lookup). Implicit-render (a controller
        # method that doesn't call `render`) is also skipped — Phase 3
        # validates explicit renders only, since the implicit path would
        # false-positive on `redirect_to` / `head` / early returns.
        #
        # @param call_node [Prism::Node]
        # @param ancestors [Array<Prism::Node>] the lexical ancestor chain
        # @param path [String] file being analysed
        # @param view_search_roots [Array<String>]
        # @param controller_index [ControllerIndex, nil]
        # @return [Array<Violation>]
        def render_violations_for(call_node:, ancestors:, path:, view_search_roots:, controller_index: nil)
          return [] unless render_call?(call_node)

          class_name = enclosing_controller_name(ancestors)
          return [] if class_name.nil?

          # Prefer the file-path-derived controller path when the source
          # lives under `app/controllers/` — Rails autoload is the runtime
          # authority on `Admin::Users::RolesController` vs
          # `Users::RolesController` (a declaration like `module Admin;
          # class Users::RolesController` resolves to whichever `Users`
          # constant Ruby finds first, and the file path is the
          # disambiguator Rails picks). Fall back to the AST-derived class
          # name for files outside `app/controllers/` (libraries, test
          # fixtures).
          controller_path = controller_path_from_file(path) || controller_path_for(class_name)
          return [] if controller_path.nil?

          # Render checks silence when the controller (or its ancestor
          # chain) inherits from a gem-shipped parent
          # (Devise::ConfirmationsController,
          # Doorkeeper::ApplicationsController, …). The gem ships its own
          # views; the local subclass calling `render :show` resolves
          # through the gem's view path, which our static analyser doesn't
          # know about.
          if controller_index&.known?(class_name) &&
             controller_index.unresolved_include?(class_name)
            return []
          end

          # Abstract base controllers: a `*BaseController` (`Admin::
          # BaseController`, `Settings::Preferences::BaseController`, …)
          # typically has no view of its own; its `render :show` bodies
          # are resolved by Rails against the calling subclass's
          # controller path at request time, NOT the base's. Same for
          # parent controllers whose view directory exists but contains
          # only subdirectories (Mastodon's `Admin::SettingsController`
          # whose `app/views/admin/settings/` holds about/, appearance/,
          # … but no top-level templates). Skip render checks for these —
          # the diagnostic would be a false positive against intentional
          # Rails abstract-base layouts.
          return [] if abstract_base_controller?(class_name, controller_path, view_search_roots)

          target = render_target_for(call_node, controller_path)
          return [] if target.nil?

          violation = render_violation(call_node, target, view_search_roots)
          violation ? [violation] : []
        end

        # Resolves the qualified name of the controller class the node
        # sits in from its lexical ancestors (the node-rule
        # `NodeContext#ancestors`, outermost first). The OUTERMOST
        # `ClassNode` is the controller — matching the old forward walk,
        # which returned the first `ClassNode` reachable from the file
        # root and validated nested-class call sites against it. Enclosing
        # `ModuleNode`s above it contribute the namespace, so the
        # nested-module declaration shape
        #
        #   module Admin
        #     class DomainBlocksController < BaseController
        #     end
        #   end
        #
        # is recovered as `Admin::DomainBlocksController` — the same name
        # the `ControllerDiscoverer` registers under. Without this, a bare
        # inner-class name would be used for index lookups +
        # `controller_path_for`, silently skipping filter validation and
        # pointing render template paths at the wrong directory
        # (Mastodon's `admin/domain_blocks` rendered as bare
        # `domain_blocks`). Returns nil when no enclosing class exists.
        def enclosing_controller_name(ancestors)
          class_index = ancestors.index { |n| n.is_a?(Prism::ClassNode) }
          return nil if class_index.nil?

          class_node = ancestors[class_index]
          enclosing = ancestors[0...class_index]
                      .grep(Prism::ModuleNode)
                      .flat_map { |n| namespace_segments_for(n) }
          qualified_name_with_enclosing(class_node.constant_path, enclosing)
        end

        def namespace_segments_for(declaration_node)
          path = qualified_name_for(declaration_node.constant_path)
          path ? path.split("::") : []
        end

        # Resolves a class-name AST node against an enclosing namespace
        # chain. A `ConstantPathNode` (e.g. `class Admin::Foo`) is already
        # absolute and ignores the chain; a `ConstantReadNode` (bare
        # `class Foo` inside `module Admin`) is qualified against it.
        def qualified_name_with_enclosing(node, enclosing)
          return nil unless node.is_a?(Prism::Node)

          local = qualified_name_for(node)
          return nil if local.nil?
          return local if node.is_a?(Prism::ConstantPathNode) && !node.parent.nil?
          return local if enclosing.empty?

          "#{enclosing.join('::')}::#{local}"
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

        def implicit_helper_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && helper_suffix?(node.name)
        end

        def filter_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && FILTER_DSL_METHODS.include?(node.name)
        end

        def render_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :render
        end

        # Drops the trailing keyword hash (`only:` / `except:` / `if:` /
        # `unless:`) so the modifier args don't get treated as filter
        # names.
        def filter_name_args(call_node)
          args = call_node.arguments&.arguments || []
          args = args[0..-2] if args.last.is_a?(Prism::KeywordHashNode)
          args
        end

        def literal_symbol_or_string(node)
          Rigor::Source::Literals.symbol_or_string_name(node)
        end

        def filter_lookup_violation(call_node, arg_node, filter_name, methods, spell_checker, ambiguous_filters:)
          if methods.include?(filter_name.to_sym)
            filter_call_violation(call_node, filter_name)
          elsif ambiguous_filters
            # An unresolved include shadows our judgment — emit the
            # recognized-filter info anyway so the call site is still
            # indexed, but skip the error.
            filter_call_violation(call_node, filter_name)
          else
            unknown_filter_violation(arg_node, call_node, filter_name, spell_checker)
          end
        end

        def permit_chain?(node)
          return false unless node.is_a?(Prism::CallNode) && node.name == :permit

          require_call = node.receiver
          return false unless require_call.is_a?(Prism::CallNode) && require_call.name == :require

          first_arg = require_call.arguments&.arguments&.first
          first_arg.is_a?(Prism::SymbolNode)
        end

        def model_class_for_permit(permit_call)
          require_call = permit_call.receiver
          symbol_node = require_call.arguments.arguments.first
          # `:user` → `User`, `:order_item` → `OrderItem`. ADR-39: the
          # shared inflector camelizes through the real
          # `ActiveSupport::Inflector` when present (so the multi-word
          # case the former `split("_").map(&:capitalize)` only
          # approximated is authoritative), falling back otherwise.
          Rigor::Plugin::Inflector.camelize(symbol_node.value.to_s)
        end

        def literal_permit_keys(permit_call)
          (permit_call.arguments&.arguments || []).filter_map do |arg|
            next [arg, arg.value] if arg.is_a?(Prism::SymbolNode)
          end
        end

        def permit_call_violation(permit_call, model_class, key_name)
          Violation.new(
            location: permit_call.message_loc || permit_call.location,
            message: "Action Pack permit `#{key_name}` resolves to a column on `#{model_class}`.",
            severity: :info, rule: "permit-call"
          )
        end

        def unknown_permit_key_violation(key_node, model_class, key_name, spell_checker)
          base = "Action Pack permit `#{key_name}` is not a column on `#{model_class}`."
          suggestion = spell_checker.correct(key_name).first
          message = suggestion ? "#{base} Did you mean `:#{suggestion}`?" : base
          Violation.new(
            location: key_node.location,
            message: message, severity: :error, rule: "unknown-permit-key"
          )
        end

        # Convert `<root>/app/controllers/admin/users/roles_controller.rb`
        # to `admin/users/roles`. Returns nil if the path is not under an
        # `app/controllers/` segment.
        def controller_path_from_file(path)
          match = path.match(%r{(?:\A|/)app/controllers/(.+)_controller\.rb\z})
          match&.[](1)
        end

        # An abstract base controller — its `render` bodies don't validate
        # against its own controller_path because Rails resolves at
        # request time against the actual subclass. Two conservative
        # heuristics:
        #   (1) The class name ends with `BaseController`. Strong
        #       Rails-convention signal (Settings::Preferences::
        #       BaseController, Admin::BaseController, …).
        #   (2) The controller's view directory exists but contains ONLY
        #       subdirectories (no template files at its top). Mastodon's
        #       Admin::SettingsController whose app/views/admin/settings/
        #       holds only about/, appearance/, … — the parent of nested
        #       controllers.
        # Deliberately NOT triggered by "no view directory at all" because
        # that fires the diagnostic we DO want for genuinely-missing views
        # (the typo / forgot-to-create case).
        def abstract_base_controller?(class_name, controller_path, view_search_roots)
          return true if class_name.end_with?("BaseController")

          view_search_roots.any? do |root|
            dir = File.join(root, controller_path)
            next false unless File.directory?(dir)

            entries = Dir.children(dir)
            entries.any? && entries.all? { |e| File.directory?(File.join(dir, e)) }
          end
        end

        # Returns `[kind, view_relative_path]` where kind is `:template`
        # or `:partial`, and view_relative_path is the path under
        # view_search_roots WITHOUT extension (the extension family is
        # appended at lookup time). Returns nil for shapes Phase 3 doesn't
        # validate (`layout:` / `plain:` / `json:` / `text:` / `inline:` /
        # `:nothing` / no parseable target).
        def render_target_for(call_node, controller_path)
          args = call_node.arguments&.arguments || []
          return nil if args.empty?

          first = args.first
          # `render partial: "..."` — the keyword form.
          return partial_target_from_kwargs(first, controller_path) if first.is_a?(Prism::KeywordHashNode)

          # `render :symbol` / `render "path"`. A trailing KeywordHashNode
          # is allowed (e.g. `render :show, status: :ok`); the leading
          # positional carries the template name.
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
              Source::Literals.symbol_named?(elem.key, "partial")
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
        # Returns nil for class names that don't end with the `Controller`
        # suffix.
        def controller_path_for(class_name)
          return nil unless class_name.end_with?("Controller")

          stripped = class_name.delete_suffix("Controller")
          # ADR-39: the shared inflector flattens `::` → `/` and applies
          # Rails' real underscore (the per-segment hand-rolled version
          # produced the same result for the common case but missed
          # acronym handling). `Admin::Widgets` → `admin/widgets`.
          Rigor::Plugin::Inflector.underscore(stripped)
        end

        def render_violation(call_node, target, view_search_roots)
          kind, relative = target
          existing = locate_template(relative, view_search_roots)
          if existing
            render_target_violation(call_node, kind, relative, existing)
          else
            missing_template_violation(call_node, kind, relative, view_search_roots)
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

        def render_target_violation(call_node, kind, relative, located)
          Violation.new(
            location: location(call_node),
            message: "Action Pack render #{kind} `#{relative}` resolved to `#{located}`.",
            severity: :info, rule: "render-target"
          )
        end

        def missing_template_violation(call_node, kind, relative, view_search_roots)
          tried = RENDER_TEMPLATE_EXTENSIONS.map { |ext| "#{relative}#{ext}" }.join(", ")
          roots = view_search_roots.join(", ")
          Violation.new(
            location: location(call_node),
            message: "Action Pack render #{kind} `#{relative}` not found under #{roots} " \
                     "(tried #{tried}).",
            severity: :error, rule: "missing-template"
          )
        end

        def filter_call_violation(call_node, filter_name)
          Violation.new(
            location: location(call_node),
            message: "Action Pack filter `#{call_node.name} :#{filter_name}` resolves to a defined method.",
            severity: :info, rule: "filter-call"
          )
        end

        def unknown_filter_violation(arg_node, call_node, filter_name, spell_checker)
          base = "Action Pack filter `#{call_node.name} :#{filter_name}` references no method " \
                 "defined on this controller (or its parent)."
          suggestion = spell_checker.correct(filter_name.to_s).first
          message = suggestion ? "#{base} Did you mean `:#{suggestion}`?" : base
          Violation.new(
            location: arg_node.location,
            message: message, severity: :error, rule: "unknown-filter-method"
          )
        end

        def helper_suffix?(name)
          name_str = name.to_s
          SUFFIXES.any? { |suffix| name_str.end_with?(suffix) && name_str.length > suffix.length }
        end

        def positional_arg_count(call_node)
          args = call_node.arguments&.arguments || []
          # Drop a trailing `KeywordHashNode` so call sites that pass
          # `users_path(format: :json)` don't get counted as arity 1. Same
          # convention rigor-rails-routes' helper-table arity uses
          # (positional only).
          args = args[0..-2] if args.last.is_a?(Prism::KeywordHashNode)
          args.size
        end

        def location(call_node)
          call_node.message_loc || call_node.location
        end

        def helper_call_violation(call_node, entry)
          method = entry[:http_method] ? entry[:http_method].to_s.upcase : "(any)"
          Violation.new(
            location: location(call_node),
            message: "Action Pack helper `#{call_node.name}` → #{method} #{entry[:path]} (action: #{entry[:action]}).",
            severity: :info, rule: "helper-call"
          )
        end
      end
    end
  end
end
