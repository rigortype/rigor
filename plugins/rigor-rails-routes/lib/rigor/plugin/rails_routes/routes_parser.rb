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
            # Registered `concern :name do ... end` blocks.
            # Keyed by Symbol name; value is the block's body
            # node. `resources :foo, concerns: :name do ... end`
            # replays the body at the resource's site.
            @concerns = {}
          end

          def record_devise_resource(name)
            @devise_resources << name.to_s
          end

          def register_concern(name, body_node)
            @concerns[name.to_sym] = body_node
          end

          def concern_body(name)
            @concerns[name.to_sym]
          end

          def push_namespace(name)
            @stack.push(kind: :namespace, name: name.to_s)
            yield
          ensure
            @stack.pop
          end

          def push_resource(parent_name)
            singular = singularize(parent_name.to_s)
            @stack.push(kind: :scope, parent: singular, parent_plural: parent_name.to_s,
                        arity_segments: [":#{singular}_id"])
            yield
          ensure
            @stack.pop
          end

          # `resource :foo do ... end` (SINGULAR resource) —
          # adds the resource name to the helper prefix and
          # path for nested declarations, but DOESN'T
          # contribute a dynamic `:id` segment (singular
          # resources have no `:id`). So `resource :instance
          # do; resources :domain_blocks; end` generates
          # `instance_domain_blocks_path` (arity 0), not
          # `instance_domain_blocks_path(:id)`.
          #
          # Helper-prefix segment uses the AS-GIVEN name (no
          # singularising — `resource :foo` keeps `foo`).
          def push_singular_resource(parent_name)
            name = parent_name.to_s
            @stack.push(kind: :singular_scope, parent: name, path_segment: "/#{name}")
            yield
          ensure
            @stack.pop
          end

          # `member do ... end` / `collection do ... end` —
          # records the mode so subsequent shorthand HTTP-verb
          # calls (`post :memorialize`) inside the block can
          # derive their helper name from the enclosing
          # resource. The frame also carries the immediate
          # parent's singular / plural names so member /
          # collection actions can pick the correct form
          # (`memorialize_account_path(id)` vs
          # `memorialize_accounts_path`).
          def push_action_block(mode, parent_singular, parent_plural)
            @stack.push(kind: :"#{mode}_block", parent_singular: parent_singular, parent_plural: parent_plural)
            yield
          ensure
            @stack.pop
          end

          # Returns the top-most `:scope` frame's singular /
          # plural names, or `nil` when not inside a resources
          # / resource block. Used by `handle_member_or_collection`
          # to push the action-block frame.
          def innermost_resource
            scope_frame = @stack.rfind { |f| f[:kind] == :scope }
            return nil if scope_frame.nil?

            { singular: scope_frame[:parent], plural: scope_frame[:parent_plural] || scope_frame[:parent] }
          end

          # Top-most `:member_block` / `:collection_block`
          # frame, or nil when not in a shorthand action
          # context. `handle_explicit_route` uses this to
          # detect a `post :memorialize` symbol-only call shape.
          def innermost_action_block
            @stack.rfind { |f| %i[member_block collection_block].include?(f[:kind]) }
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
            when :singular_scope then frame[:parent]
            end
          end

          def frame_path_segments(frame)
            case frame[:kind]
            when :namespace then ["/#{frame[:name]}"]
            when :scope then ["/#{pluralize(frame[:parent])}/:#{frame[:parent]}_id"]
            when :as_scope then frame[:path] ? [frame[:path]] : []
            when :singular_scope then [frame[:path_segment]]
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
            sheep jeans police news settings
          ].to_set.freeze
          private_constant :UNCOUNTABLE

          # Latin / Greek irregular plurals Rails ships in its
          # default inflector. `media` → `medium` is the
          # dominant Rails-app case (Mastodon's `resources
          # :media, only: [:show]` generates `medium_path(id)`,
          # not `media_path`). Pre-fix `media` was in
          # UNCOUNTABLE which produced `media_path` for both
          # index and show — incorrect.
          IRREGULAR_SINGULARS = {
            "media" => "medium",
            "data" => "datum",
            "criteria" => "criterion",
            "phenomena" => "phenomenon"
          }.freeze
          private_constant :IRREGULAR_SINGULARS

          def singularize(word)
            return IRREGULAR_SINGULARS[word] if IRREGULAR_SINGULARS.key?(word)
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
          when :use_doorkeeper
            handle_use_doorkeeper(node, context)
          when :concern
            handle_concern_definition(node, context)
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

        # `use_doorkeeper do ... end` — Doorkeeper gem's
        # standard OAuth route helpers (`oauth_token_path`,
        # `oauth_authorization_path`, `oauth_application_path`,
        # etc.). We generate the full catalogue plus walk the
        # block body for `skip_controllers <names>` calls so
        # the project's omitted controllers don't register.
        # `controllers <hash>` mappings inside the block change
        # the serving controller class but not the helper
        # names — they can stay unmodelled.
        def handle_use_doorkeeper(node, context)
          skip = collect_doorkeeper_skips(node)
          DoorkeeperRoutes.generate(skip: skip).each do |entry|
            context.entries << entry
          end
        end

        def collect_doorkeeper_skips(node)
          body = node.block&.body
          return [] if body.nil?

          skips = []
          body.compact_child_nodes.each do |child|
            next unless child.is_a?(Prism::CallNode) && child.name == :skip_controllers
            next if child.receiver

            (child.arguments&.arguments || []).each do |arg|
              skips << arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode)
            end
          end
          skips
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
            replay_concerns(node, context)
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

          # Push a `:singular_scope` frame so nested
          # declarations pick up the singular resource's
          # name in their helper prefix (Mastodon's
          # `resource :instance do; scope module: :instances
          # do; resources :domain_blocks; end; end` →
          # `instance_domain_blocks_path`). The singular
          # frame adds NO `:id` segment to arity — singular
          # resources don't carry one.
          context.push_singular_resource(name) do
            replay_concerns(node, context)
            interpret_block_body(node, context)
          end
        end

        # `concern :account_resources do ... end` registers the
        # body for later replay; we DO NOT interpret it at the
        # definition site (the body has no parent-resource
        # context yet). Concerns at the top level land in the
        # Context's `concerns` map by Symbol name.
        def handle_concern_definition(node, context)
          name = symbol_argument(node, 0)
          body = node.block&.body
          return if name.nil? || body.nil?

          context.register_concern(name, body)
        end

        # `resources :accounts, concerns: :account_resources do ... end`
        # — replays the registered concern body inside the
        # current Context (which already has the accounts
        # resource frame pushed). Supports both single-symbol
        # (`concerns: :name`) and array-of-symbols
        # (`concerns: [:a, :b]`) forms.
        def replay_concerns(resource_node, context)
          concerns_value = keyword_value(resource_node, :concerns)
          return if concerns_value.nil?

          Array(concerns_value).each do |concern_name|
            body = context.concern_body(concern_name)
            next if body.nil?

            body.compact_child_nodes.each { |child| interpret(child, context) }
          end
        end

        # Reads the value of an options-hash key. Distinct from
        # `keyword_symbol` / `keyword_array` because `concerns:`
        # accepts EITHER a single Symbol or an Array of Symbols
        # — same Rails idiom Rails accepts.
        def keyword_value(node, key)
          options_hash(node)[key]
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
          # Member / collection block shorthand: `post :memorialize`
          # inside `member do ... end` (no path arg, just a
          # SymbolNode). Rails generates a helper based on the
          # action name + the enclosing resource: a member
          # action becomes `<action>_<singular_chain>_path(id)`,
          # a collection action becomes
          # `<action>_<plural_chain>_path`.
          return register_member_collection_action(node, context) if member_collection_shorthand?(node, context)

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

        # True when we're inside `member do ... end` / `collection
        # do ... end` AND the call is of the form
        # `<verb> :symbol [, options...]` — a shorthand action
        # declaration whose first positional argument is the
        # action name (no explicit path).
        def member_collection_shorthand?(node, context)
          return false unless context.innermost_action_block

          first_arg = node.arguments&.arguments&.first
          first_arg.is_a?(Prism::SymbolNode)
        end

        # Generates the member / collection action helper.
        # Member: `<action>_<helper_prefix>path(id)`, arity =
        #   parent_segment_count (which already includes the
        #   enclosing resource's `:id`).
        # Collection: `<action>_<plural_helper_prefix>path`,
        #   arity = parent_segment_count - 1 (no `:id` segment;
        #   the collection URL is /<resource>/<action>).
        def register_member_collection_action(node, context)
          action_name = symbol_argument(node, 0).to_s
          frame = context.innermost_action_block
          if frame[:kind] == :member_block
            register_member_action(node, context, action_name)
          else
            register_collection_action(node, context, action_name, frame)
          end
        end

        def register_member_action(node, context, action_name)
          # `helper_prefix` already ends with "_" (each segment
          # appends one); the formula below yields e.g.
          # `memorialize_admin_account_path`. Arity equals the
          # parent segment count — Rails member URLs carry the
          # enclosing resource's `:id`, which the :scope frame
          # already counts.
          name = "#{action_name}_#{context.helper_prefix}path"
          context.entries << HelperTable::Entry.new(
            name: name, arity: context.parent_segment_count,
            path: "#{context.path_prefix}/#{action_name}",
            http_method: node.name, action: :custom
          )
        end

        def register_collection_action(node, context, action_name, frame)
          # Collection URL drops the immediate parent's `:id`
          # segment. The plural helper prefix swaps the
          # singular form (in `helper_prefix`) for the plural
          # — the immediate-resource frame stored both.
          plural_prefix = context.helper_prefix.sub(/#{frame[:parent_singular]}_\z/, "#{frame[:parent_plural]}_")
          name = "#{action_name}_#{plural_prefix}path"
          arity = [context.parent_segment_count - 1, 0].max
          context.entries << HelperTable::Entry.new(
            name: name, arity: arity,
            path: "#{context.path_prefix}/#{action_name}",
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
          resource = context.innermost_resource
          return interpret_block_body(node, context) if resource.nil?

          mode = node.name # :member or :collection
          context.push_action_block(mode, resource[:singular], resource[:plural]) do
            interpret_block_body(node, context)
          end
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
          # Singular resources (`resource :foo`) use the
          # given name AS-IS for both path and helper —
          # singularising would mangle a deliberately-plural
          # singular-DSL name like Mastodon's
          # `resource :relationships, only: [:show, :update]`
          # (Rails generates `relationships_path`, not
          # `relationship_path`). Plural resources still
          # singularise for the show / new / edit helpers.
          # Plural resources singularise for show / new / edit
          # helpers (`resources :users` → `user_path(id)`);
          # singular resources use the name AS-IS even when it
          # looks plural (Mastodon's `resource :relationships,
          # only: [:show, :update]` → `relationships_path`).
          # The path segment uses `name` in both shapes — Rails
          # never singularises the URL.
          singular = plural ? singularize_word(name.to_s) : name.to_s
          path_base = "#{context.path_prefix}/#{name}"

          actions.each do |action|
            entry = entry_for_action(
              action,
              name: name, singular: singular, base_arity: base_arity,
              path_base: path_base, helper_prefix: context.helper_prefix, plural: plural
            )
            context.entries << entry if entry
          end
        end

        # Maps an action keyword to the route-helper entry it
        # produces. The five "named-helper" actions
        # (`:index` / `:show` / `:new` / `:edit` plus
        # singular-resource `:show`) generate a distinct
        # helper; the three "verb-only" actions (`:create` /
        # `:update` / `:destroy`) Rails serves under the same
        # path-helper Rails reuses for show / index forms — so
        # we emit them too, otherwise an `only: [:create]`
        # resource (e.g. Mastodon's `resource :inbox, only:
        # [:create]`) registers NO helpers and downstream
        # callers see a false `unknown-helper inbox_path`.
        # The HelperTable already dedupes by name, so a
        # resource that lists both `:show` and `:update` does
        # not double-register.
        def entry_for_action(action, name:, singular:, base_arity:, path_base:, helper_prefix:, plural:)
          case action
          when :index then index_entry(plural, helper_prefix, name, base_arity, path_base, singular)
          when :show then show_entry(plural, helper_prefix, singular, base_arity, path_base)
          when :new
            HelperTable::Entry.new(
              name: "new_#{helper_prefix}#{singular}_path",
              arity: base_arity, path: "#{path_base}/new",
              http_method: :get, action: :new
            )
          when :edit then edit_entry(plural, helper_prefix, singular, base_arity, path_base)
          when :create
            # Plural `resources` collection POST shares the
            # index helper (`<name>_path` → collection URL).
            # Singular `resource` POST shares the show helper
            # (`<name>_path` → resource URL). Both shapes
            # produce a `<prefix><name>_path` entry; only the
            # arity / path differ.
            create_entry(plural, helper_prefix, name, singular, base_arity, path_base)
          when :update, :destroy
            # Member PATCH / PUT / DELETE on plural resources
            # share the show helper (`<prefix><singular>_path(id)`).
            # Singular-resource PATCH / DELETE shares
            # `<prefix><name>_path` (no `:id`).
            show_entry(plural, helper_prefix, singular, base_arity, path_base)
          end
        end

        def create_entry(plural, helper_prefix, name, singular, base_arity, path_base)
          if plural
            HelperTable::Entry.new(
              name: "#{helper_prefix}#{name}_path",
              arity: base_arity, path: path_base,
              http_method: :post, action: :create
            )
          else
            HelperTable::Entry.new(
              name: "#{helper_prefix}#{singular}_path",
              arity: base_arity, path: path_base,
              http_method: :post, action: :create
            )
          end
        end

        def index_entry(plural, helper_prefix, name, base_arity, path_base, singular)
          return nil unless plural

          # Rails appends `_index_path` to the index helper
          # name when the singular form of the resource matches
          # the plural form AND the noun isn't in the canonical
          # UNCOUNTABLE list. The collision would otherwise put
          # both the index (`:id`-less) and show (`:id`-bearing)
          # helpers under the same name, and Rails disambiguates
          # by suffixing the index form. Mastodon's
          # `resources :reblogged_by, controller:
          # :reblogged_by_accounts, only: :index` and similar
          # rely on this — calls like
          # `api_v1_status_reblogged_by_index_url(status.id)`
          # would otherwise read as `unknown-helper`.
          #
          # UNCOUNTABLE nouns (`news`, `series`, `media`, …)
          # keep both helpers under the same name on the Rails
          # side — they don't get the `_index_` suffix.
          index_name = if name.to_s == singular && !UNCOUNTABLE.include?(name.to_s)
                         "#{helper_prefix}#{name}_index_path"
                       else
                         "#{helper_prefix}#{name}_path"
                       end
          HelperTable::Entry.new(
            name: index_name,
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
          sheep jeans police news settings
        ].to_set.freeze

        # Same `IRREGULAR_SINGULARS` map as `Context#singularize`.
        IRREGULAR_SINGULARS = {
          "media" => "medium",
          "data" => "datum",
          "criteria" => "criterion",
          "phenomena" => "phenomenon"
        }.freeze

        def singularize_word(word)
          return IRREGULAR_SINGULARS[word] if IRREGULAR_SINGULARS.key?(word)
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
