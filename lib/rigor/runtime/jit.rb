# frozen_string_literal: true

module Rigor
  # Process-level runtime concerns that sit beside the analyzer rather than
  # inside it. Currently just deferred YJIT enablement.
  module Runtime
    # Deferred YJIT enablement for the long-running analysis commands.
    #
    # Ruby 3.3+ ships YJIT but leaves it off unless the process opts in
    # (`--yjit`, `RUBY_YJIT_ENABLE=1`, or `RubyVM::YJIT.enable`). Enabling it
    # unconditionally at boot is a net LOSS on short `rigor check` / `coverage`
    # runs: the JIT compile cost is paid up front, but a run that finishes in a
    # couple of seconds ends before it amortizes. Measured cold A/B (2026-07-13,
    # Ruby 4.0.5): mastodon `app/models` 4.0s -> 5.0s (0.80x), kramdown `lib`
    # 1.7s -> 2.55s (0.66x), dependabot 1.6s -> 2.34s (0.68x). Long runs win big
    # in the same measurement: mastodon `app`+`lib` 25.2s -> 14.9s (1.69x),
    # redmine `app/models` 8.6s -> 5.5s (1.56x). Allocations and diagnostics are
    # byte-identical under YJIT — the tradeoff is purely wall-time.
    #
    # The resolution is to enable YJIT only once a run has proven long enough to
    # amortize the compile cost. {enable_after} spawns one daemon thread that
    # sleeps the deadline then enables: a run that finishes before the deadline
    # never pays JIT compile (the sub-deadline penalty zone is avoided by
    # construction), while a long run enables mid-flight and JITs the remaining
    # — dominant — work. Long-lived servers (`rigor lsp` / `rigor mcp`) instead
    # enable at boot via {enable_now}, since they always run long.
    #
    # Opt-out: `RIGOR_DISABLE_YJIT=1` makes every entry point a no-op (the pin
    # the byte-identical-diagnostics gate uses). If YJIT is already enabled (the
    # user passed `--yjit` / `RUBY_YJIT_ENABLE=1`) or is unavailable (a build
    # without YJIT, or a non-MRI Ruby), both entry points are no-ops too.
    module Jit
      # Opt-out switch: `RIGOR_DISABLE_YJIT=1` disables both entry points.
      DISABLE_ENV = "RIGOR_DISABLE_YJIT"

      # Advanced / calibration override of the {enable_after} deadline, in
      # float seconds. Unset (or unparseable / negative) falls back to
      # {DEFAULT_DEADLINE_SECONDS}. Exposed so the deadline can be swept during
      # calibration and tuned per-project without an engine change.
      DEADLINE_ENV = "RIGOR_YJIT_DEADLINE"

      # The amortization deadline for {enable_after}, in seconds.
      #
      # Calibrated by interleaved cold A/B measurement on 2026-07-13 (Ruby
      # 4.0.5, arm64-darwin25). Enabling YJIT mid-run costs a ~1s compile burst,
      # so a run whose length is only ~0-1s longer than the deadline pays the
      # burst without time to amortize and LOSES (measured: `app/models` at a
      # 3.0s deadline regressed 4.14s -> 4.68s). The short-run cases cluster at
      # <=1.7s (kramdown / dependabot) and ~4.0-4.9s (mastodon `app/models` ~4.1s,
      # mail ~4.9s), with the next case at redmine ~7s. 5.0s parks that danger
      # zone in the empty 5-6s gap: every case <=4.9s finishes before the
      # deadline fires (guaranteed no-YJIT parity — the sleeping thread is killed
      # at exit), while runs long enough to pay off (>=~15s: gitlab, mastodon
      # `app`+`lib`) enable mid-flight and JIT their dominant tail — the mastodon
      # `app`+`lib` win is preserved ~100% (25.4s -> 15.1s, vs 15.1s always-on).
      DEFAULT_DEADLINE_SECONDS = 5.0

      module_function

      # Enables YJIT now, unless opted out, already enabled, or unavailable.
      #
      # An imperative command, not a query — the boolean reports whether this
      # call is what enabled YJIT (so the `?`-suffix predicate convention does
      # not apply; hence the Naming/PredicateMethod exemption).
      #
      # @return [Boolean] true if this call enabled YJIT; false if it was a
      #   no-op (unavailable / opted out / already enabled).
      def enable_now # rubocop:disable Naming/PredicateMethod
        return false unless available?
        return false if disabled?
        return false if RubyVM::YJIT.enabled?

        RubyVM::YJIT.enable
        true
      end

      # Spawns one background thread that sleeps `seconds` then calls
      # {enable_now}. The thread is a daemon in effect — Ruby kills all live
      # threads when the main thread exits — so a run that finishes before the
      # deadline simply never enables YJIT, which is the point.
      #
      # Returns nil (and spawns no thread) when the feature is already a no-op
      # up front (unavailable / opted out / already enabled), so callers never
      # pay for a thread that could only no-op.
      #
      # @param seconds [Numeric] the amortization deadline.
      # @return [Thread, nil] the deadline thread, or nil when no-op up front.
      def enable_after(seconds)
        return nil unless available?
        return nil if disabled?
        return nil if RubyVM::YJIT.enabled?

        thread = Thread.new do
          sleep(seconds)
          enable_now
        end
        # A background perf optimization must never spill a backtrace onto the
        # run's stderr; on any unexpected failure, stay silent and leave YJIT
        # off. The deadline sleep gives ample time to set this before the body
        # could raise.
        thread.report_on_exception = false
        thread
      end

      # The resolved {enable_after} deadline: {DEADLINE_ENV} when it parses to a
      # non-negative float, else {DEFAULT_DEADLINE_SECONDS}.
      #
      # @return [Numeric]
      def deadline_seconds
        raw = ENV.fetch(DEADLINE_ENV, nil)
        return DEFAULT_DEADLINE_SECONDS if raw.nil? || raw.empty?

        value = Float(raw, exception: false)
        value && value >= 0 ? value : DEFAULT_DEADLINE_SECONDS
      end

      # @return [Boolean] whether this Ruby exposes `RubyVM::YJIT.enable`.
      def available?
        defined?(RubyVM::YJIT.enable) ? true : false
      end

      # @return [Boolean] whether the opt-out env switch is set.
      def disabled?
        ENV[DISABLE_ENV] == "1"
      end
    end
  end
end
