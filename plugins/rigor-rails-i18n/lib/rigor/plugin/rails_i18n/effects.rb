# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class RailsI18n < Rigor::Plugin::Base
      # rigor-rails-i18n's effect contract (ADR-103 WD10; design note § 11.2; issue #387).
      #
      # `I18n.t` is not pure, and the reason is worth stating because it looks pure: it reads
      # `I18n.locale`, which is per-fiber mutable process state, and on first use it loads the backend's
      # translations. So a translation lookup is `global.read` — which is exactly the kind of label a
      # project puts in `tolerated:` and then stops thinking about, and exactly why the *meaning* label
      # matters more than the transport here. `rails.i18n.translate` is what a presenter envelope names
      # when it wants to permit translation and nothing else.
      #
      # `I18n.locale=` is a `global.write`, and that one is worth surfacing: a presenter that changes the
      # locale changes it for everything downstream in the request.
      module Effects
        I18N = "I18n"
        READ = ["global.read", "rails.i18n.translate"].freeze
        WRITE = ["global.write"].freeze

        LOOKUPS = %w[t t! translate translate! l localize].freeze
        WRITERS = %w[locale= default_locale= backend= load_path= with_locale].freeze

        module_function

        def attributions
          LOOKUPS.map do |selector|
            EffectAttribution.new(
              receiver: I18N, method: selector, labels: READ, singleton: true, discharge: true,
              why: "reads `I18n.locale` (per-fiber mutable process state) and lazily loads the backend's " \
                   "translations; `rails.i18n.translate` is the meaning a presenter envelope permits"
            )
          end +
            WRITERS.map do |selector|
              EffectAttribution.new(
                receiver: I18N, method: selector, labels: WRITE, singleton: true, discharge: true,
                why: "changes process- or fiber-wide translation state, which every later lookup reads"
              )
            end
        end
      end
    end
  end
end
