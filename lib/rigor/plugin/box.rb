# frozen_string_literal: true

module Rigor
  module Plugin
    # ADR-39 slice 5 — the isolation boundary for target-library invocation. When Rigor is launched with
    # `RUBY_BOX=1` (opt-in; the launcher re-execs only when a project opts in), a target library is loaded and
    # called inside a `Ruby::Box` so its **core-class monkey-patches and gem version cannot contaminate Rigor's
    # main space**. `Ruby::Box` is not a security sandbox (the gem's code still runs in-process) — it is the
    # *contamination* boundary the rule needs, which is sufficient because the rule only ever invokes a
    # declared, trusted, pure target library.
    #
    # **Disabled by default.** {enabled?} is false unless the experimental `Ruby::Box` feature is active, so
    # every consumer keeps a non-box path and the default behaviour (loading the trusted library into the main
    # space, per slices 2/4) is unchanged. The box only ever holds the trusted, project-agnostic target
    # libraries (inflection rules, the Rack status table); per-project / exact-version boxes are a later slice.
    module Box
      module_function

      # True only when the experimental `Ruby::Box` feature is present and active (the process was started with
      # `RUBY_BOX=1`). Any error answers false so a consumer silently keeps its non-box path.
      def enabled?
        defined?(::Ruby::Box) && ::Ruby::Box.respond_to?(:enabled?) && ::Ruby::Box.enabled?
      rescue StandardError
        false
      end

      # The process-shared box for trusted, project-agnostic target libraries. Built lazily on first use.
      def shared
        @shared ||= ::Ruby::Box.new
      end

      # Requires `feature` into the shared box exactly once. Returns true when the feature is available in the
      # box, false when it could not be loaded (the caller then declines — never falls back to loading into the
      # main space, which would defeat the boundary).
      def require_feature(feature)
        @required ||= {}
        return @required[feature] if @required.key?(feature)

        shared.require(feature)
        @required[feature] = true
      rescue StandardError
        @required[feature] = false
      end

      # Evaluates `code` inside the shared box and returns the result across the box boundary. The caller MUST
      # build `code` safely — interpolate value arguments through `String#inspect` (which round-trips as a safe
      # Ruby literal) and only ever interpolate method names from a fixed allow-list, never free user input.
      def eval(code)
        shared.eval(code)
      end
    end
  end
end
