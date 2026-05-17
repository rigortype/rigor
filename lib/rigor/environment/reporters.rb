# frozen_string_literal: true

module Rigor
  class Environment
    # Mutable container for the per-run analysis reporters
    # ({Rigor::RbsExtended::Reporter} and
    # {Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter}).
    # Held by {Environment} as a single attr; the reporters can be
    # swapped through {Environment#attach_reporters!} so long-lived
    # integrations (the LSP `ProjectContext`, future editor-mode
    # daemons) can share one Environment across many `Runner.run`
    # calls without each call's diagnostic events accumulating into
    # a single reporter pair.
    #
    # Per-publish reset is the contract: at the start of every
    # `Runner.run` in sequential mode, the runner stamps the
    # environment's `Reporters` slot with the runner's own
    # freshly-built reporter pair. Dispatchers / `RbsExtended`
    # consumers continue to write through
    # `environment.rbs_extended_reporter` /
    # `environment.boundary_cross_reporter` — the lookup just hops
    # through the `Reporters` slot rather than reading a frozen
    # ivar.
    #
    # Construction default is `nil` on both slots so existing
    # callers that don't care about reporters (project-default
    # `Environment.default`, test scopes that don't drive
    # dispatch) keep their current behaviour: reporter lookups
    # return nil, and the consumer sites short-circuit on
    # `reporter.nil?`.
    class Reporters
      attr_accessor :rbs_extended, :boundary_cross

      def initialize(rbs_extended: nil, boundary_cross: nil)
        @rbs_extended = rbs_extended
        @boundary_cross = boundary_cross
      end
    end
  end
end
