# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class Activejob < Rigor::Plugin::Base
      # rigor-activejob's effect contract (ADR-103 WD4 / WD10; design note § 11.2 "Deferred execution";
      # issue #387).
      #
      # ## Attribution follows the code, not the clock
      #
      # `perform_later` is the effect; `perform` is not. The job body runs in another process on another
      # stack, so the caller's code does not contain it and there is **no edge** from `perform_later` to
      # `perform` — {Rigor::Plugin::EffectEdge::TARGETS} has no spelling for one. `perform_now` is an
      # ordinary edge, because it is an ordinary call.
      #
      # `set(wait: 1.hour)` returns a `ConfiguredJob` and does nothing, exactly like a Relation builder; the
      # `.perform_later` on it is the origin, which is what `on_result:` expresses.
      #
      # ## The transport is a project fact
      #
      # Argument-blind, an enqueue is bare `io` — true and useless for policy. But a Rails app declares its
      # adapter once, in `config.active_job.queue_adapter`, and reading it turns the row into something a
      # reviewer can act on: under Solid Queue the enqueue is an `INSERT` into `solid_queue_jobs`, and a
      # "no database on this path" envelope is right to object to it. Under Sidekiq it is a Redis round
      # trip. Under `:async` it is a thread in this process and no transport at all; under `:inline` Rails
      # runs the job on the caller's stack, which — and only which — makes `perform_later` a real edge.
      #
      # This is the configuration-level twin of the argument-dependent narrowing the catalogue does for
      # `File.open`'s mode: the same discipline, one scope wider. An unread or per-environment adapter keeps
      # the honest `io`.
      module Effects
        BASE = "ActiveJob::Base"

        # Where a Rails app declares its adapter. Per-environment files are read too, because an app that
        # sets the adapter only in `config/environments/production.rb` is common; agreement across every
        # file that names one is what licenses the narrowing (see {.transport_for}).
        CONFIG_PATHS = ["config/application.rb", "config/environments"].freeze

        SETTING = /queue_adapter\s*=\s*[:"']([a-z_]+)["']?/

        # What each adapter's enqueue actually touches. The absent adapters are the point: anything not
        # listed keeps bare `io`, which is the truthful upper bound for a transport nobody named.
        TRANSPORTS = {
          "solid_queue" => ["io.db.write"], "delayed_job" => ["io.db.write"], "delayed" => ["io.db.write"],
          "que" => ["io.db.write"], "good_job" => ["io.db.write"], "queue_classic" => ["io.db.write"],
          "sidekiq" => ["io.net"], "resque" => ["io.net"], "sneakers" => ["io.net"],
          "shoryuken" => ["io.net"], "backburner" => ["io.net"], "sucker_punch" => [],
          "async" => [], "inline" => [], "test" => []
        }.freeze

        # The meaning half, which is adapter-independent and is what a policy actually names.
        MEANING = ["rails.activejob.enqueue", "job.enqueue"].freeze

        # `X.perform_later`, `X.perform_all_later`, `X.enqueue` — the class-side enqueues.
        SINGLETON_ENQUEUES = %w[perform_later perform_all_later enqueue enqueue_at].freeze

        # `job.enqueue`, and the enqueue on whatever `set(…)` returned.
        RESULT_ENQUEUES = %w[perform_later enqueue enqueue_at].freeze

        module_function

        # @param adapter [String, nil] the adapter the project declares, or nil when it declares none
        #   (or more than one, across environments)
        def attributions(adapter)
          labels = (TRANSPORTS[adapter] || ["io"]) + MEANING
          why = transport_why(adapter)
          SINGLETON_ENQUEUES.map do |selector|
            EffectAttribution.new(receiver: BASE, method: selector, labels: labels, singleton: true,
                                  discharge: true, why: why)
          end +
            RESULT_ENQUEUES.map do |selector|
              EffectAttribution.new(
                receiver: BASE, method: selector, labels: labels, on_result: true, discharge: true,
                why: "#{why} Matched on the RESULT of a call to the job class, which is the shape " \
                     "`WelcomeJob.set(wait: 1.hour).perform_later` takes: `set` is a builder and returns a " \
                     "lazy ConfiguredJob, so the enqueue is one link further out."
              )
            end +
            [EffectAttribution.new(receiver: BASE, method: :enqueue, labels: labels, discharge: true,
                                   why: why)]
        end

        def transport_why(adapter)
          if adapter.nil?
            return "the queue adapter is unread or differs per environment, so the transport stays the " \
                   "honest `io`; `rails.activejob.enqueue` is the meaning a policy names."
          end

          transport = TRANSPORTS[adapter]
          if transport.nil?
            return "`config.active_job.queue_adapter = :#{adapter}` is not an adapter this plugin has a " \
                   "transport for, so the row keeps bare `io`."
          end
          if transport.empty?
            return "`config.active_job.queue_adapter = :#{adapter}` runs the queue inside this process, so " \
                   "the enqueue crosses no transport at all."
          end

          "`config.active_job.queue_adapter = :#{adapter}` makes the enqueue a #{transport.first} — the " \
            "project's own configuration narrowing a transport that is otherwise unknowable."
        end

        # `perform_now` is always an edge. Under `:inline`, so is `perform_later`: Rails genuinely runs the
        # job on the caller's stack there, and refusing the edge would understate a controller action that
        # sends the whole email inline.
        def edges(adapter)
          list = [
            EffectEdge.new(receiver: BASE, target: :perform_now,
                           why: "`Job.perform_now(...)` runs `Job#perform` synchronously, in this process")
          ]
          return list unless adapter == "inline"

          list << EffectEdge.new(
            receiver: BASE, target: :perform_now, method: :perform_later,
            why: "`config.active_job.queue_adapter = :inline` makes `perform_later` run `perform` on the " \
                 "caller's stack; the edge is licensed by the project's own declaration and by nothing else"
          )
        end

        # `reach: [rails-jobs]` — a job's `perform` is an entry point: nothing in the project calls it, and
        # its footprint is what a reviewer asking "what does this job do" wants.
        def entry_points
          [
            EffectEntryPoints.new(
              name: "rails-jobs", globs: ["app/jobs/**/*.rb"],
              why: "ActiveJob jobs — `perform` is invoked by the queue, never by project code"
            )
          ]
        end

        # Reads `config.active_job.queue_adapter` out of the project's configuration. Returns the adapter
        # name when every file that names one agrees, and nil when none does or they disagree — a
        # per-environment split has no single transport, and guessing one would be the wrong kind of
        # precision.
        def detect_adapter(io_boundary, root)
          found = config_files(root).filter_map do |path|
            io_boundary.read_file(path).force_encoding("UTF-8")[SETTING, 1]
          rescue StandardError
            nil
          end.uniq
          found.length == 1 ? found.first : nil
        end

        def config_files(root)
          application = File.join(root, CONFIG_PATHS.first)
          environments = Dir.glob(File.join(root, CONFIG_PATHS.last, "*.rb"))
          ([application] + environments).select { |path| File.file?(path) }
        rescue StandardError
          []
        end
      end
    end
  end
end
