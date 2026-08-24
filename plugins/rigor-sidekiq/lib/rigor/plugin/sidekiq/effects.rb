# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class Sidekiq < Rigor::Plugin::Base
      # rigor-sidekiq's effect contract (ADR-103 WD4 / WD10; [#456](https://github.com/rigortype/rigor/issues/456)).
      #
      # `job.enqueue` shipped in the vocabulary with nothing producing it. Across two Rails applications
      # the corpus census found zero instances of it, while Mastodon alone writes 219 `perform_async`-shaped
      # call sites with this plugin loaded — so the label a policy would actually name ("nothing on this
      # path may enqueue work") could not be written against anything.
      #
      # ## Why the rows key on a module
      #
      # A Sidekiq worker has no base class: it is `class TriggerWebhookWorker; include Sidekiq::Job`. Every
      # other first-party plugin's rows key on a base class and reach a project subclass through the
      # project's own `class … <` lines, which is a walk that cannot see an `include` — so until #456 taught
      # `Effects::PluginFacts#ancestry` to walk included modules beside the superclass, no spelling of these
      # rows could have matched. The marker modules are the plugin's existing `worker_marker_modules:`
      # config, so a project that includes its own concern instead names it once and gets both the arity
      # check and these rows.
      #
      # ## What is deliberately not here
      #
      # `perform_inline` / `perform_sync` run the job on the caller's stack. They are not an enqueue and
      # must not carry `job.enqueue`; the honest reading is an edge into the worker's own `#perform`, which
      # {Rigor::Plugin::EffectEdge::TARGETS} spells only for the ActiveJob shape today. A row claiming the
      # enqueue for them would be worse than the silence.
      module Effects
        # Redis is the transport, and unlike ActiveJob's adapter there is nothing to read: a project that
        # loads Sidekiq has chosen it. `io.net` rather than `io` because the round trip is a socket in every
        # deployment worth naming — a unix socket is still `io.net`'s subsystem, not the filesystem's.
        TRANSPORT = ["io.net"].freeze

        # The meaning half, and the reason this file exists: what a policy names.
        MEANING = ["job.enqueue"].freeze

        LABELS = (TRANSPORT + MEANING).freeze

        # The class-side enqueues. `perform_bulk` takes an array of argument arrays and enqueues each.
        SINGLETON_ENQUEUES = %w[perform_async perform_in perform_at perform_bulk].freeze

        # `Worker.set(queue: "low").perform_async(…)` — `set` returns a lazy `Setter` that has enqueued
        # nothing, so the enqueue is one link further out, keyed on the class that produced the Setter.
        RESULT_ENQUEUES = %w[perform_async perform_in perform_at perform_bulk].freeze

        WHY = "Sidekiq's enqueue is a Redis round trip; `job.enqueue` is the meaning a policy names. " \
              "The row is keyed on the marker module because a Sidekiq worker includes rather than " \
              "inherits."

        module_function

        # @param marker_modules [Array<String>] the modules a worker includes — the plugin's own
        #   `worker_marker_modules:` config, so one project setting drives the arity check and these rows.
        def attributions(marker_modules)
          marker_modules.flat_map do |marker|
            SINGLETON_ENQUEUES.map do |selector|
              EffectAttribution.new(receiver: marker, method: selector, labels: LABELS, singleton: true,
                                    discharge: true, why: WHY)
            end +
              RESULT_ENQUEUES.map do |selector|
                EffectAttribution.new(
                  receiver: marker, method: selector, labels: LABELS, on_result: true, discharge: true,
                  why: "#{WHY} Matched on the RESULT of a call to the worker class, which is the shape " \
                       "`Worker.set(queue: \"low\").perform_async(…)` takes."
                )
              end
          end
        end
      end
    end
  end
end
