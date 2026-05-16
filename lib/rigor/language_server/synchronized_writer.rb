# frozen_string_literal: true

module Rigor
  module LanguageServer
    # Wraps the LSP gem's `Io::Writer` with a Mutex so concurrent
    # writes (the dispatch loop's response writes + the Debouncer's
    # async `publishDiagnostics` writes) don't interleave on the
    # shared STDOUT.
    #
    # Pass-through proxy: `#write(message)` is the only call site
    # the rest of the LSP uses; `#close` is forwarded for
    # completeness.
    class SynchronizedWriter
      def initialize(inner)
        @inner = inner
        @mutex = Mutex.new
      end

      def write(message)
        @mutex.synchronize { @inner.write(message) }
      end

      def close
        @mutex.synchronize { @inner.close }
      end
    end
  end
end
