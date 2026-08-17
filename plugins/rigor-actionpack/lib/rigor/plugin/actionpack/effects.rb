# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # rigor-actionpack's effect contract (ADR-103 WD10 / WD14; design note § 11.2; issue #387).
      #
      # A controller action's effects are mostly writes to the response and to per-request state, and the
      # vocabulary distinguishes them because a reviewer does: `rails.response.write` is "this action
      # answers the request", `rails.session.write` is "this action changes who the user is logged in as".
      #
      # ## `mutate.self`, not `io`
      #
      # `render` and `redirect_to` do not write to a socket. They set `@_response_body` and the status on
      # the controller instance; Rack writes it later, outside any project method. So the honest label is
      # `mutate.self` plus the framework meaning — and an envelope forbidding `io` in a service object is
      # not violated by a helper that happens to call `render_to_string`.
      #
      # `render` additionally keeps a **taint**: the template is not an effect unit yet (ADR-103 WD11 /
      # issue #392), so what the view does is genuinely unknown and the summary says so rather than
      # pretending the action stops at the `render` line.
      #
      # ## The self-path rows
      #
      # `session[:user_id] = id` is `[]=` on the result of a receiver-less `session`, and nothing types
      # that result. The `self.session` spelling matches the receiver expression as written, scoped by
      # `within:` to classes whose project ancestry reaches `ActionController::Base` — so a `session`
      # method on some unrelated project class is not mistaken for this one.
      module Effects
        CONTROLLER = "ActionController::Base"

        RESPONSE = ["mutate.self", "rails.response.write"].freeze
        SESSION_WRITE = ["mutate", "rails.session.write"].freeze
        SESSION_READ = ["io", "rails.session.read"].freeze
        COOKIE_WRITE = ["mutate", "rails.cookie.write"].freeze
        FLASH_WRITE = ["mutate", "rails.flash.write"].freeze

        # Response writers that say everything about themselves.
        RESPONSE_WRITERS = %w[redirect_to redirect_back redirect_back_or_to head].freeze

        # The render family. Same labels, plus the `template-not-analysed` taint: what the controller does
        # is fully stated, and what the TEMPLATE does is unknown until views are effect units (ADR-103
        # WD11 / issue #392). A summary that stopped at the `render` line and read exhaustive would be
        # the one genuinely misleading row in the whole Rails layer.
        RENDERERS = %w[render render_to_string render_to_body].freeze

        # The cookie jars a Rails app writes through.
        COOKIE_JARS = ["self.cookies", "self.cookies.signed", "self.cookies.encrypted",
                       "self.cookies.permanent"].freeze

        module_function

        def attributions
          response_rows + file_rows + session_rows + cookie_rows + flash_rows
        end

        def response_rows
          RESPONSE_WRITERS.map do |selector|
            EffectAttribution.new(
              receiver: CONTROLLER, method: selector, labels: RESPONSE, discharge: true,
              why: "sets the response on the controller instance — Rack writes the socket later, outside " \
                   "any project method, so this is `mutate.self` and deliberately not `io`"
            )
          end + render_rows
        end

        def render_rows
          RENDERERS.map do |selector|
            EffectAttribution.new(
              receiver: CONTROLLER, method: selector, labels: RESPONSE, discharge: true,
              taint: "template-not-analysed",
              why: "sets the response body from a template. The controller half is fully stated; the " \
                   "template's own effects are unknown until views become effect units, and the taint " \
                   "is how the summary says so rather than reading exhaustive"
            )
          end
        end

        # `send_file` streams from disk; `send_data` does not.
        def file_rows
          [
            EffectAttribution.new(
              receiver: CONTROLLER, method: :send_data, labels: RESPONSE, discharge: true,
              why: "sets the response body from an in-memory string"
            ),
            EffectAttribution.new(
              receiver: CONTROLLER, method: :send_file, labels: RESPONSE + ["io.fs.read"], discharge: true,
              why: "sets the response AND reads the named file off disk"
            )
          ]
        end

        def session_rows
          [
            EffectAttribution.new(
              receiver: "self.session", method: :[]=, labels: SESSION_WRITE, within: CONTROLLER,
              discharge: true,
              why: "writes per-request state whose store may be a cookie, a cache or the database"
            ),
            EffectAttribution.new(
              receiver: "self.session", method: :delete, labels: SESSION_WRITE, within: CONTROLLER,
              discharge: true, why: "same store, same write"
            ),
            EffectAttribution.new(
              receiver: "self.session", method: :[], labels: SESSION_READ, within: CONTROLLER,
              discharge: true,
              why: "reads the session store — `io` because a cache- or database-backed store really does " \
                   "go out to fetch it"
            ),
            EffectAttribution.new(
              receiver: CONTROLLER, method: :reset_session, labels: SESSION_WRITE, discharge: true,
              why: "discards the whole session — the logout write"
            )
          ]
        end

        def cookie_rows
          COOKIE_JARS.flat_map do |jar|
            %i[[]= delete].map do |selector|
              EffectAttribution.new(
                receiver: jar, method: selector, labels: COOKIE_WRITE, within: CONTROLLER, discharge: true,
                why: "queues a Set-Cookie header on the response — state that outlives the request"
              )
            end
          end
        end

        def flash_rows
          ["self.flash", "self.flash.now"].flat_map do |jar|
            %i[[]= alert= notice=].map do |selector|
              EffectAttribution.new(
                receiver: jar, method: selector, labels: FLASH_WRITE, within: CONTROLLER, discharge: true,
                why: "writes the flash, which rides the session into the next request"
              )
            end
          end
        end

        def entry_points
          [
            EffectEntryPoints.new(
              name: "rails-controllers", globs: ["app/controllers/**/*.rb"],
              why: "controller actions — the request entry points; nothing in the project calls them"
            )
          ]
        end
      end
    end
  end
end
