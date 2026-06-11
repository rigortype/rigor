# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    # ADR-25 — a pure RBS-bundle plugin. It ships NO analyzer code:
    # no `diagnostics_for_file`, no `dynamic_return`. Its
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
        # Bumped 2026-05-28 — added Date#midnight /
        # at_midnight / beginning_of_day / end_of_day (Rails
        # aliases that return Time, not Date).
        version: "0.2.0",
        description: "RBS bundle for the most-frequently-flagged ActiveSupport core_ext extensions.",
        signature_paths: ["sig"]
      )
    end

    Rigor::Plugin.register(ActivesupportCoreExt)
  end
end
