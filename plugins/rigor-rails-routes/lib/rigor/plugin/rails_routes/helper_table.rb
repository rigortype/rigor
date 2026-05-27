# frozen_string_literal: true

require_relative "devise_routes"

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # Frozen catalogue of route helpers parsed from
      # `config/routes.rb`. Each entry maps a helper name
      # (`users_path`, `edit_user_path`, …) to the metadata
      # downstream consumers and the analyzer's per-call
      # validation need:
      #
      # - `arity`: number of positional arguments the helper
      #   takes. `users_path` → 0; `user_path(:id)` → 1;
      #   `user_post_path(:user_id, :id)` → 2.
      # - `path`: the path template Rails generates
      #   (`/users/:user_id/posts/:id`).
      # - `http_method`: `:get` / `:post` / `:patch` / `:put` /
      #   `:delete` for the canonical action; `nil` for
      #   helpers that span multiple methods (a `resources`
      #   show helper isn't HTTP-method-specific in the
      #   helper sense — it's path-sensitive only).
      # - `action`: `:index` / `:show` / `:new` / `:edit` /
      #   `:create` / `:update` / `:destroy` for resourceful
      #   routes; `:custom` for explicit `get`/`post`/etc.;
      #   `:root` for the root route.
      #
      # Both `_path` and `_url` forms share the same metadata —
      # the table records each helper twice (once with `_path`,
      # once with `_url`) for `O(1)` lookup at the call site.
      class HelperTable
        Entry = Data.define(:name, :arity, :path, :http_method, :action)

        attr_reader :entries, :custom_helpers, :devise_resources

        # @param entries [Array<Entry>] freshly built; the
        #   factory below is the canonical construction path.
        # @param custom_helpers [Enumerable<String>] names of
        #   project-defined helper methods (typically pulled
        #   from `app/helpers/**/*.rb` by
        #   {HelperDiscoverer}) that the analyzer should treat
        #   as known — they do NOT correspond to a route but
        #   their presence MUST NOT fire `unknown-helper`. No
        #   arity / path metadata is recorded; the analyzer
        #   skips the route-side checks for these names.
        # @param devise_resources [Enumerable<String>] resource
        #   names declared via `devise_for :resource` (already
        #   singularised, e.g. `"user"`). Used to recognise the
        #   dynamic OmniAuth helper family
        #   (`<resource>_<provider>_omniauth_(authorize|callback)_(path|url)`)
        #   whose provider segment is supplied at runtime — no
        #   per-name entry is registered for them but they MUST
        #   NOT fire `unknown-helper` either.
        def initialize(entries, custom_helpers: [], devise_resources: [])
          @entries = entries.freeze
          # Multimap: a single helper name can map to multiple
          # entries when an uncountable-noun resource registers
          # both an arity-0 index helper and an arity-1 show
          # helper under the same `news_path` name. `find`
          # returns the first entry (preserving the previous
          # API); `accepts_arity?` checks against every entry.
          @by_name = entries.group_by(&:name).transform_values(&:freeze).freeze
          @custom_helpers = custom_helpers.to_set.freeze
          @devise_resources = devise_resources.to_set(&:to_s).freeze
          freeze
        end

        # @return [Entry, nil] First matching entry; for the
        #   uncountable-noun case this is the index helper
        #   (the show helper is also registered but starts
        #   second).
        def find(helper_name)
          @by_name[helper_name.to_s]&.first
        end

        # @return [Boolean]
        def known?(helper_name)
          @by_name.key?(helper_name.to_s)
        end

        # True when `helper_name` is either a registered route
        # helper, a discovered project-defined custom helper,
        # OR a dynamic OmniAuth-shaped helper for one of the
        # declared `devise_for` resources. The
        # `unknown-helper` rule consults this predicate to
        # decide whether to fire — `known?` alone misses
        # custom helpers and OmniAuth providers, which would
        # then false-fire on canonical Rails-app patterns.
        def recognised?(helper_name)
          name = helper_name.to_s
          return true if @by_name.key?(name)
          return true if @custom_helpers.include?(name)

          omniauth_match?(name)
        end

        # `<resource>_<provider>_omniauth_(authorize|callback)_(path|url)` — when
        # `<resource>` matches a declared `devise_for` resource
        # the helper is dynamic-provider Devise OmniAuth. The
        # provider segment is opaque to a static parser, so we
        # accept any non-empty token between the resource and
        # the omniauth suffix.
        def omniauth_match?(name)
          return false if @devise_resources.empty?

          DeviseRoutes::OMNIAUTH_SUFFIXES.any? do |suffix|
            next false unless name.end_with?(suffix)

            stem = name.delete_suffix(suffix)
            @devise_resources.any? do |resource|
              stem.start_with?("#{resource}_") && stem.length > resource.length + 1
            end
          end
        end

        # @return [Boolean] true when any entry under this
        #   helper name accepts the given positional arity.
        #
        # Rails helpers have the signature `helper(*segments, options = {})`,
        # so `expected + 1` is always valid — the extra argument is treated
        # as a query-params/options hash (e.g. `users_path(page: 2)` or
        # `user_path(@u, pagination_params(...))`).
        def accepts_arity?(helper_name, arity)
          (@by_name[helper_name.to_s] || []).any? { |entry| entry.arity == arity || entry.arity + 1 == arity }
        end

        # @return [Array<Integer>] all accepted positional
        #   arities for a helper name. Empty when unknown.
        def acceptable_arities(helper_name)
          (@by_name[helper_name.to_s] || []).map(&:arity).uniq
        end

        # All helper names — used by the "did you mean" suggester.
        def names
          @by_name.keys
        end

        def empty?
          @entries.empty?
        end

        def size
          @entries.size
        end

        def to_h
          # Plain dump for fact-store publishing (ADR-9). Each
          # name serialises as a small Hash for the FIRST entry
          # under that name, with `acceptable_arities` carrying
          # the full arity set so cross-plugin consumers can
          # honour the uncountable-noun multi-arity case.
          @by_name.transform_values do |group|
            entry = group.first
            { name: entry.name, arity: entry.arity, path: entry.path,
              http_method: entry.http_method, action: entry.action,
              acceptable_arities: group.map(&:arity).uniq }
          end
        end
      end
    end
  end
end
