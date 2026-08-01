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
    # without YJIT, or a non-MRI Ruby), every entry point is a no-op too.
    #
    # `fork` copies only the calling thread, so the {enable_after} sleeper dies
    # in every child of a fork pool — a worker would run its whole slice
    # interpreted while the parent JITs work it no longer does. {rearm_after_fork}
    # is the child-side entry point that repairs this, and it carries the
    # *remaining* deadline rather than restarting the window; see its own
    # comment for why that distinction is worth the bookkeeping.
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

        # Record when the window actually closes, so a child forked partway
        # through it can re-arm with what is LEFT ({rearm_after_fork}) instead
        # of restarting the wait. Monotonic, so a wall-clock adjustment mid-run
        # cannot move the deadline; and monotonic time survives `fork`, so the
        # value stays comparable in a child.
        #
        # Thread-safety: this is written on the arming thread before any `fork`
        # and read only in children *after* the fork, each of which sees a
        # private copy of the parent's memory. No reader and writer ever share a
        # process, so the plain attribute needs no lock.
        @deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds

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

      # Re-arms the deferred-YJIT deadline inside a freshly forked child,
      # carrying the *remaining* window rather than restarting it.
      #
      # `fork` copies only the calling thread, so the parent's {enable_after}
      # sleeper never fires in a child: without re-arming, a worker runs its
      # entire slice interpreted however long that takes, and a fork pool can be
      # slower than sequential (measured: `coverage --protection --mutation
      # lib/rigor/analysis` at 37s sequential against 67s at eight workers).
      # Re-arming with a *fresh full* deadline fixes that but overshoots the
      # other way — the parent has normally already burned part of the window
      # before it forks, so every child sits out the whole window again. That is
      # pure warm-up loss, and it is paid once per worker, so it grows with the
      # worker count exactly where a pool is supposed to pay off.
      #
      # The remaining window is what the amortization contract actually says:
      # the deadline exists to keep short *runs* off the JIT, and a child is a
      # continuation of the parent's run, not a new one. When the deadline has
      # already passed, the run has proven itself long — enable straight away.
      #
      # Re-arming goes through {enable_after}, so the child records the same
      # absolute deadline it inherited and a grandchild fork carries it too.
      #
      # @return [Thread, nil] the child's deadline thread; nil when YJIT was
      #   enabled immediately, and nil when the call is a no-op up front
      #   (unavailable / opted out / already enabled — a child forked after the
      #   parent enabled inherits the enabled state and has nothing to do).
      def rearm_after_fork
        return nil unless available?
        return nil if disabled?
        return nil if RubyVM::YJIT.enabled?

        # No recorded deadline means nothing in this process ever armed one — a
        # caller that forks without going through a CLI entry point, or a spec.
        # Degrade to a fresh full window, never to no YJIT at all.
        return enable_after(deadline_seconds) if @deadline_at.nil?

        remaining = @deadline_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return enable_after(remaining) if remaining.positive?

        enable_now
        nil
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
