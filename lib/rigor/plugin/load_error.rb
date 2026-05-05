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
      attr_reader :plugin_ref, :cause_class

      def initialize(message, plugin_ref:, cause: nil)
        super(message)
        @plugin_ref = plugin_ref
        @cause_class = cause&.class
      end
    end
  end
end
