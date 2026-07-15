# frozen_string_literal: true

module Rigor
  module Plugin
    class RspecRails < Rigor::Plugin::Base
      # The set of HTTP-status symbols `have_http_status` accepts.
      #
      # ADR-39 — the HTTP status symbols come from the **real**
      # `Rack::Utils::SYMBOL_TO_STATUS_CODE` (the authority `have_http_status` itself resolves through
      # `Rack::Utils.status_code`), not a vendored snapshot: a snapshot that lagged the installed Rack
      # would flag a newly-added status symbol as a false `unknown-symbol` (a false positive on working
      # code). When Rack cannot be loaded the symbol set is unknowable, so {known_symbols} returns `nil`
      # and the caller **declines** to flag anything — reduced coverage, never a guess.
      #
      # The Rails status-group aliases (`:success`, `:missing`, …) are a small, stable convention set
      # defined by Rails (`ActionDispatch::TestResponse`) — not a growing catalogue — so they are kept as a
      # constant rather than pulling in actionpack.
      module HttpStatusCodes
        RAILS_STATUS_GROUP_ALIASES = %i[
          informational success successful redirect
          client_error missing server_error error
        ].to_set.freeze

        VALID_NUMERIC_RANGE = (100..599)

        module_function

        # The authoritative set of accepted `have_http_status` symbols (real Rack status symbols ∪ the
        # Rails group aliases), or `nil` when it cannot be determined because Rack is unavailable. A `nil`
        # return means "decline" — the caller MUST NOT flag any symbol as unknown (ADR-39: never guess from
        # a stale copy).
        def known_symbols
          rack = rack_status_symbols
          return nil if rack.nil?

          rack | RAILS_STATUS_GROUP_ALIASES
        end

        # The real `Rack::Utils::SYMBOL_TO_STATUS_CODE` keys, or `nil` when Rack is not loadable. Lazy
        # require (core Rigor carries no Rack dependency; the plugin brings it); memoised for the process.
        def rack_status_symbols
          return @rack_status_symbols if defined?(@rack_status_symbols)

          require "rack/utils"
          @rack_status_symbols = Rack::Utils::SYMBOL_TO_STATUS_CODE.keys.to_set.freeze
        rescue ::LoadError, ::StandardError
          # `::`-qualified: in this lexical scope a bare `LoadError` resolves to `Rigor::Plugin::LoadError`
          # (the plugin-loading error, a StandardError), so the real `::LoadError` (a ScriptError) from a
          # failed require would escape instead of declining.
          @rack_status_symbols = nil
        end
      end
    end
  end
end
