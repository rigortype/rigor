# frozen_string_literal: true

require_relative "../scope"
require_relative "../protection/discovery_seed"

module Rigor
  class CLI
    # Issue #512 — the scope `rigor type-of` probes with: single-file, plus the cross-file tables a prior
    # `rigor check --incremental` left in the snapshot ({Protection::DiscoverySeed.from_snapshot}) when there are
    # any. A probe never re-parses the project for its seed, so without a reusable snapshot this is the bare
    # `Scope.empty` it always was.
    #
    # The seed is the full {Inference::ProjectSeedTables} fold, so a `contested_*` sibling travels with the member
    # it qualifies (ADR-119): this is a recorded whole-index consumer in `admission_census.yml`.
    module TypeOfProjectScope
      module_function

      def build(environment:, configuration:, buffer: nil)
        base = Scope.empty(environment: environment)
        seed = Protection::DiscoverySeed.from_snapshot(configuration: configuration, buffer: buffer)
        return base if seed.nil? || seed.empty?

        base.with_discovery(base.discovery.with(**seed))
      end
    end
  end
end
