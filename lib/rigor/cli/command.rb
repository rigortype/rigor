# frozen_string_literal: true

require_relative "../rooted_glob"
require_relative "../analysis/path_expansion"

module Rigor
  class CLI
    # Base class for the `rigor <subcommand>` command objects.
    #
    # Every subcommand captured the same invariant wiring — the argument vector plus the output and error streams — in
    # an identical `initialize(argv:, out:, err:)`, and defaulted the streams inconsistently (some to `$stdout` /
    # `$stderr`, most not at all). Centralising it here gives one consistent shape and lets a test instantiate a command
    # with just `argv:` (the streams default so a spec can pass a `StringIO` for one and ignore the other).
    #
    # Subclasses read the `@argv` / `@out` / `@err` ivars directly.
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
            paths.concat(RootedGlob.glob(arg, "**/*.rb"))
          elsif File.file?(arg)
            paths << arg
          else
            @err.puts("#{command_name}: not a file or directory: #{arg}")
            return nil
          end
        end
        paths.uniq
      end

      # #2206 — the `.rb` paths `args` names, with a path that is neither a directory nor a `.rb` file reported the way
      # `rigor check` reports it ({Analysis::PathExpansion.diagnostics}): a warning beside files that will be read, an
      # error when nothing will be. The diagnostics go to stderr. Returns nil when one is an error, so the caller exits.
      def collect_paths_reporting(args)
        bad = Analysis::PathExpansion.unusable(args)
        files = Analysis::PathExpansion.ruby_files(args, [])
        diagnostics = Analysis::PathExpansion.diagnostics(bad, any_files: files.any?)
        diagnostics.each { |diagnostic| @err.puts(diagnostic.to_s) }
        return nil if diagnostics.any?(&:error?)

        files.uniq
      end
    end
  end
end
