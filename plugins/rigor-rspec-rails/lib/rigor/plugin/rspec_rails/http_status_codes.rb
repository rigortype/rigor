# frozen_string_literal: true

module Rigor
  module Plugin
    class RspecRails < Rigor::Plugin::Base
      # Curated set of HTTP-status symbols `have_http_status`
      # accepts. Derived from `Rack::Utils::SYMBOL_TO_STATUS_CODE`
      # (Rack 3.x snapshot) plus Rails' status-group aliases
      # accepted by `ActionDispatch::TestResponse`.
      #
      # Vendored as a frozen Set so the plugin has no
      # `rack` / `actionpack` runtime dependency — checking
      # against a static catalogue is intentional: a future
      # Rack release that adds a new alias would require
      # bumping this constant, but the false-positive risk is
      # bounded (the diagnostic just suggests a typo when in
      # fact the symbol is newly-added).
      module HttpStatusCodes
        SYMBOL_TO_STATUS_CODE = {
          # 1xx Informational
          continue: 100, switching_protocols: 101, processing: 102, early_hints: 103,
          # 2xx Success
          ok: 200, created: 201, accepted: 202, non_authoritative_information: 203,
          no_content: 204, reset_content: 205, partial_content: 206, multi_status: 207,
          already_reported: 208, im_used: 226,
          # 3xx Redirection
          multiple_choices: 300, moved_permanently: 301, found: 302, see_other: 303,
          not_modified: 304, use_proxy: 305, temporary_redirect: 307,
          permanent_redirect: 308,
          # 4xx Client Error
          bad_request: 400, unauthorized: 401, payment_required: 402, forbidden: 403,
          not_found: 404, method_not_allowed: 405, not_acceptable: 406,
          proxy_authentication_required: 407, request_timeout: 408, conflict: 409,
          gone: 410, length_required: 411, precondition_failed: 412,
          payload_too_large: 413, uri_too_long: 414, unsupported_media_type: 415,
          range_not_satisfiable: 416, expectation_failed: 417, misdirected_request: 421,
          unprocessable_entity: 422, unprocessable_content: 422, locked: 423,
          failed_dependency: 424, too_early: 425, upgrade_required: 426,
          precondition_required: 428, too_many_requests: 429,
          request_header_fields_too_large: 431, unavailable_for_legal_reasons: 451,
          # 5xx Server Error
          internal_server_error: 500, not_implemented: 501, bad_gateway: 502,
          service_unavailable: 503, gateway_timeout: 504, http_version_not_supported: 505,
          variant_also_negotiates: 506, insufficient_storage: 507, loop_detected: 508,
          not_extended: 510, network_authentication_required: 511,
          # Rails status-group aliases (see
          # ActionDispatch::TestResponse RESPONSE_PREDICATES)
          informational: :informational_group, success: :success_group,
          successful: :success_group, redirect: :redirect_group,
          client_error: :client_error_group, missing: :client_error_group,
          server_error: :server_error_group, error: :server_error_group
        }.freeze

        KNOWN_SYMBOLS = SYMBOL_TO_STATUS_CODE.keys.to_set.freeze

        VALID_NUMERIC_RANGE = (100..599)
      end
    end
  end
end
