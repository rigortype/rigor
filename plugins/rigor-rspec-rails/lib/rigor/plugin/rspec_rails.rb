# frozen_string_literal: true

require "rigor/plugin"

require_relative "rspec_rails/have_http_status_analyzer"

module Rigor
  module Plugin
    # rigor-rspec-rails — validates rspec-rails matchers whose arguments are statically checkable.
    #
    # v0.1.0 covers `have_http_status(int_or_symbol)`:
    #
    # - Integer: must be in `100..599`.
    # - Symbol: must be one of the `Rack::Utils::SYMBOL_TO_STATUS_CODE` keys or one of Rails' status-group
    #   aliases (`:success`, `:successful`, `:missing`, `:redirect`, `:error`, `:client_error`,
    #   `:server_error`, `:informational`).
    #
    # ## Why this is a separate plugin from rigor-rspec
    #
    # `rigor-rspec` handles the **type-narrowing** matchers (`be_a`, `be_kind_of`, `be_nil`, `eq(literal)`,
    # etc.) — ones that refine a local's static type so downstream calls in the same `it` body resolve at
    # the narrowed type. `rigor-rspec-rails` handles the **behavioral** matchers — ones that assert runtime
    # state (HTTP status, rendered template, route shape) without narrowing a type. The two are activated
    # independently in `.rigor.yml`.
    #
    # ## Deferred matchers
    #
    # - `render_template(...)` — overlaps with `rigor-actionpack`'s render-target validation (`render
    #   :show` against the view tree). A separate slice would coordinate the two to avoid double-firing.
    # - `route_to(...)` / `redirect_to(...)` — needs the routes table from `rigor-rails-routes`
    #   (`:helper_table` cross-plugin fact). Future slice.
    # - `have_enqueued_job(JobClass)` / `have_enqueued_mail(MailerClass)` — class-existence check overlaps
    #   with engine's `inference.unresolved-constant`; queued behind a decision on which surface owns the
    #   diagnostic.
    # - `have_received(:method)` — overlaps with engine's `call.undefined-method`; same coordination
    #   question.
    # - `be_routable` — needs routes table.
    # - `match_response_schema(...)` (rswag / OpenAPI) — out of scope, separate plugin.
    class RspecRails < Rigor::Plugin::Base
      manifest(
        id: "rspec-rails",
        version: "0.1.0",
        description: "Validates rspec-rails behavioral matchers (have_http_status floor)."
      )

      # ADR-37 — the engine walks each file and hands us every CallNode; the analyzer is now pure per-node
      # logic. The diagnostic points at the matcher name (`message_loc`), reproducing the previous
      # `message_loc || location` positioning.
      node_rule Prism::CallNode do |node, _scope, path|
        violation = HaveHttpStatusAnalyzer.violation_for(node)
        next [] unless violation

        [diagnostic(
          node, path: path, location: node.message_loc,
                message: violation.message, severity: :warning, rule: violation.rule
        )]
      end
    end

    Rigor::Plugin.register(RspecRails)
  end
end
