# frozen_string_literal: true

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # Generates the catalogue of OAuth route helpers a
      # `use_doorkeeper do ... end` block adds to a Rails app's
      # routing table. The set is the Doorkeeper gem's
      # documented default — see Doorkeeper's
      # [Routing](https://github.com/doorkeeper-gem/doorkeeper/wiki/Customizing-routes)
      # documentation; this module mirrors the canonical
      # helper names.
      #
      # Used by `RoutesParser` when it sees a `use_doorkeeper`
      # call. Each generated helper is materialised as a
      # `HelperTable::Entry` so the analyzer's
      # `unknown-helper` rule recognises them. Arity for the
      # `oauth_application_path(:id)` / `oauth_authorized_application_path(:id)`
      # forms is 1 (the `:id`); all other Doorkeeper helpers
      # are arity 0.
      #
      # Scope:
      #
      # - Recognises the standard helper set: authorization,
      #   token, revoke, introspect, token_info, userinfo,
      #   applications (resources), authorized_applications.
      # - Honours `skip_controllers <names>` inside the block
      #   to omit the named controller's helpers.
      # - Does NOT yet honour `controllers ...:` remappings —
      #   those change WHICH class serves the route but not
      #   the helper NAMES, so omitting them is sound.
      # - Does NOT yet honour custom `as:` / `at:` on
      #   `use_doorkeeper` itself.
      module DoorkeeperRoutes
        # Per-controller helper catalogue. Keys are the
        # `skip_controllers :<key>` names; values are the
        # entries (name + arity + path + http_method).
        # Both `_path` and `_url` variants are paired by
        # `RoutesParser` after registration.
        CONTROLLER_HELPERS = {
          authorizations: [
            ["oauth_authorization_path", 0, "/oauth/authorize", :get, :show],
            ["oauth_authorization_url",  0, "/oauth/authorize", :get, :show]
          ],
          tokens: [
            ["oauth_token_path", 0, "/oauth/token", :post, :create],
            ["oauth_token_url",  0, "/oauth/token", :post, :create],
            ["oauth_revoke_path", 0, "/oauth/revoke", :post, :create],
            ["oauth_revoke_url",  0, "/oauth/revoke", :post, :create],
            ["oauth_introspect_path", 0, "/oauth/introspect", :post, :create],
            ["oauth_introspect_url",  0, "/oauth/introspect", :post, :create]
          ],
          token_info: [
            ["oauth_token_info_path", 0, "/oauth/token/info", :get, :show],
            ["oauth_token_info_url",  0, "/oauth/token/info", :get, :show]
          ],
          userinfo: [
            ["oauth_userinfo_path", 0, "/oauth/userinfo", :get, :show],
            ["oauth_userinfo_url",  0, "/oauth/userinfo", :get, :show]
          ],
          applications: [
            ["oauth_applications_path", 0, "/oauth/applications", :get, :index],
            ["oauth_applications_url",  0, "/oauth/applications", :get, :index],
            ["new_oauth_application_path", 0, "/oauth/applications/new", :get, :new],
            ["new_oauth_application_url",  0, "/oauth/applications/new", :get, :new],
            ["edit_oauth_application_path", 1, "/oauth/applications/:id/edit", :get, :edit],
            ["edit_oauth_application_url",  1, "/oauth/applications/:id/edit", :get, :edit],
            ["oauth_application_path", 1, "/oauth/applications/:id", :get, :show],
            ["oauth_application_url",  1, "/oauth/applications/:id", :get, :show]
          ],
          authorized_applications: [
            ["oauth_authorized_applications_path", 0, "/oauth/authorized_applications", :get, :index],
            ["oauth_authorized_applications_url",  0, "/oauth/authorized_applications", :get, :index],
            ["oauth_authorized_application_path", 1, "/oauth/authorized_applications/:id", :delete, :destroy],
            ["oauth_authorized_application_url",  1, "/oauth/authorized_applications/:id", :delete, :destroy]
          ]
        }.freeze

        module_function

        # @param skip [Array<Symbol>] controller names the
        #   project omits via `skip_controllers :name, ...`.
        # @return [Array<HelperTable::Entry>] flattened entries.
        def generate(skip: [])
          skip_set = skip.to_set(&:to_sym)
          CONTROLLER_HELPERS.flat_map do |controller, rows|
            next [] if skip_set.include?(controller)

            rows.map do |name, arity, path, http_method, action|
              HelperTable::Entry.new(
                name: name, arity: arity, path: path,
                http_method: http_method, action: action
              )
            end
          end
        end
      end
    end
  end
end
