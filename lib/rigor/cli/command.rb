# frozen_string_literal: true

module Rigor
  class CLI
    # Base class for the `rigor <subcommand>` command objects.
    #
    # Every subcommand captured the same invariant wiring — the argument
    # vector plus the output and error streams — in an identical
    # `initialize(argv:, out:, err:)`, and defaulted the streams
    # inconsistently (some to `$stdout` / `$stderr`, most not at all).
    # Centralising it here gives one consistent shape and lets a test
    # instantiate a command with just `argv:` (the streams default so a
    # spec can pass a `StringIO` for one and ignore the other).
    #
    # Subclasses read the `@argv` / `@out` / `@err` ivars directly, as
    # they did before.
    class Command
      def initialize(argv:, out: $stdout, err: $stderr)
        @argv = argv
        @out = out
        @err = err
      end
    end
  end
end
