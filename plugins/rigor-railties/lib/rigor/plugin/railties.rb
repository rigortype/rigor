# frozen_string_literal: true

require "rigor/plugin"

require_relative "railties/effects"

module Rigor
  module Plugin
    # rigor-railties — the Rails **framework core** as an effect vocabulary.
    #
    # Unlike its siblings this plugin runs no analysis: it emits no diagnostic, types no receiver and
    # declares no producer. What it contributes is the part of ADR-103's Rails layer that belongs to no
    # single component gem — `Rails.cache`, `Rails.logger`, `Rails.env`, the application configuration and
    # the credentials — plus the `rails` entry-point preset that `effects.snapshot.reach:` adopts by name.
    #
    # ## Why it is its own plugin
    #
    # The rule ADR-103 WD10 works to is "the row lives in the plugin that owns the gem". `Rails.cache` and
    # `Rails.application` come from railties and activesupport, not from Action Pack or Active Record, and
    # putting them in whichever Rails plugin a project happened to enable would make a model's
    # `Rails.logger.info` visible or invisible depending on whether the app has controllers. A project that
    # wants the Rails effect vocabulary lists this plugin; a project that wants only Active Record's rows
    # does not.
    #
    # It is also the natural owner of the `rails` preset. A preset name may be registered once with one
    # glob set ({Rigor::Effects::EntryPoints.register}), and `rails` spans four directories owned by four
    # different component plugins — so exactly one plugin has to declare the union, and it is this one.
    # Each component plugin additionally declares its own narrower preset (`rails-controllers`,
    # `rails-jobs`, `rails-mailers`, `rails-channels`) for a project that wants a slice.
    #
    #     plugins:
    #       - gem: rigor-railties
    #
    #     effects:
    #       snapshot:
    #         reach: [rails]
    #       tolerated: [telemetry, rails.config.read]
    #
    # ## Cost when effects are off
    #
    # None beyond the load. The manifest's effect fields are frozen arrays; nothing reads them unless the
    # project has an `effects:` block ({Rigor::Plugin::Registry#effect_contributions} is lazy), and the
    # plugin implements no per-call contribution path at all, so `ContributionIndex` never consults it.
    class Railties < Rigor::Plugin::Base
      manifest(
        id: "railties",
        version: "0.1.0",
        description: "The Rails framework-core effect vocabulary: cache, logger, environment, " \
                     "configuration, credentials, and the `rails` entry-point preset.",
        # ADR-103 WD2 — rigor-railties models Rails itself, so it opens the `rails.*` root. Granted only
        # because the engine bundles this plugin ({Rigor::Plugin::FirstParty}); the same declaration from a
        # third-party gem would open `railties.*` and earn a warning.
        effect_root: "rails",
        effect_labels: %w[rails.config.read rails.credentials.read],
        effect_attributions: Effects.attributions,
        effect_entry_points: Effects.entry_points
      )
    end

    Rigor::Plugin.register(Railties)
  end
end
