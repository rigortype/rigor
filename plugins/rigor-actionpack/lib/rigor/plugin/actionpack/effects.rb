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

        # The view context a template unit's body runs under — the `self_type:` the plugin declares on
        # every {Rigor::Plugin::TemplateUnit}. A `render` inside a template is an implicit-self call on
        # it, which is what lets one row colour the template → partial edge (#1048).
        VIEW = "ActionView::Base"

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

        # Rails' own name for the implicit render — what `ActionController::Base` calls when an action
        # returns without having answered. The project never writes it, which is exactly the point: the
        # row exists so the engine's unit-level {Rigor::Effects::CalleeRule} has a declaration to read,
        # and it carries no labels because an action that implicitly renders has already been coloured by
        # nothing at all and must not be coloured by a guess (see `why:`).
        IMPLICIT_RENDER = "default_render"

        # Action View's own format lookup order for a template-side render, as DATA the engine's
        # `rails_render_partial` rule copies onto the edge (#1065). While a `.js.erb` template renders, the
        # lookup context holds `[:js, :html]` — `LookupContext#formats=` appends `:html` to a lone `:js` —
        # so `render "watchers"` runs `_watchers.js.erb` where it exists and `_watchers.html.erb`
        # otherwise. The propagator takes the first key a unit answers.
        #
        # `js` is the only entry, because it is the only fallback Action View itself hard-codes. What a
        # `.json`, `.xml` or `.turbo_stream` template falls back to is whatever the REQUEST's formats
        # happened to be (`prepend_formats` puts the template's format in front of them) — an `Accept`
        # header the source never states, Turbo's included — so those keep their taint rather than guess.
        FORMAT_FALLBACKS = { "js" => ["html"] }.freeze

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
              receiver: CONTROLLER, method: selector, labels: RESPONSE, discharge: true, responds: true,
              why: "sets the response on the controller instance — Rack writes the socket later, outside " \
                   "any project method, so this is `mutate.self` and deliberately not `io`"
            )
          end + render_rows + [implicit_render_row]
        end

        # `render` and its two `*_to_string` twins. Each carries a `callee:` so the render site edges to
        # the template's own effect unit (#1048), and each keeps the `template-not-analysed` taint — which
        # now rides the edge: a render whose template produced a unit discharges it, and one whose
        # template the plugin declined (a layout, #1047) or whose target is computed keeps it.
        #
        # Only `render` sets `responds:`. `render_to_string` builds a string and leaves the response
        # unanswered, so an action that calls it and returns still takes Rails' implicit render.
        def render_rows
          RENDERERS.map do |selector|
            EffectAttribution.new(
              receiver: CONTROLLER, method: selector, labels: RESPONSE, discharge: true,
              taint: "template-not-analysed", callee: "rails_render", responds: selector == "render",
              why: "sets the response body from a template. The controller half is fully stated; the " \
                   "template's own effects reach it through the `rails_render` callee edge, and the " \
                   "taint survives on the edge for a target the rule cannot resolve"
            )
          end + [
            EffectAttribution.new(
              receiver: VIEW, method: :render, labels: [], discharge: true,
              taint: "template-not-analysed", callee: "rails_render_partial",
              callee_fallbacks: FORMAT_FALLBACKS,
              why: "a `render` inside a template runs another template. The edge is the whole " \
                   "contribution — what a partial render DOES is what the partial does, and the row " \
                   "reaches it now — while a target the rule cannot resolve keeps the taint. In a view " \
                   "a bare argument names a PARTIAL and `layout:` names one too, which is why this is a " \
                   "separate rule from the controller's"
            )
          ]
        end

        # The implicit render, as an EDGE and nothing else. An action that never answered still renders
        # `<controller>/<action>`, so its summary must include that template's effects — but the fact is
        # the absence of a call, so there is no site to colour, and inventing a `rails.response.write`
        # here would put it on every private helper a controller defines as well.
        def implicit_render_row
          EffectAttribution.new(
            receiver: CONTROLLER, method: IMPLICIT_RENDER, labels: [], discharge: true,
            callee: "rails_implicit_render",
            why: "Rails renders `<controller>/<action>` for an action that answered nothing. The edge " \
                 "is the whole contribution: no label, because an implicit render is observed from a " \
                 "body that made no call, and a label read off an absence would colour every helper"
          )
        end

        # `send_file` streams from disk; `send_data` does not.
        def file_rows
          [
            EffectAttribution.new(
              receiver: CONTROLLER, method: :send_data, labels: RESPONSE, discharge: true, responds: true,
              why: "sets the response body from an in-memory string"
            ),
            EffectAttribution.new(
              receiver: CONTROLLER, method: :send_file, labels: RESPONSE + ["io.fs.read"], discharge: true,
              responds: true, why: "sets the response AND reads the named file off disk"
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
