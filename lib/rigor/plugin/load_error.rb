# frozen_string_literal: true

module Rigor
  module Plugin
    # Raised inside the loader (and surfaced as a diagnostic by the
    # analyzer) when a plugin entry cannot be resolved or
    # instantiated. Carries the failing plugin reference plus the
    # underlying cause so the diagnostic message stays precise.
    #
    # ADR-2 § "Plugin Trust and I/O Policy" requires plugin failures
    # to be isolated at the analyzer boundary; this class is the
    # carrier for that contract on the loading side.
    class LoadError < StandardError
      attr_reader :plugin_ref, :cause_class, :reason

      # ADR-9 slice 5 introduces two new reason codes alongside the
      # implicit "load failure" used for require / configuration /
      # init failures:
      #
      #   - `:missing-producer` — a non-optional `manifest(consumes:)`
      #     entry names a `(plugin_id, name)` no loaded plugin
      #     produces.
      #   - `:dependency-cycle` — the consumes graph forms a cycle.
      #
      # Older callers omit `reason:` and the field defaults to nil
      # (the legacy "load failure" envelope).
      def initialize(message, plugin_ref:, cause: nil, reason: nil)
        super(message)
        @plugin_ref = plugin_ref
        @cause_class = cause&.class
        @reason = reason&.to_sym
      end
    end
  end
end
