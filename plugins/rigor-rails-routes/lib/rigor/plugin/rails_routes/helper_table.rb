# frozen_string_literal: true

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

        attr_reader :entries

        # @param entries [Array<Entry>] freshly built; the
        #   factory below is the canonical construction path.
        def initialize(entries)
          @entries = entries.freeze
          # Multimap: a single helper name can map to multiple
          # entries when an uncountable-noun resource registers
          # both an arity-0 index helper and an arity-1 show
          # helper under the same `news_path` name. `find`
          # returns the first entry (preserving the previous
          # API); `accepts_arity?` checks against every entry.
          @by_name = entries.group_by(&:name).transform_values(&:freeze).freeze
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

        # @return [Boolean] true when any entry under this
        #   helper name accepts the given positional arity.
        def accepts_arity?(helper_name, arity)
          (@by_name[helper_name.to_s] || []).any? { |entry| entry.arity == arity }
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
