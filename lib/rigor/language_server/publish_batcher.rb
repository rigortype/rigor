# frozen_string_literal: true

module Rigor
  module LanguageServer
    # Issue #142 — coalesces keys that become "ready" close together in wall-clock time into ONE batched
    # round instead of firing one round per key. `DiagnosticPublisher` uses this to fold a burst of buffers
    # whose OWN per-URI debounce timers elapse around the same moment (a workspace-wide rename, a git branch
    # switch that touches many open files) into one `#publish_many` dispatch across the fork-based worker
    # pool — but the mechanism itself carries no LSP- or URI-specific knowledge, so it stays a small,
    # independently testable collaborator rather than inline state on `DiagnosticPublisher`.
    #
    # Single-flight: the first `#enqueue` call to arrive owns the round and runs `on_batch` with every key
    # currently pending (deduplicated); a call that arrives while a round is running just adds its key and
    # returns — the running round loops once more before releasing ownership, so nothing queued mid-round is
    # dropped. The same claim/consume shape `DiagnosticPublisher#run_project_round` already uses for the
    # whole-project save round (#246), generalised to an arbitrary key type and an arbitrary batch action.
    class PublishBatcher
      # @rbs on_batch: untyped --
      #   `(keys) -> void`, called with the deduplicated Array of keys pending at the start of one round. May be
      #   called more than once in a row when keys keep arriving while a round runs.
      # @rbs on_error: untyped --
      #   `(exception) -> void`, called when `on_batch` raises. A round must never wedge the coalescing lock for every
      #   future `#enqueue` call — ownership is always released before this fires. Whatever was mid-flight when the
      #   round raised is lost; anything enqueued by a concurrent `#enqueue` call after this round's drain but before
      #   the rescue stays pending and rides the NEXT round instead. Defaults to a no-op (the exception is swallowed
      #   silently).
      def initialize(on_batch:, on_error: nil)
        @on_batch = on_batch
        @on_error = on_error
        @lock = Mutex.new
        @pending = []
        @running = false
      end

      # Adds `key` to the pending set and, if no round is currently running, becomes the round and drains
      # every key pending (looping until none remain) before returning. A call that arrives while another is
      # already running the round returns immediately having only enqueued its key.
      def enqueue(key)
        start = false
        @lock.synchronize do
          @pending << key
          unless @running
            @running = true
            start = true
          end
        end
        return unless start

        run_owned_round
      end

      private

      def run_owned_round
        loop do
          run_batch
          break unless more_pending?
        end
      rescue StandardError => e
        @lock.synchronize { @running = false }
        @on_error&.call(e)
      end

      # True when another key joined `@pending` while this round was running — the caller's loop should run
      # once more rather than release ownership. Releases ownership (resets `@running`) otherwise.
      def more_pending?
        @lock.synchronize do
          if @pending.empty?
            @running = false
            false
          else
            true
          end
        end
      end

      def run_batch
        keys = @lock.synchronize { @pending.uniq.tap { @pending.clear } }
        @on_batch.call(keys)
      end
    end
  end
end
