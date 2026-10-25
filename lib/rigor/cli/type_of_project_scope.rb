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
        seed = Protection::DiscoverySeed.from_snapshot(configuration: configuration, buffer: buffer)
        seeded(environment: environment, seed: seed)
      end

      # The bare single-file scope, or that scope with `seed`'s tables folded in. Also the one place the language
      # server's editor queries (#2282) fold a {LanguageServer::ProjectContext#discovery_seed_for} seed, so the
      # whole-index copy stays recorded against this file alone.
      def seeded(environment:, seed:)
        base = Scope.empty(environment: environment)
        return base if seed.nil? || seed.empty?

        base.with_discovery(base.discovery.with(**seed))
      end
    end
  end
end
