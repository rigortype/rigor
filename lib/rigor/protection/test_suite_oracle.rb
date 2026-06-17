# frozen_string_literal: true

module Rigor
  module Protection
    # ADR-70 — the **test-suite** kill oracle, the dynamic sibling of
    # {DiagnosticOracle} on the ADR-69 seam. A mutant is killed iff applying its
    # bytes to the file under test turns the project's test suite **red**. This is
    # the dynamic half of the fused static∪dynamic protection map: a `Dynamic`
    # site Rigor cannot bite (a type survivor) may still be fully guarded by a
    # test.
    #
    # The suite command is the **runner hook** (`--test-command`, e.g.
    # `bundle exec rake`). The runner is injectable so the decision logic is
    # unit-testable without shelling out; the default shells out and reads the
    # process exit status (0 = green / passed).
    #
    # I/O policy: {#killed?} writes the mutant to disk, runs the suite, and
    # **always restores** the original bytes in an `ensure` — a normal exception
    # never leaves a mutant on disk. (A hard interrupt mid-suite is the standard
    # mutation-testing hazard the `ensure` cannot cover; callers running this in
    # CI accept that, as `mutant` / Stryker do.)
    class TestSuiteOracle
      # @param command [Array<String>] the test command (the runner hook)
      # @param runner [#call, nil] `runner.call(command) -> true iff the suite
      #   passed`. Defaults to shelling out via `system`.
      def initialize(command:, runner: nil)
        @command = command
        @runner = runner || method(:shell_run)
      end

      # The baseline: the suite must pass on clean code, else "a mutant survived"
      # is meaningless (every mutant would look killed, or none would). Run once
      # before measuring.
      def green?
        @runner.call(@command)
      end

      # Killed iff the mutant turns the suite red. Restores `original` afterward.
      # @param path [String] the file to (temporarily) overwrite with the mutant
      # @param original [String] the clean bytes to restore
      # @param mutant_source [String] the mutated bytes to test against
      def killed?(path:, original:, mutant_source:)
        File.write(path, mutant_source)
        !@runner.call(@command)
      ensure
        File.write(path, original)
      end

      private

      def shell_run(command)
        system(*command, out: File::NULL, err: File::NULL)
      end
    end
  end
end
