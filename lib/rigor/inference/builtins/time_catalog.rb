# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Time` catalog. Singleton — load once, consult during dispatch.
      #
      # Time is a pure-C built-in: the Init block in
      # `references/ruby/time.c` registers the bulk of the surface,
      # and the Ruby-side prelude `references/ruby/timev.rb`
      # contributes the class-side constructors (`Time.now`,
      # `Time.at`, `Time.new`) through Primitive cexpr stubs.
      #
      # Time receivers are not lifted to a `Constant` carrier today
      # (there is no `Time` literal node — the closest is
      # `Time.now` / `Time.new(...)`, which produce `Nominal[Time]`).
      # The catalog wiring therefore mostly governs:
      #
      # 1. The size-projection-equivalent reader surface (`#year`,
      #    `#month`, `#hour`, `#sec`, `#wday`, …) — RBS-declared
      #    `Integer` is preserved through dispatch.
      # 2. The blocklist below, which keeps the indirect-mutator
      #    methods that the C-body classifier mis-flagged as
      #    `:leaf` from ever folding through a hypothetical future
      #    `Constant<Time>` carrier.
      #
      # The blocklist captures the false-positive `:leaf` entries
      # whose helper functions the regex classifier did not
      # recognise as mutators.
      TIME_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/time.yml",
          __dir__
        ),
        mutating_selectors: {
          "Time" => Set[
            # `time_init_copy` writes the `timew` and `vtm` slots on
            # the receiver via `time_set_timew` / `time_set_vtm`.
            # Classed `:leaf` because those setters are not in the
            # mutator regex's helper list. Blocked for symmetry with
            # String / Array / Range / Set initialize_copy entries.
            :initialize_copy,
            # `time_localtime_m` -> `time_localtime` calls
            # `time_modify(time)` to mark the receiver mutable
            # before rewriting its `vtm` cache and `tzmode`. The
            # docstring is explicit ("converts time to local time
            # in place"). The C-body classifier mis-flagged it as
            # `:leaf` because `time_modify` is not in its mutator
            # regex.
            :localtime,
            # `time_gmtime` (registered as both `gmtime` and `utc`
            # against `rb_cTime`) follows the same in-place pattern
            # as `time_localtime`: `time_modify(time)` then a
            # `time_set_vtm` write and `TZMODE_SET_UTC`. Both
            # selectors share the cfunc, so both must be blocked.
            :gmtime, :utc
          ]
        }
      )
    end
  end
end
