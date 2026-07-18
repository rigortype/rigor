# frozen_string_literal: true

module Rigor
  module Plugin
    # Raised inside the loader (and surfaced as a diagnostic by the analyzer) when a plugin entry cannot be
    # resolved or instantiated. Carries the failing plugin reference plus the underlying cause so the diagnostic
    # message stays precise.
    #
    # ADR-2 § "Plugin Trust and I/O Policy" requires plugin failures to be isolated at the analyzer boundary;
    # this class is the carrier for that contract on the loading side.
    class LoadError < StandardError
      attr_reader :plugin_ref, :cause_class, :reason

      # #194 slice 1 — the file `require` resolved the plugin gem to, when the require SUCCEEDED but the
      # later configuration / instantiation step then failed. The loader stamps it in a rescue after a
      # successful require (a require that failed outright never resolves a file and leaves this nil), so a
      # config/init failure names the exact plugin copy it loaded from — the engine↔plugin version skew that
      # made #194 a multi-round diagnosis. Consumed by the `plugin_loader.load-error` diagnostic message and
      # the `rigor plugins` load-error row.
      attr_accessor :resolved_path

      # ADR-9 slice 5 introduces two new reason codes alongside the implicit "load failure" used for require /
      # configuration / init failures:
      #
      #   - `:missing-producer` — a non-optional `manifest(consumes:)` entry names a `(plugin_id, name)` no
      #     loaded plugin produces.
      #   - `:dependency-cycle` — the consumes graph forms a cycle.
      #
      # Older callers omit `reason:` and the field defaults to nil (the legacy "load failure" envelope).
      def initialize(message, plugin_ref:, cause: nil, reason: nil, resolved_path: nil)
        super(message)
        @plugin_ref = plugin_ref
        @cause_class = cause&.class
        @reason = reason&.to_sym
        @resolved_path = resolved_path
      end
    end
  end
end
