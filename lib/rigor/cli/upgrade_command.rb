# frozen_string_literal: true

require_relative "command"

module Rigor
  class CLI
    # `rigor upgrade` — the ADR-50 WD7 migration command skeleton.
    #
    # The real body lands when a concrete backwards-compatibility break gives it a target (e.g. re-running `baseline
    # regenerate` against a strengthened default profile, surfacing renamed suppression ids,
    # reporting `bleeding_edge:` graduations).  Until then it prints the
    # current version and notes that upgrade is queued.
    class UpgradeCommand < Command
      USAGE = "Usage: rigor upgrade [options]"

      # @rbs return: Integer -- CLI exit status.
      def run
        @out.puts("rigor upgrade: No migration target available yet (ADR-50 WD7, queued).")
        @out.puts("Current version: #{Rigor::VERSION}")
        0
      end
    end
  end
end
