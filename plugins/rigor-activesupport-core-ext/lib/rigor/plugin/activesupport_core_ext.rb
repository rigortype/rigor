# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    # ADR-25 — a pure RBS-bundle plugin. It ships NO analyzer code:
    # no `diagnostics_for_file`, no `flow_contribution_for`. Its
    # whole contribution is the manifest's `signature_paths: ["sig"]`,
    # which declares the bundled ActiveSupport `core_ext` RBS
    # directory. `Plugin::Loader` resolves that directory against
    # this gem's root and `Environment.for_project` merges it into
    # the RBS environment, so the ActiveSupport core-extension
    # selectors (`3.days`, `"x".squish`, `Time.current`, …) resolve.
    #
    # Activate it like any plugin — no path, no vendoring:
    #
    #   # .rigor.yml
    #   plugins:
    #     - rigor-activesupport-core-ext
    #
    # Coverage scope and rationale: see `README.md` in this gem.
    class ActivesupportCoreExt < Rigor::Plugin::Base
      manifest(
        id: "activesupport-core-ext",
        version: "0.1.0",
        description: "RBS bundle for the most-frequently-flagged ActiveSupport core_ext extensions.",
        signature_paths: ["sig"]
      )
    end

    Rigor::Plugin.register(ActivesupportCoreExt)
  end
end
