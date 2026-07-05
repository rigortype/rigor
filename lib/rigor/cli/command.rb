# frozen_string_literal: true

module Rigor
  class CLI
    # Base class for the `rigor <subcommand>` command objects.
    #
    # Every subcommand captured the same invariant wiring — the argument vector plus the output and error streams — in
    # an identical `initialize(argv:, out:, err:)`, and defaulted the streams inconsistently (some to `$stdout` /
    # `$stderr`, most not at all). Centralising it here gives one consistent shape and lets a test instantiate a command
    # with just `argv:` (the streams default so a spec can pass a `StringIO` for one and ignore the other).
    #
    # Subclasses read the `@argv` / `@out` / `@err` ivars directly, as they did before.
    class Command
      def initialize(argv:, out: $stdout, err: $stderr)
        @argv = argv
        @out = out
        @err = err
      end

      private

      # Expands `args` (a mix of files and directories) into a unique list of `.rb` paths, recursing into directories.
      # Returns nil — after writing `<command_name>: not a file or directory: <arg>` to `@err` — on the first arg that
      # is neither. Shared by the path-walking commands (`type-scan`, `coverage`).
      def collect_paths(args, command_name:)
        paths = []
        args.each do |arg|
          if File.directory?(arg)
            paths.concat(Dir.glob(File.join(arg, "**/*.rb")))
          elsif File.file?(arg)
            paths << arg
          else
            @err.puts("#{command_name}: not a file or directory: #{arg}")
            return nil
          end
        end
        paths.uniq
      end
    end
  end
end
