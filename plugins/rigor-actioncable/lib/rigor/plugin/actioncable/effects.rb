# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class Actioncable < Rigor::Plugin::Base
      # rigor-actioncable's effect contract (ADR-103 WD10; design note § 11.2; issue #387).
      #
      # A broadcast leaves the process — through Redis, through the async in-memory adapter, or through
      # Solid Cable's database table, depending on `config/cable.yml`. Bare `io` is the only sound
      # transport, and `rails.actioncable.broadcast` is what a reviewer means when they say "this model
      # callback pushes to every connected browser".
      #
      # Turbo Streams' `broadcast_*` family rides the same rows: it is ActionCable underneath, and a
      # `broadcast_replace_later_to` in a model callback is exactly the effect a policy on `app/models/**`
      # exists to surface.
      module Effects
        CHANNEL = "ActionCable::Channel::Base"
        SERVER = "ActionCable.server"
        BROADCASTING = ["io", "rails.actioncable.broadcast"].freeze

        # `Turbo::Broadcastable`'s class-body-declared broadcasts, called on a model instance.
        TURBO_SELECTORS = %w[
          broadcast_append_to broadcast_prepend_to broadcast_replace_to broadcast_update_to
          broadcast_remove_to broadcast_before_to broadcast_after_to broadcast_action_to
          broadcast_render_to broadcast_refresh_to
        ].freeze

        # The `_later` twins enqueue an ActiveJob that broadcasts, so they carry the enqueue meaning too.
        TURBO_LATER_SELECTORS = TURBO_SELECTORS.map { |name| "#{name.delete_suffix('_to')}_later_to" }.freeze

        LATER = (BROADCASTING + ["rails.activejob.enqueue", "job.enqueue"]).freeze

        module_function

        def attributions
          channel_rows + server_rows + turbo_rows
        end

        def channel_rows
          [
            row(CHANNEL, :broadcast_to, BROADCASTING, singleton: true,
                                                      why: "publishes to the channel's stream — out of this process, through whatever " \
                                                           "`config/cable.yml` names"),
            row(CHANNEL, :transmit, BROADCASTING,
                why: "sends a message down this subscriber's own connection"),
            row(CHANNEL, :stream_from, BROADCASTING,
                why: "subscribes the connection to a stream, which registers with the pubsub adapter"),
            row(CHANNEL, :stream_for, BROADCASTING, why: "the model-keyed `stream_from`")
          ]
        end

        def server_rows
          [
            row(SERVER, :broadcast, BROADCASTING, why: "the bare pubsub publish"),
            row("ActionCable.server.pubsub", :broadcast, BROADCASTING, why: "the adapter-level publish")
          ]
        end

        def turbo_rows
          TURBO_SELECTORS.map do |selector|
            row("ActiveRecord::Base", selector, BROADCASTING,
                why: "Turbo Streams broadcasts over ActionCable — a model callback that pushes HTML to " \
                     "every connected browser is exactly the effect an `app/models/**` policy names")
          end +
            TURBO_LATER_SELECTORS.map do |selector|
              row("ActiveRecord::Base", selector, LATER,
                  why: "the `_later` twin enqueues a job that broadcasts, so it carries the enqueue " \
                       "meaning as well as the broadcast one")
            end
        end

        def row(receiver, selector, labels, why:, singleton: false)
          EffectAttribution.new(receiver: receiver, method: selector, labels: labels,
                                singleton: singleton, discharge: true, why: why)
        end

        def entry_points
          [
            EffectEntryPoints.new(
              name: "rails-channels", globs: ["app/channels/**/*.rb"],
              why: "channel callbacks — `subscribed`, `receive` and friends are invoked by the framework"
            )
          ]
        end
      end
    end
  end
end
