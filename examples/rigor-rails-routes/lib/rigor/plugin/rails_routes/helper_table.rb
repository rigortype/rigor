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
          @by_name = entries.to_h { |entry| [entry.name, entry] }.freeze
          freeze
        end

        # @return [Entry, nil]
        def find(helper_name)
          @by_name[helper_name.to_s]
        end

        # @return [Boolean]
        def known?(helper_name)
          @by_name.key?(helper_name.to_s)
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
          # entry serialises as a small Hash so consumers don't
          # need to require this file's classes.
          @by_name.transform_values do |entry|
            { name: entry.name, arity: entry.arity, path: entry.path,
              http_method: entry.http_method, action: entry.action }
          end
        end
      end
    end
  end
end
