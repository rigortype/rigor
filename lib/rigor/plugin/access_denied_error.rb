# frozen_string_literal: true

module Rigor
  module Plugin
    # Raised when a plugin's I/O attempt fails the active {TrustPolicy}. Surfaced through {IoBoundary} so the
    # analyzer can convert the exception into a `:plugin_loader` diagnostic without crashing `rigor check`.
    #
    # The policy is documented in [ADR-2 § "Plugin Trust and I/O Policy"](../../../docs/adr/2-extension-api.md).
    # `reason:` is one of `:read_outside_scope`, `:network_disabled`, `:url_fetch_failed` or `:url_body_too_large`.
    class AccessDeniedError < StandardError
      attr_reader :reason, :resource

      def initialize(message, reason:, resource: nil)
        super(message)
        @reason = reason
        @resource = resource
      end
    end
  end
end
