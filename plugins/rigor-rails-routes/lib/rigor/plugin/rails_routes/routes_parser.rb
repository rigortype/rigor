# frozen_string_literal: true

require "prism"

require_relative "helper_table"

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # Statically interprets `config/routes.rb`'s DSL via
      # Prism — never executes the file. The interpreter is
      # deliberately narrow; it covers the subset documented
      # in the plugin's README and degrades silently on
      # constructs it doesn't recognise.
      #
      # Recognised DSL surface (per the Rails-plugins
      # roadmap):
      #
      # - `Rails.application.routes.draw do ... end` (entry
      #   block; the body is interpreted)
      # - `resources :name [, only: [...] | except: [...]]`
      # - `resource :name`
      # - `get/post/patch/put/delete "path", to:, as:`
      # - `root to: "..."` / `root "..."`
      # - `scope "path", as: :name do ... end` (with `as:` key)
      # - One level of `namespace :foo do ... end`
      # - One level of nested `resources` (`resources :users
      #   do; resources :posts; end`)
      # - `member do ... end` / `collection do ... end`
      #   inside `resources`
      #
      # Out of scope for v0.1.0 (silent skips):
      #
      # - `scope path:` / `scope module:` (path/module-only, no `as:`)
      # - Constraints (`constraints: { id: /\d+/ }`)
      # - `mount` / engine routes
      # - `direct(:name) { |obj| ... }`
      # - Format restrictions
      module RoutesParser
        # Standard resource actions Rails generates by default.
        DEFAULT_RESOURCE_ACTIONS = %i[index show new create edit update destroy].freeze
        # Default actions for `resource` (singular) — no index,
        # no `:id` segment.
        DEFAULT_SINGULAR_ACTIONS = %i[show new create edit update destroy].freeze

        # Helper-name conventions per action. `:show` and
        # `:update` / `:destroy` share the singular-form
        # helper (Rails dedupes).
        ACTION_HTTP_METHODS = {
          index: :get,
          show: :get,
          new: :get,
          create: :post,
          edit: :get,
          update: :patch, # also :put
          destroy: :delete
        }.freeze

        module_function

        # @param contents [String] raw `config/routes.rb` source
        # @param file_reader [Proc, nil] called with `"name.rb"` to load a
        #   draw partial from `config/routes/name.rb`. Returns file contents
        #   or nil when the file is absent.
        # @return [HelperTable]
        def parse(contents, file_reader: nil, custom_helpers: [])
          parse_result = Prism.parse(contents)
          return HelperTable.new([], custom_helpers: custom_helpers) unless parse_result.errors.empty?

          context = Context.new(file_reader: file_reader)
          interpret(parse_result.value, context)

          # Each helper has both `_path` and `_url` forms.
          paired = context.entries.flat_map do |entry|
            [
              entry,
              HelperTable::Entry.new(
                name: entry.name.sub(/_path\z/, "_url"),
                arity: entry.arity,
                path: entry.path,
                http_method: entry.http_method,
                action: entry.action
              )
            ]
          end
          HelperTable.new(paired, custom_helpers: custom_helpers, devise_resources: context.devise_resources)
        end

        # Per-parse mutable accumulator. Tracks the current
        # nesting prefix (namespaces + parent resource) and the
        # entries collected so far.
        class Context
          attr_reader :entries, :file_reader, :devise_resources

          def initialize(file_reader: nil)
            @entries = []
            @file_reader = file_reader
            # Stack of prefix segments. Each entry is one of:
            # - `{ kind: :namespace, name: "admin" }`
            # - `{ kind: :scope, parent: "user", arity_segments: [":user_id"] }`
            # - `{ kind: :as_scope, name: "event", path: "/:event_slug", arity: 1 }`
            @stack = []
            # Devise resource segments (singularised) declared
            # via `devise_for :resource`. Drives the
            # OmniAuth-helper recognition in `HelperTable#omniauth_match?`.
            @devise_resources = []
          end

          def record_devise_resource(name)
            @devise_resources << name.to_s
          end

          def push_namespace(name)
            @stack.push(kind: :namespace, name: name.to_s)
            yield
          ensure
            @stack.pop
          end

          def push_resource(parent_name)
            singular = singularize(parent_name.to_s)
            @stack.push(kind: :scope, parent: singular, arity_segments: [":#{singular}_id"])
            yield
          ensure
            @stack.pop
          end

          # `scope "/:slug", as: "foo" do ... end` — adds a
          # helper-name prefix without the "parent resource" arity
          # arithmetic that push_resource uses.
          def push_as_scope(name, path, arity_count)
            @stack.push(kind: :as_scope, name: name.to_s, path: path, arity: arity_count)
            yield
          ensure
            @stack.pop
          end

          # Helper-name prefix from namespaces (`admin_`,
          # `admin_users_`, …).
          def helper_prefix
            segments = @stack.filter_map { |frame| frame_helper_segment(frame) }
            segments.map { |segment| "#{segment}_" }.join
          end

          # Path prefix — including the parent's `:user_id`
          # segments for nested resources and the namespace
          # path prefix.
          def path_prefix
            parts = @stack.flat_map { |frame| frame_path_segments(frame) }
            parts.join
          end

          # Number of dynamic segments (`:user_id`-style)
          # captured by the parent scope chain. Used to
          # compute helper arity for nested resources.
          # Each nested-resource `:scope` frame contributes 1;
          # each `:as_scope` frame contributes its own arity.
          def parent_segment_count
            @stack.sum do |frame|
              case frame[:kind]
              when :scope then 1
              when :as_scope then frame[:arity]
              else 0
              end
            end
          end

          private

          def frame_helper_segment(frame)
            case frame[:kind]
            when :namespace then frame[:name]
            when :scope then frame[:parent]
            when :as_scope then frame[:name]
            end
          end

          def frame_path_segments(frame)
            case frame[:kind]
            when :namespace then ["/#{frame[:name]}"]
            when :scope then ["/#{pluralize(frame[:parent])}/:#{frame[:parent]}_id"]
            when :as_scope then frame[:path] ? [frame[:path]] : []
            else []
            end
          end

          # Tiny English inflector. Sufficient for the standard
          # `posts` ↔ `post`, `users` ↔ `user` rename Rails
          # generates by default; users with custom
          # inflections need to author RBS by hand for the
          # affected helpers (out of scope for v0.1.0).
          #
          # The canonical English uncountable noun set from
          # ActiveSupport::Inflector::Inflections (Rails 8.x).
          # `singularize("news")` returns `"news"` rather than
          # `"new"`. Pre-fix the parser stripped the trailing
          # 's' from `news`, so `resources :news` registered
          # `new_path` / `news_path` / `new_news_path` (broken
          # — Rails actually generates `news_path` for both
          # index and show, with the show form taking `:id`).
          # Redmine hit this 81× across `news_path(id)` calls.
          UNCOUNTABLE = %w[
            equipment information rice money species series fish
            sheep jeans police news media settings
          ].to_set.freeze
          private_constant :UNCOUNTABLE

          def singularize(word)
            return word if UNCOUNTABLE.include?(word)
            return "#{word.chomp('ies')}y" if word.end_with?("ies") && word.length > 3
            return word.chomp("es") if word.end_with?("ses") || word.end_with?("xes")
            return word.chomp("s") if word.end_with?("s")

            word
          end

          def pluralize(word)
            return word if UNCOUNTABLE.include?(word)
            return word if word.end_with?("s")
            return "#{word.chomp('y')}ies" if word.end_with?("y") && word.length > 1

            "#{word}s"
          end
        end

        def interpret(node, context)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::CallNode
            interpret_call(node, context)
          else
            node.compact_child_nodes.each { |child| interpret(child, context) }
          end
        end

        def interpret_call(node, context)
          case node.name
          when :draw
            if node.block
              # `Rails.application.routes.draw do ... end`
              interpret_block_body(node, context)
            else
              # `draw(:admin)` — routing partial at
              # config/routes/{name}.rb.
              load_drawn_routes(node, context)
            end
          when :namespace
            handle_namespace(node, context)
          when :resources
            handle_resources(node, context)
          when :resource
            handle_resource(node, context)
          when :root
            handle_root(node, context)
          when :scope
            handle_scope(node, context)
          when :get, :post, :patch, :put, :delete
            handle_explicit_route(node, context)
          when :member, :collection
            # Inside a `resources` block, `member do ... end`
            # / `collection do ... end` introduces extra
            # routes. Interpreted only when we have a parent
            # scope (otherwise the call is meaningless).
            handle_member_or_collection(node, context)
          when :devise_for
            handle_devise_for(node, context)
          when :concern
            # `concern :name do ... end` — intentional no-op.
            # Concerns are injected into resource blocks via
            # `concerns: :name`; evaluating the concern body
            # at definition time registers helpers with no
            # parent-resource arity, producing wrong-arity
            # false positives. Skip the body here; helpers
            # defined only inside concerns are silently absent
            # (unknown-helper) which is less harmful.
            nil
          else
            interpret_block_body(node, context)
          end
        end

        def interpret_block_body(node, context)
          body = node.block&.body
          return if body.nil?

          body.compact_child_nodes.each { |child| interpret(child, context) }
        end

        def handle_namespace(node, context)
          name = symbol_argument(node, 0)
          return interpret_block_body(node, context) if name.nil?

          context.push_namespace(name) { interpret_block_body(node, context) }
        end

        # `devise_for :users [, skip: [...], path: "..."]` —
        # generates the standard Devise route-helper catalogue
        # for the named resource. Symbol-literal first arg
        # only; non-literal forms (e.g. dynamic resource names
        # built from constants) are silently skipped because the
        # helper SET depends on the literal name and we cannot
        # statically resolve a variable here. `skip:` is read
        # so the project's omitted controllers do not register.
        def handle_devise_for(node, context)
          resource = symbol_argument(node, 0)
          return if resource.nil?

          skip = Array(keyword_array(node, :skip)).map(&:to_sym)
          resource_segment = DeviseRoutes.singularize(resource.to_s)
          context.record_devise_resource(resource_segment)
          DeviseRoutes.generate(resource: resource, skip: skip).each do |entry|
            context.entries << entry
          end
        end

        def keyword_array(node, key)
          arg = options_hash(node)[key]
          arg.is_a?(Array) ? arg : nil
        end

        # `scope "/:slug", as: "event" do ... end`
        #
        # When `as:` is present the block body is interpreted under a
        # new `:as_scope` stack frame that adds the given prefix to
        # every helper registered inside.  Dynamic path segments
        # (`:slug`) are counted so nested-resource arities stay
        # correct.
        #
        # When `as:` is absent the block is interpreted without any
        # prefix change — helper names are unaffected by the scope's
        # path, which matches Rails' behaviour for path-only scopes.
        def handle_scope(node, context)
          as_name = keyword_symbol(node, :as)

          if as_name.nil?
            interpret_block_body(node, context)
            return
          end

          path = string_argument(node, 0)
          arity = path ? count_path_placeholders(path) : 0

          context.push_as_scope(as_name.to_s, path, arity) do
            interpret_block_body(node, context)
          end
        end

        def handle_resources(node, context)
          name = symbol_argument(node, 0)
          return interpret_block_body(node, context) if name.nil?

          actions = restrict_actions(node, DEFAULT_RESOURCE_ACTIONS)
          base_arity = context.parent_segment_count

          register_resourceful_helpers(name, actions, base_arity, context, plural: true)

          context.push_resource(name) do
            interpret_block_body(node, context)
          end
        end

        def handle_resource(node, context)
          name = symbol_argument(node, 0)
          return interpret_block_body(node, context) if name.nil?

          actions = restrict_actions(node, DEFAULT_SINGULAR_ACTIONS)
          base_arity = context.parent_segment_count

          # Singular resource — no `:id` segment, no `:index`
          # / pluralised helper. The "show" helper is
          # `<name>_path` (singular).
          register_resourceful_helpers(name, actions, base_arity, context, plural: false)

          # Nested `resources :things` inside `resource :profile`
          # is rare; we still descend so the inner declarations
          # collect their own helpers.
          interpret_block_body(node, context)
        end

        def handle_root(node, context)
          # `root to: "..."` / `root "..."` — single helper
          # `root_path`, arity 0, GET. Real-world Rails apps also
          # use `root :to => 'welcome#index', :as => 'home'` (the
          # canonical Redmine idiom across 230+ call sites), which
          # registers an additional `home_path` / `home_url` alias
          # for the same path. Mastodon and Solidus also use the
          # `as:` form occasionally for analytics-friendly URL
          # naming.
          path = context.path_prefix.empty? ? "/" : context.path_prefix
          context.entries << HelperTable::Entry.new(
            name: "#{context.helper_prefix}root_path",
            arity: 0, path: path, http_method: :get, action: :root
          )

          alias_name = keyword_symbol(node, :as)
          return if alias_name.nil?

          context.entries << HelperTable::Entry.new(
            name: "#{context.helper_prefix}#{alias_name}_path",
            arity: 0, path: path, http_method: :get, action: :root
          )
        end

        def handle_explicit_route(node, context)
          # `get "/about", to: "static#about", as: :about`
          path = string_argument(node, 0)
          as_name = keyword_symbol(node, :as)
          return if as_name.nil? && path.nil?

          # When `as:` is omitted, Rails derives a helper name
          # from the path for static paths (no :segment). We
          # do the same when the path has no placeholders.
          if as_name.nil?
            return if path.nil? || path.include?(":")

            as_name = path.delete_prefix("/").tr("/", "_")
            return if as_name.empty?
          end

          name = "#{context.helper_prefix}#{as_name}_path"
          arity = context.parent_segment_count + count_path_placeholders(path)
          context.entries << HelperTable::Entry.new(
            name: name, arity: arity,
            path: "#{context.path_prefix}#{path || ''}",
            http_method: node.name, action: :custom
          )
        end

        def load_drawn_routes(node, context)
          return unless context.file_reader

          name = symbol_argument(node, 0) || string_argument(node, 0)&.to_sym
          return unless name

          sub_contents = context.file_reader.call("#{name}.rb")
          return unless sub_contents

          sub_result = Prism.parse(sub_contents)
          return if sub_result.errors.any?

          interpret(sub_result.value, context)
        end

        def handle_member_or_collection(node, context)
          # Only meaningful when we're inside a `resources` /
          # `resource` block. The Context's stack tells us.
          return unless context.parent_segment_count.positive? || in_singular_resource?(context)

          # The Context doesn't currently distinguish
          # "inside resources" from "inside resource" — for
          # v0.1.0 we treat both the same way and let the
          # explicit `as:` in member/collection do the
          # naming work.
          interpret_block_body(node, context)
        end

        def in_singular_resource?(*)
          # Slice 1 doesn't model the singular-resource frame
          # separately; placeholder so member / collection
          # blocks at least descend.
          true
        end

        # Generate the standard helpers for a resource(s).
        # `plural: true` for `resources :users`, `false` for
        # `resource :profile`.
        def register_resourceful_helpers(name, actions, base_arity, context, plural:)
          singular = singularize_word(name.to_s)
          plural_form = plural ? name.to_s : singular # `resource :foo` uses singular path
          path_base = "#{context.path_prefix}/#{plural_form}"

          actions.each do |action|
            entry = entry_for_action(
              action,
              name: name, singular: singular, base_arity: base_arity,
              path_base: path_base, helper_prefix: context.helper_prefix, plural: plural
            )
            context.entries << entry if entry
          end
        end

        # `:create` / `:update` / `:destroy` don't generate
        # `*_path` helpers separate from the show / index
        # helper Rails reuses for their forms; the case
        # statement returns nil for those and the caller
        # skips them.
        def entry_for_action(action, name:, singular:, base_arity:, path_base:, helper_prefix:, plural:)
          case action
          when :index then index_entry(plural, helper_prefix, name, base_arity, path_base)
          when :show then show_entry(plural, helper_prefix, singular, base_arity, path_base)
          when :new
            HelperTable::Entry.new(
              name: "new_#{helper_prefix}#{singular}_path",
              arity: base_arity, path: "#{path_base}/new",
              http_method: :get, action: :new
            )
          when :edit then edit_entry(plural, helper_prefix, singular, base_arity, path_base)
          end
        end

        def index_entry(plural, helper_prefix, name, base_arity, path_base)
          return nil unless plural

          HelperTable::Entry.new(
            name: "#{helper_prefix}#{name}_path",
            arity: base_arity, path: path_base,
            http_method: :get, action: :index
          )
        end

        def show_entry(plural, helper_prefix, singular, base_arity, path_base)
          show_path = plural ? "#{path_base}/:id" : path_base
          show_arity = plural ? base_arity + 1 : base_arity
          HelperTable::Entry.new(
            name: "#{helper_prefix}#{singular}_path",
            arity: show_arity, path: show_path,
            http_method: :get, action: :show
          )
        end

        def edit_entry(plural, helper_prefix, singular, base_arity, path_base)
          edit_path = plural ? "#{path_base}/:id/edit" : "#{path_base}/edit"
          edit_arity = plural ? base_arity + 1 : base_arity
          HelperTable::Entry.new(
            name: "edit_#{helper_prefix}#{singular}_path",
            arity: edit_arity, path: edit_path,
            http_method: :get, action: :edit
          )
        end

        def restrict_actions(node, default)
          options = options_hash(node)
          # `resources :foo, only: :show` is the same as
          # `only: [:show]` in Rails; `options_hash` preserves the
          # Symbol shape from the source, so coerce here.
          if (only = options[:only])
            Array(only) & default
          elsif (except = options[:except])
            default - Array(except)
          else
            default
          end
        end

        def options_hash(node)
          args = node.arguments&.arguments || []
          last = args.last
          return {} unless last.is_a?(Prism::KeywordHashNode)

          last.elements.each_with_object({}) do |element, into|
            next unless element.is_a?(Prism::AssocNode)
            next unless element.key.is_a?(Prism::SymbolNode)

            value = symbol_array(element.value) || symbol_value(element.value) || string_value(element.value)
            into[element.key.unescaped.to_sym] = value
          end
        end

        def symbol_argument(node, index)
          arg = (node.arguments&.arguments || [])[index]
          symbol_value(arg)
        end

        def string_argument(node, index)
          arg = (node.arguments&.arguments || [])[index]
          string_value(arg)
        end

        def keyword_symbol(node, key)
          options_hash(node)[key]
        end

        def symbol_value(node)
          node.is_a?(Prism::SymbolNode) ? node.unescaped.to_sym : nil
        end

        def string_value(node)
          node.is_a?(Prism::StringNode) ? node.unescaped : nil
        end

        def symbol_array(node)
          return nil unless node.is_a?(Prism::ArrayNode)

          values = node.elements.map { |e| symbol_value(e) }
          values.all? ? values : nil
        end

        def count_path_placeholders(path)
          return 0 if path.nil?

          path.scan(/:[a-z_][a-z0-9_]*/).size
        end

        # Shared with `Context::Inflector#singularize` — kept in
        # sync until one of the two call sites can adopt the
        # other.
        UNCOUNTABLE = %w[
          equipment information rice money species series fish
          sheep jeans police news media settings
        ].to_set.freeze

        def singularize_word(word)
          return word if UNCOUNTABLE.include?(word)
          return "#{word.chomp('ies')}y" if word.end_with?("ies") && word.length > 3
          return word.chomp("es") if word.end_with?("ses") || word.end_with?("xes")
          return word.chomp("s") if word.end_with?("s")

          word
        end
      end
    end
  end
end
