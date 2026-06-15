# frozen_string_literal: true

require "prism"
require "rigor/source/literals"

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

          # Apply name-transform alias rules discovered during
          # the walk (the `direct(name.sub(X, Y)) do |...| send(
          # "#{name}_url", ...) end` GitLab pattern — see
          # `collect_alias_rules` below).
          apply_alias_rules(context)

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

        # For every registered alias rule `(from_str, to_str,
        # arity_delta)`, find every existing entry whose name
        # contains `from_str` and register an aliased entry with
        # `from_str → to_str` substitution. The pattern matches
        # GitLab's shorthand-helper idiom: a loop over registered
        # route names that invokes `direct(new_name) do |project,
        # *args| send("#{name}_url", project&.namespace,
        # project, *args) end` where `new_name = name.sub(FROM,
        # TO)`. The direct block extracts the namespace from
        # `project` and forwards the rest, so the alias's arity
        # is one LESS than the original helper's
        # (`namespace_project_blob_path(namespace_id, project_id,
        # blob_id)` → `project_blob_path(project, blob_id)`).
        # We register each alias under the original entry's
        # arity AND `original - 1` to span both interpretations.
        def apply_alias_rules(context)
          return if context.alias_rules.empty?

          aliases = []
          context.alias_rules.each do |from, to|
            context.entries.each do |entry|
              next unless entry.name.include?(from)

              new_name = entry.name.sub(from, to)
              next if new_name == entry.name

              # Register at original arity AND at arity-1 so the
              # common GitLab `|project, *args|` pattern (which
              # collapses namespace_id + project_id into project)
              # passes the arity check.
              [entry.arity, [entry.arity - 1, 0].max].uniq.each do |arity|
                aliases << HelperTable::Entry.new(
                  name: new_name, arity: arity,
                  path: entry.path, http_method: entry.http_method,
                  action: entry.action
                )
              end
            end
          end
          context.entries.concat(aliases)
        end

        # Per-parse mutable accumulator. Tracks the current
        # nesting prefix (namespaces + parent resource) and the
        # entries collected so far.
        class Context
          attr_reader :entries, :file_reader, :devise_resources, :alias_rules

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
            # `(from_str, to_str)` pairs collected from
            # iterative `direct(name.sub(FROM, TO)) do ... end`
            # patterns. Applied after parsing via
            # `apply_alias_rules` to generate substituted-name
            # aliases for every matching entry — closes
            # GitLab's `namespace_project_*` → `project_*`
            # shorthand idiom.
            @alias_rules = []
          end

          def register_alias_rule(from, to)
            @alias_rules << [from, to]
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

          # `with_options only: [:index], concerns: :batch do
          # ... end` — every call inside the block inherits
          # these default options (each call's own options
          # override the defaults). `effective_options_for`
          # below merges them in caller-precedence order.
          def push_with_options(defaults)
            @stack.push(kind: :with_options, defaults: defaults)
            yield
          ensure
            @stack.pop
          end

          # The merged default-options chain from every
          # enclosing `with_options` frame on the stack
          # (outer-most first; inner frames take precedence).
          # `handle_resources` / `handle_resource` merge this
          # with the node's own option hash so a bare
          # `resources :links` inside `with_options only:
          # [:index], concerns: :batch do ... end` is
          # treated as if it had those options written
          # inline.
          def with_options_defaults
            defaults = {}
            @stack.each do |frame|
              next unless frame[:kind] == :with_options

              defaults = defaults.merge(frame[:defaults])
            end
            defaults
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

          # The chain of resource-singular segments above the
          # current scope, in order — used to form member-route
          # helper names of the form `<as>_<singular_chain>_path`.
          # Includes nested resources (`resources :projects do;
          # resources :issues do; get 'foo', as: 'bar'; end; end`
          # → `bar_project_issue_path`). Returns `""` outside any
          # `:scope` / `:singular_scope` frame.
          def resource_singular_chain
            segments = @stack.filter_map do |frame|
              case frame[:kind]
              when :scope then frame[:parent]
              when :singular_scope then frame[:parent]
              end
            end
            segments.empty? ? "" : "#{segments.join('_')}_"
          end

          # Namespace-only prefix (drops the resource-singular
          # segments that `helper_prefix` includes). Used so that
          # an `:as => 'foo'` inside `namespace :admin do
          # resources :projects do; ...; end; end` generates
          # `admin_foo_project_path` — namespace first, then
          # `:as` action prefix, then singular chain.
          def namespace_only_prefix
            segments = @stack.filter_map do |frame|
              case frame[:kind]
              when :namespace then frame[:name]
              when :as_scope then frame[:name]
              end
            end
            segments.empty? ? "" : "#{segments.join('_')}_"
          end

          # True when we're inside a `resources` or `resource`
          # scope (the AST has pushed a `:scope` or
          # `:singular_scope` frame). Drives member-route
          # helper-name generation in `handle_explicit_route`.
          def inside_resource_scope?
            @stack.any? { |frame| %i[scope singular_scope].include?(frame[:kind]) }
          end

          # The innermost `:scope` frame (plural resource),
          # carrying `parent` (singular) and `parent_plural`.
          # Used by the inline `:on => :collection` / `:on =>
          # :member` form to derive the helper name.
          def innermost_scope_frame
            @stack.rfind { |f| f[:kind] == :scope }
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
            when :as_scope
              # An `:as_scope` frame with an empty `:name` is a
              # path-only frame pushed by `scope(path: 'X')`
              # without `:as` — contributes path/arity but no
              # helper-prefix segment.
              frame[:name].to_s.empty? ? nil : frame[:name]
            when :singular_scope then frame[:parent]
            end
          end

          def frame_path_segments(frame)
            case frame[:kind]
            when :namespace then ["/#{frame[:name]}"]
            when :scope
              # Use the as-given plural when available
              # (`parent_plural` was captured at
              # push_resource time) — the singularize /
              # pluralize round-trip is lossy for irregular
              # forms (`media → medium → medias`) but the
              # original name is always correct.
              plural = frame[:parent_plural] || pluralize(frame[:parent])
              ["/#{plural}/:#{frame[:parent]}_id"]
            when :as_scope then frame[:path] ? [frame[:path]] : []
            when :singular_scope then [frame[:path_segment]]
            else []
            end
          end

          # ADR-39: inflection delegates to the shared
          # `Rigor::Plugin::Inflector`, which calls the real
          # `ActiveSupport::Inflector` (the authority Rails itself uses to
          # generate helper names) when available, falling back to a
          # built-in approximation otherwise. This replaces the hand-tuned
          # AS-replica these methods used to carry — every special case
          # they accreted (`news` uncountable, `media`→`medium`,
          # `databases`→`database`, `custom_css` ss-preservation,
          # `async_refresh`→`async_refreshes`) was reverse-engineered
          # `ActiveSupport::Inflector` behaviour, so the real inflector
          # produces the same result for those and the correct one for the
          # words the replica never covered.
          def singularize(word)
            Rigor::Plugin::Inflector.singularize(word)
          end

          def pluralize(word)
            Rigor::Plugin::Inflector.pluralize(word)
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
          when :draw_all
            # `draw_all :user` — from the
            # `action_dispatch-draw_all` gem (used by GitLab
            # FOSS). Same single-file load semantics as `draw`
            # — the gem just allows multiple route-dir search
            # paths (we look in the one we know about).
            # GitLab's `draw_all :user` loads
            # `config/routes/user.rb` containing `devise_for
            # :users, controllers: ...` plus the broader user
            # route catalogue; without this every Devise
            # session helper reads as `unknown-helper`.
            load_drawn_routes(node, context)
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
          when :get, :post, :patch, :put, :delete, :match
            # `match 'login', :to => 'a#b', :as => :signin, :via => [:get, :post]`
            # generates the same helper-name shape as `get` /
            # `post` (first arg = path string, `:as` overrides the
            # derived helper name). The only difference is the
            # HTTP-method set (driven by `:via`); the helper-name
            # generation logic is identical, so reuse the same
            # handler. Redmine relies heavily on `match` for
            # multi-method endpoints (`account/lost_password`,
            # `news/preview`, etc.).
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
          when :mount
            handle_mount(node, context)
          when :with_options
            handle_with_options(node, context)
          when :concern
            handle_concern_definition(node, context)
          when :direct
            # `direct(:name) do |args...| ... end` — Rails DSL
            # for a custom URL helper. We register `name_path`
            # and (auto-paired) `name_url`. The arity comes
            # from the block's required-parameter count. Only
            # literal Symbol/String names are handled here;
            # non-literal forms are caught by the
            # `detect_alias_rule_in_each` walker upstream.
            handle_direct(node, context)
          when :each
            # `.each do |name| ... end` — scan the block for
            # the GitLab `direct(name.sub(X, Y)) do ... end`
            # alias-generation idiom. If found, record the
            # (X, Y) pair so `apply_alias_rules` can expand
            # every matching registered entry.
            detect_alias_rule_in_each(node, context)
            interpret_block_body(node, context)
          else
            interpret_block_body(node, context)
          end
        end

        # `direct(:name) do |arg1, arg2, ...| ... end` — Rails
        # adds a custom URL helper. We register `name_path`
        # with the block's required-arg count as the arity (the
        # auto-pairing in `parse` adds `name_url`). Only handled
        # for literal Symbol or String first-arg.
        def handle_direct(node, context)
          name = Rigor::Source::Literals.symbol_or_string_name(node.arguments&.arguments&.first)
          return if name.nil? || name.empty?

          block = node.block
          arity = if block.is_a?(Prism::BlockNode)
                    block_required_arity(block)
                  else
                    0
                  end

          context.entries << HelperTable::Entry.new(
            name: name.end_with?("_path") || name.end_with?("_url") ? name : "#{name}_path",
            arity: arity, path: "/<direct:#{name}>",
            http_method: :get, action: :custom
          )
        end

        def block_required_arity(block_node)
          params = block_node.parameters
          return 0 unless params.is_a?(Prism::BlockParametersNode)
          return 0 unless params.parameters.is_a?(Prism::ParametersNode)

          (params.parameters.requireds || []).size
        end

        # Walks a `.each do |loop_var| ... end` body looking for:
        #   - `<new_name_var> = <loop_var>.sub(FROM_STR, TO_STR)`
        #   - `direct(<new_name_var>) do |...| ... end`
        # When both shapes appear with the same `<new_name_var>`,
        # registers `(FROM_STR, TO_STR)` as an alias rule. The
        # iterated collection (`Rails.application.routes.set`)
        # is assumed to yield the names of already-registered
        # helpers — GitLab's idiom. Other iterations that happen
        # to match the shape are rare; the FP risk is bounded
        # because alias generation only adds entries.
        def detect_alias_rule_in_each(each_node, context)
          block = each_node.block
          return unless block.is_a?(Prism::BlockNode)

          loop_var = first_block_parameter_name(block)
          return if loop_var.nil?

          body = block.body
          return if body.nil?

          # First pass: gather every `<var> = <loop_var>.sub(FROM, TO)`
          # assignment.
          sub_assignments = {}
          walk_for_alias_pattern(body) do |node|
            next unless node.is_a?(Prism::LocalVariableWriteNode)
            next unless node.value.is_a?(Prism::CallNode)
            next unless node.value.name == :sub

            recv = node.value.receiver
            next unless recv.is_a?(Prism::LocalVariableReadNode) && recv.name == loop_var

            args = node.value.arguments&.arguments || []
            next if args.size != 2

            from = string_value(args[0])
            to = string_value(args[1])
            next if from.nil? || to.nil?

            sub_assignments[node.name] = [from, to]
          end

          return if sub_assignments.empty?

          # Second pass: find `direct(<var>) do ... end` calls
          # whose first arg is one of the captured assignment
          # variables.
          walk_for_alias_pattern(body) do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :direct
            next if node.arguments.nil?

            first = node.arguments.arguments.first
            next unless first.is_a?(Prism::LocalVariableReadNode)
            next unless (rule = sub_assignments[first.name])

            context.register_alias_rule(rule[0], rule[1])
          end
        end

        def walk_for_alias_pattern(node, &)
          return unless node.is_a?(Prism::Node)

          yield node
          node.compact_child_nodes.each { |child| walk_for_alias_pattern(child, &) }
        end

        def first_block_parameter_name(block_node)
          params = block_node.parameters
          return nil unless params.is_a?(Prism::BlockParametersNode)
          return nil unless params.parameters.is_a?(Prism::ParametersNode)

          required = params.parameters.requireds
          return nil if required.nil? || required.empty?

          first = required.first
          first.respond_to?(:name) ? first.name : nil
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

        # `with_options X do ... end` — applies the `X`
        # options hash as defaults for every call inside the
        # block. Mastodon's `with_options only: [:index],
        # concerns: :batch do resources :links; resources
        # :tags; end` lets us register the inner resources
        # with the implicit defaults — closing `batch_*_path`
        # cluster generated via the `:batch` concern.
        #
        # We push a `:with_options` frame carrying the
        # defaults; `effective_options_for(node)` (in
        # `handle_resources` / `handle_resource`) merges them
        # in before reading specific option keys.
        def handle_with_options(node, context)
          defaults = options_hash(node)
          context.push_with_options(defaults) do
            interpret_block_body(node, context)
          end
        end

        # `mount Foo::Engine, at: '/path', as: :name` —
        # mounted Rails engines. The mount adds a single
        # helper for the mount point itself: `<as>_path` /
        # `<as>_url` (arity 0). The engine's own internal
        # helpers are out of scope (they'd need the engine's
        # routes.rb available; almost no static parser
        # follows that). Mastodon uses `mount Sidekiq::Web,
        # at: 'sidekiq', as: :sidekiq` and similar.
        #
        # When `as:` is omitted Rails derives a helper name
        # from the engine class — that's harder to compute
        # statically, so we silently skip.
        def handle_mount(node, context)
          options = options_hash(node)
          as_name = options[:as]
          return if as_name.nil?

          at_path = options[:at]
          path = at_path.is_a?(String) ? "/#{at_path.delete_prefix('/')}" : "/#{as_name}"
          context.entries << HelperTable::Entry.new(
            name: "#{context.helper_prefix}#{as_name}_path",
            arity: context.parent_segment_count,
            path: "#{context.path_prefix}#{path}",
            http_method: nil, action: :mount
          )
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
              sym = Rigor::Source::Literals.symbol(arg)
              skips << sym if sym
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
          # `scope :path_arg, as: :name` (path as a positional
          # arg) vs `scope(path: ':project_id', as: :project)`
          # (path as a `:path` keyword). GitLab's project routes
          # rely on the latter for the `*namespace_id` /
          # `:project_id` outer scopes. The leading `/` is added
          # if missing so the path-prefix join produces clean
          # segments.
          path = string_argument(node, 0) || keyword_value_string(node, :path)
          path = "/#{path}" if path && !path.start_with?("/")
          arity = path ? count_path_placeholders(path) : 0

          if as_name.nil?
            # Even without `:as`, a `scope(path: 'groups/*id')`
            # still contributes its path / arity segments to
            # helpers declared inside (GitLab's
            # `scope(path: 'groups/*id', controller: :groups)
            # do; get :edit, as: :edit_group end` → arity 1).
            # Skip the frame when there's also no path
            # contribution (a pure `scope(module: :foo)` with
            # no helper-name / path effect).
            return interpret_block_body(node, context) if path.nil? || arity.zero?

            context.push_as_scope("", path, arity) do
              interpret_block_body(node, context)
            end
            return
          end

          context.push_as_scope(as_name.to_s, path, arity) do
            interpret_block_body(node, context)
          end
        end

        def handle_resources(node, context)
          name = symbol_argument(node, 0)
          return interpret_block_body(node, context) if name.nil?

          options = effective_options_for(node, context)
          actions = restrict_actions_from(options, DEFAULT_RESOURCE_ACTIONS)
          base_arity = context.parent_segment_count
          # `resources :collections, as: :actor_collections`
          # remaps the helper name family —
          # `actor_collections_path` for index,
          # `actor_collection_path(id)` for show. Path / arity
          # are unaffected. Mastodon uses this inside a
          # concern (`resources :collections, only: [:show],
          # as: :actor_collections`).
          helper_name = options[:as] || name

          register_resourceful_helpers(helper_name, actions, base_arity, context, plural: true)

          context.push_resource(name) do
            replay_concerns_from_options(options, context)
            interpret_block_body(node, context)
          end
        end

        def handle_resource(node, context)
          name = symbol_argument(node, 0)
          return interpret_block_body(node, context) if name.nil?

          options = effective_options_for(node, context)
          actions = restrict_actions_from(options, DEFAULT_SINGULAR_ACTIONS)
          base_arity = context.parent_segment_count
          helper_name = options[:as] || name

          # Singular resource — no `:id` segment, no `:index`
          # / pluralised helper. The "show" helper is
          # `<name>_path` (singular).
          register_resourceful_helpers(helper_name, actions, base_arity, context, plural: false)

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
          replay_concerns_from_options(effective_options_for(resource_node, context), context)
        end

        def replay_concerns_from_options(options, context)
          concerns_value = options[:concerns]
          return if concerns_value.nil?

          Array(concerns_value).each do |concern_name|
            body = context.concern_body(concern_name)
            next if body.nil?

            body.compact_child_nodes.each { |child| interpret(child, context) }
          end
        end

        # Returns the merged option hash for a node — the
        # caller's own options override `with_options`
        # defaults from the surrounding Context stack. Used by
        # `handle_resources` / `handle_resource` so a bare
        # `resources :foo` inside `with_options only: [:index],
        # concerns: :batch do ... end` is treated as if it
        # had those options written inline.
        def effective_options_for(node, context)
          context.with_options_defaults.merge(options_hash(node))
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

          # `:on => :collection` / `:on => :member` inline form
          # — Rails accepts this as a shorthand for `collection
          # do ... end` / `member do ... end` wrappers around a
          # single action. `get 'report', :on => :collection`
          # inside `resources :time_entries` generates
          # `report_time_entries_path` (collection-style: action
          # prefix on the plural resource name). Treat the action
          # name as the path's basename string (Redmine's idiom).
          on_target = keyword_symbol(node, :on)
          if on_target && context.inside_resource_scope?
            path_arg = string_argument(node, 0) || symbol_argument(node, 0)&.to_s
            as_name = keyword_symbol(node, :as) || path_arg
            return register_on_target_action(node, context, as_name, on_target) if as_name
          end

          # `get "/about", to: "static#about", as: :about` —
          # path as the first positional arg. Also handle the
          # hashrocket-key form `get 'help/*path' => 'help#show',
          # as: :help_page` where the path is the String key in
          # the trailing keyword/options hash (its value is the
          # `controller#action`). Without this, the arity check
          # underestimates because the placeholder count comes
          # from a nil path.
          path = string_argument(node, 0) || hashrocket_path_key(node)
          as_name = keyword_symbol(node, :as)
          return if as_name.nil? && path.nil?

          # When `as:` is omitted, Rails derives a helper name
          # from the path for static paths (no :segment). We
          # do the same when the path has no placeholders. The
          # special case `get '/'` inside a `:as_scope` (e.g.
          # `scope path: '/blob/*id', as: :blob do; get '/' end`)
          # has empty path content after stripping the leading
          # slash — Rails reuses the enclosing as_scope's name.
          # We surface that by registering the helper with an
          # empty `as_name`, which `explicit_route_helper_name`
          # then composes from `helper_prefix.chomp("_")`.
          if as_name.nil?
            return if path.nil? || path.include?(":")

            as_name = path.delete_prefix("/").tr("/", "_")
            if as_name.empty? && context.helper_prefix.empty?
              # `get '/'` style — only meaningful when the
              # helper_prefix is non-empty (otherwise Rails would
              # generate a root helper, handled elsewhere).
              return
            end
          end

          name = explicit_route_helper_name(context, as_name)
          total_placeholders = count_path_placeholders(path)
          optional = count_optional_path_placeholders(path)
          base_arity = context.parent_segment_count + total_placeholders
          # Register the maximum-arity entry; if the path
          # carries `(...)` optional segments (e.g.
          # `'settings(/:tab)'`), register additional entries
          # for each smaller arity so the call-site arity check
          # accepts `settings_project_path(:id)` (no `:tab`).
          (0..optional).each do |drop|
            context.entries << HelperTable::Entry.new(
              name: name, arity: base_arity - drop,
              path: "#{context.path_prefix}#{path || ''}",
              http_method: node.name, action: :custom
            )
          end
        end

        # Builds the helper name for an explicit `get` / `post`
        # / `match` route. Rails uses two distinct shapes:
        #
        # - **Outside a `resources` scope** (top-level or inside
        #   `namespace` / `scope`): `<namespace_prefix><as>_path`
        #   — e.g. `match 'login', as: :signin` →
        #   `signin_path`; inside `namespace :admin` →
        #   `admin_signin_path`.
        # - **Inside a `resources` scope**: the `:as` acts as
        #   the ACTION prefix on the resource's singular chain.
        #   `resources :projects do; get 'settings', as:
        #   :settings; end` → `settings_project_path(:id)` (NOT
        #   `project_settings_path`). The namespace prefix still
        #   leads: `namespace :admin do; resources :projects do;
        #   get 'foo', as: :bar; end; end` →
        #   `admin_bar_project_path(:id)`.
        def explicit_route_helper_name(context, as_name)
          # Empty `as_name` is the `get '/'`-inside-an-as_scope
          # case (e.g. `scope path: '/blob/*id', as: :blob do;
          # get '/' end` → `blob_path(:id)`). Use the
          # helper_prefix as-is (drop the trailing underscore)
          # — Rails reuses the enclosing scope's name verbatim.
          return "#{context.helper_prefix.chomp('_')}_path" if as_name.to_s.empty?

          if context.inside_resource_scope?
            "#{context.namespace_only_prefix}#{as_name}_#{context.resource_singular_chain}path"
          else
            "#{context.helper_prefix}#{as_name}_path"
          end
        end

        # True when the call is `<verb> :symbol [, options...]`
        # or `<verb> 'string'` inside one of:
        # - a `member do ... end` / `collection do ... end`
        #   block (canonical shorthand context), or
        # - a `resources :name do ... end` / `resource :name
        #   do ... end` block at the *direct* nesting level.
        #   Rails defaults a bare symbol- or string-named verb
        #   inside resources to a member action (GitLab's
        #   `resource :application_settings do; match :general,
        #   via: [...] end` → `general_application_settings_path`).
        def member_collection_shorthand?(node, context)
          return false unless context.innermost_action_block || context.inside_resource_scope?

          first_arg = node.arguments&.arguments&.first
          return true if first_arg.is_a?(Prism::SymbolNode)

          # A plain action-name string with no `/` or `:` —
          # treat it as if it were a symbol (`get 'report'` ==
          # `get :report` inside member/collection block).
          first_arg.is_a?(Prism::StringNode) &&
            !first_arg.unescaped.include?("/") &&
            !first_arg.unescaped.include?(":")
        end

        # Generates the member / collection action helper.
        # Member: `<action>_<helper_prefix>path(id)`, arity =
        #   parent_segment_count (which already includes the
        #   enclosing resource's `:id`).
        # Collection: `<action>_<plural_helper_prefix>path`,
        #   arity = parent_segment_count - 1 (no `:id` segment;
        #   the collection URL is /<resource>/<action>).
        def register_member_collection_action(node, context)
          action_name = symbol_argument(node, 0)&.to_s ||
                        string_argument(node, 0).to_s
          frame = context.innermost_action_block
          # No `member do` / `collection do` wrapper but we're
          # inside a resources block — Rails defaults a bare
          # `<verb> :symbol` inside resources to a MEMBER
          # action (e.g. `get :preview` → `preview_<singular>_path
          # (:id)`).
          if frame.nil?
            register_member_action(node, context, action_name)
          elsif frame[:kind] == :member_block
            register_member_action(node, context, action_name)
          else
            register_collection_action(node, context, action_name, frame)
          end
        end

        # `get 'report', :on => :collection` (or `:member`)
        # inline form inside `resources`. The helper name shape
        # matches member_action / collection_action: the action
        # name prefixes the resource's singular (member) or
        # plural (collection). Closes Redmine's
        # `report_time_entries_path` cluster.
        def register_on_target_action(node, context, action_name, on_target)
          scope_frame = context.innermost_scope_frame
          return if scope_frame.nil?

          parent_singular = scope_frame[:parent]
          parent_plural = scope_frame[:parent_plural] || parent_singular

          case on_target
          when :member
            name = "#{action_name}_#{context.helper_prefix}path"
            arity = context.parent_segment_count
          when :collection
            plural_prefix = context.helper_prefix.sub(/#{parent_singular}_\z/, "#{parent_plural}_")
            name = "#{action_name}_#{plural_prefix}path"
            arity = [context.parent_segment_count - 1, 0].max
          else
            return
          end

          context.entries << HelperTable::Entry.new(
            name: name, arity: arity,
            path: "#{context.path_prefix}/#{action_name}",
            http_method: node.name, action: :custom
          )
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
          # Stub: always returns true so member / collection
          # blocks descend. The singular-resource frame
          # (`push_singular_resource`) is modelled in Context;
          # a future caller could use it to tighten this check.
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
          # Rails adds `_index_` whenever `singular == plural`
          # — including for UNCOUNTABLE nouns (Redmine's
          # `resources :news` registers `news_index_path` for
          # the index). The earlier "skip UNCOUNTABLE" carve-out
          # was empirically wrong; only the
          # IRREGULAR-singular path (e.g. `media → medium`)
          # actually has `singular != plural` and skips
          # `_index_`.
          index_name = if name.to_s == singular
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
          restrict_actions_from(options_hash(node), default)
        end

        def restrict_actions_from(options, default)
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

        # Reads a keyword option whose value is a literal String
        # (returned as-is). Returns nil when the key is missing
        # or the value is non-literal. Used for `scope(path:
        # ':project_id', ...)` shape parsing where `:path` is
        # passed as a keyword rather than a positional arg.
        def keyword_value_string(node, key)
          value = options_hash(node)[key]
          value.is_a?(String) ? value : nil
        end

        # `get 'help/*path' => 'help#show', as: :help_page` —
        # the path lives in a String-keyed AssocNode of the
        # trailing keyword/options hash (its value is the
        # `controller#action` String). Returns the path String,
        # or nil when no such hashrocket-key entry exists.
        def hashrocket_path_key(node)
          args = node.arguments&.arguments || []
          last = args.last
          return nil unless last.is_a?(Prism::KeywordHashNode)

          last.elements.each do |element|
            next unless element.is_a?(Prism::AssocNode)
            next unless element.key.is_a?(Prism::StringNode)

            return element.key.unescaped
          end
          nil
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

          # Both `:name` (regular segment) and `*name` (wildcard
          # / "globbing" segment) are Rails path parameters and
          # contribute to helper arity. GitLab's
          # `path: '*namespace_id'` outer scope adds 1 to the
          # arity of every helper underneath.
          path.scan(/[:*][a-z_][a-z0-9_]*/).size
        end

        # Number of placeholders inside `(...)` groups — Rails'
        # optional-segment syntax (`'settings(/:tab)'`). Required
        # arity is `count_path_placeholders - count_optional`;
        # callers accepting a `(required..required+optional)`
        # arity range register an entry per achievable arity.
        def count_optional_path_placeholders(path)
          return 0 if path.nil?

          path.scan(/\([^)]*\)/).sum { |group| group.scan(/[:*][a-z_][a-z0-9_]*/).size }
        end

        # ADR-39 — delegates to the shared inflector (real
        # `ActiveSupport::Inflector` when available). Previously a
        # hand-tuned AS-replica kept in sync with `Context#singularize`;
        # both now share the one authoritative implementation.
        def singularize_word(word)
          Rigor::Plugin::Inflector.singularize(word)
        end
      end
    end
  end
end
