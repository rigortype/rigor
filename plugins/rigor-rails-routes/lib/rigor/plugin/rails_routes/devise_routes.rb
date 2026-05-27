# frozen_string_literal: true

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # Generates the catalogue of route helpers a `devise_for
      # :resources` call adds to a Rails app's routing table.
      # The set is fixed and well-documented (the
      # [Devise wiki](https://github.com/heartcombo/devise/wiki/How-To:-Add-routes-helpers)
      # enumerates every generated helper); the generator
      # mirrors it.
      #
      # Used by `RoutesParser` when it sees a top-level
      # `devise_for :name` (or `devise_for :name, skip:
      # [...]`) call. Each generated helper is materialised as
      # a `HelperTable::Entry` so the analyzer's
      # `unknown-helper` rule recognises them and the arity
      # check accepts the canonical signatures (Devise helpers
      # take zero positional args plus an optional trailing
      # options hash, which `HelperTable#accepts_arity?`
      # already handles via the `arity + 1` rule).
      #
      # Scope:
      #
      # - Recognises the standard six controllers
      #   (`:sessions`, `:passwords`, `:confirmations`,
      #   `:unlocks`, `:registrations`, `:omniauth_callbacks`).
      # - Honours `skip: [...]` to suppress controllers the
      #   project disables.
      # - Honours `path: "..."` to remap the URL path (does
      #   NOT remap the helper-name prefix — Devise uses the
      #   resource name for the helper, not the path).
      # - Does NOT yet honour `as: "..."` overrides, `class_name:`,
      #   `controllers: { ... }` (these are rare; expand on
      #   demand).
      # - `omniauth_callbacks` helpers are dynamic — the
      #   provider name is supplied at call time
      #   (`user_facebook_omniauth_authorize_path`) and Devise
      #   declares them from the configured providers, which
      #   live in an initializer this static parser does not
      #   read. We register the SHAPE-FAMILY suffix matchers
      #   `_omniauth_authorize_path` / `_omniauth_callback_path`
      #   via a separate hook (see `OMNIAUTH_HELPER_PATTERNS`);
      #   these are NOT in the table but consulted by the
      #   `Analyzer.allowed_dynamic_pattern?` check.
      module DeviseRoutes
        # The standard Devise controllers and the helper
        # actions each generates. Keys are the controller
        # name; values are arrays of `[helper_prefix,
        # http_method, action]` triples — `helper_prefix` is
        # the part BEFORE the resource-name segment (Rails
        # produces `<prefix>_<resource>_<suffix>_path`; for
        # the bare `<resource>_session_path` shape the prefix
        # is empty).
        CONTROLLER_HELPERS = {
          sessions: [
            ["new", "session", :get, :new],
            [nil, "session", :post, :create],
            ["destroy", "session", :delete, :destroy]
          ],
          passwords: [
            ["new", "password", :get, :new],
            ["edit", "password", :get, :edit],
            [nil, "password", :get, :show]
          ],
          confirmations: [
            ["new", "confirmation", :get, :new],
            [nil, "confirmation", :get, :show]
          ],
          unlocks: [
            ["new", "unlock", :get, :new],
            [nil, "unlock", :get, :show]
          ],
          registrations: [
            ["cancel", "registration", :get, :show],
            ["new", "registration", :get, :new],
            ["edit", "registration", :get, :edit],
            [nil, "registration", :get, :show]
          ]
        }.freeze

        # Dynamic-provider helper patterns. `_omniauth_authorize_path`
        # and `_omniauth_callback_path` are generated per
        # configured provider (Facebook, GitHub, …) by an
        # initializer this parser does not read. We treat any
        # `<resource>_<provider>_omniauth_(authorize|callback)_(path|url)`
        # call as recognised when the resource is one the
        # project declared via `devise_for`.
        OMNIAUTH_SUFFIXES = %w[
          _omniauth_authorize_path _omniauth_authorize_url
          _omniauth_callback_path _omniauth_callback_url
        ].freeze

        module_function

        # @param resource [String, Symbol] the `devise_for`
        #   argument — typically `:users`. Used as both the
        #   helper-name segment (`new_user_session_path`) and
        #   to derive the resource path.
        # @param skip [Array<Symbol>] controllers the project
        #   disables via `devise_for :users, skip: [:registrations]`.
        # @return [Array<HelperTable::Entry>] one entry per
        #   generated `_path` helper. The caller is expected to
        #   pair `_url` variants the same way `RoutesParser` does
        #   for other entries.
        def generate(resource:, skip: [])
          resource_segment = singularize(resource.to_s)
          skip_set = skip.to_set(&:to_sym)
          entries = []

          CONTROLLER_HELPERS.each do |controller, actions|
            next if skip_set.include?(controller)

            actions.each do |(prefix, suffix, http_method, action)|
              helper = if prefix
                         "#{prefix}_#{resource_segment}_#{suffix}_path"
                       else
                         "#{resource_segment}_#{suffix}_path"
                       end
              path = devise_path_for(resource_segment, controller, action)
              entries << HelperTable::Entry.new(
                name: helper,
                arity: 0,
                path: path,
                http_method: http_method,
                action: action
              )
            end
          end
          entries
        end

        # Returns the set of OmniAuth pattern suffixes the
        # analyzer accepts for a given resource. The analyzer
        # consults this set (via `HelperTable#allows_omniauth?`)
        # when a `*_path` / `*_url` call's name does not match
        # any registered entry and its prefix matches a Devise
        # resource.
        def omniauth_suffixes
          OMNIAUTH_SUFFIXES
        end

        # The same tiny singularizer used by `RoutesParser`.
        # We duplicate the catalogue here so this module does
        # not need to reach into `Context`'s private state.
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

        # Approximate path generation. We don't honour the
        # `path:` Devise option here because the helper NAME
        # is what the analyzer cares about; the `path` field is
        # informational and surfaces only in the `:helper` info
        # diagnostic.
        def devise_path_for(resource_segment, controller, action)
          plural = "#{resource_segment}s"
          base = "/#{plural}"
          case controller
          when :sessions then session_path_for(action)
          when :registrations then registration_path_for(action, base)
          else "#{base}/#{controller}#{action_suffix(action)}"
          end
        end

        def session_path_for(action)
          case action
          when :new then "/users/sign_in"
          when :create then "/users/sign_in"
          when :destroy then "/users/sign_out"
          else "/users/sign_in"
          end
        end

        def registration_path_for(action, base)
          case action
          when :new then "#{base}/sign_up"
          when :edit then "#{base}/edit"
          when :show then base
          else base
          end
        end

        def action_suffix(action)
          case action
          when :new then "/new"
          when :edit then "/edit"
          else ""
          end
        end
      end
    end
  end
end
