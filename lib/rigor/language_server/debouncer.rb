# frozen_string_literal: true

module Rigor
  module LanguageServer
    # Per-key debouncer. The LSP uses this to defer
    # `publishDiagnostics` until the user stops typing (200ms
    # quiet-time floor per LSP UX conventions). Each
    # `schedule(uri, delay:)` cancels the previous task for the
    # same `uri` and queues a new one — only the LAST task in a
    # burst actually runs.
    #
    # Threading model: each scheduled task runs in its own Thread
    # so the dispatcher loop doesn't block. Concurrent writes to
    # STDOUT from the Debouncer's threads + the main dispatch
    # loop are serialised by `SynchronizedWriter`.
    #
    # Cancellation is cooperative: each task carries a
    # `cancelled` flag; new schedules flip the prior task's flag
    # and the prior thread skips the block on wake-up. This is
    # safer than `Thread#kill` for in-flight Ruby code and good
    # enough for the "drop stale debounce" use case.
    class Debouncer
      Task = Struct.new(:thread, :cancelled) # rubocop:disable Lint/StructNewOverride

      def initialize
        @tasks = {}
        @mutex = Mutex.new
      end

      # Schedule `block` to run after `delay` seconds, replacing
      # any pending task for the same `key`. `delay: 0` makes the
      # task fire immediately (still on its own thread); tests
      # pair this with `#flush!` for deterministic assertions.
      def schedule(key, delay:, &block)
        task = Task.new(nil, false)

        previous = @mutex.synchronize do
          prev = @tasks[key]
          @tasks[key] = task
          prev
        end
        previous&.cancelled = true

        task.thread = Thread.new do
          sleep(delay) if delay.positive?
          unless task.cancelled
            begin
              block.call
            rescue StandardError => e
              warn "Debouncer task #{key.inspect}: #{e.class}: #{e.message}"
            end
          end
          @mutex.synchronize { @tasks.delete(key) if @tasks[key] == task }
        end
        nil
      end

      # Wait for every pending task to complete. Used by specs to
      # synchronise with the async schedule; the production
      # `shutdown` path uses `#cancel_all` instead.
      def flush!
        threads = @mutex.synchronize { @tasks.values.map(&:thread) }
        threads.each do |thread|
          thread.join
        rescue StandardError
          # Threads can die from raised exceptions; ignore.
        end
      end

      # Cancel every pending task (sets the flag; the threads
      # exit without running the block). Called on `shutdown` so
      # in-flight publishes don't write to a closed STDOUT.
      def cancel_all
        @mutex.synchronize do
          @tasks.each_value { |t| t.cancelled = true }
          @tasks.clear
        end
      end

      # @return [Integer] number of currently-pending tasks.
      def pending_size
        @mutex.synchronize { @tasks.size }
      end
    end
  end
end
