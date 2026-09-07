# frozen_string_literal: true

module Rigor
  module Protection
    # ADR-70 — the **test-suite** kill oracle, the dynamic sibling of {DiagnosticOracle} on the ADR-69 seam. A
    # mutant is killed iff applying its bytes to the file under test turns the project's test suite **red**. This
    # is the dynamic half of the fused static∪dynamic protection map: a `Dynamic` site Rigor cannot bite (a type
    # survivor) may still be fully guarded by a test.
    #
    # The suite command is the **runner hook** (`--test-command`, e.g. `bundle exec rake`). The runner is
    # injectable so the decision logic is unit-testable without shelling out; the default shells out and reads
    # the process exit status (0 = green / passed).
    #
    # I/O policy: {#killed?} writes the mutant to disk, runs the suite, and **always restores** the original
    # bytes in an `ensure` — a normal exception never leaves a mutant on disk. (A hard interrupt mid-suite is the
    # standard mutation-testing hazard the `ensure` cannot cover; callers running this in CI accept that, as
    # `mutant` / Stryker do.)
    class TestSuiteOracle
      # @rbs command: Array[String] -- The test command (the runner hook)
      # @rbs runner: untyped --
      #   `runner.call(command) -> true iff the suite passed`. Defaults to shelling out via `system`.
      def initialize(command:, runner: nil)
        @command = command
        @runner = runner || method(:shell_run)
      end

      # The baseline: the suite must pass on clean code, else "a mutant survived" is meaningless (every mutant
      # would look killed, or none would). Run once before measuring.
      def green?
        @runner.call(@command)
      end

      # Killed iff the mutant turns the suite red. Restores `original` afterward.
      # @rbs path: String -- The file to (temporarily) overwrite with the mutant
      # @rbs original: String -- The clean bytes to restore
      # @rbs mutant_source: String -- The mutated bytes to test against
      def killed?(path:, original:, mutant_source:)
        File.write(path, mutant_source)
        !@runner.call(@command)
      ensure
        File.write(path, original)
      end

      private

      # Run the suite with Bundler's environment stripped, so a `bundle exec` test command resolves the
      # **target** project's Gemfile — not whatever bundle Rigor itself was launched under. Running Rigor via
      # `bundle exec` leaks `RUBYOPT=-rbundler/setup` + `GEM_HOME` / `BUNDLE_*` into a plain `system` subprocess,
      # which then resolves the target's Gemfile against Rigor's gems and fails — so a green suite looks red and
      # the run aborts. `with_unbundled_env` restores the pre-bundler env (a bare `env -u BUNDLE_GEMFILE` is not
      # enough — the `BUNDLER_ORIG_*` preservers defeat it). Found validating ADR-70 on real projects
      # (2026-06-17).
      def shell_run(command)
        run = -> { system(*command, out: File::NULL, err: File::NULL) }
        return run.call unless defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)

        Bundler.with_unbundled_env(&run)
      end
    end
  end
end
