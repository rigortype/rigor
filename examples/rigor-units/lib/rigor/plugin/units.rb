# frozen_string_literal: true

require "rigor/plugin"

require_relative "units/method_table"
require_relative "units/analyzer"

module Rigor
  module Plugin
    # Example plugin: types a units-of-measure DSL that extends
    # `Numeric` with constructor methods (`100.kilometers`,
    # `2.hours`) and propagates dimensional types through
    # arithmetic, chained constructors (`60.kilometers.per_hour`),
    # and conversion queries (`speed.in_kilometers_per_hour`).
    #
    # The plugin walks the file's AST, maintains a local-variable
    # binding map (`distance: :distance`, `speed: :speed`, …),
    # and emits one diagnostic per recognised event:
    #
    # | Event                                 | Severity | Rule |
    # | ---                                   | ---      | --- |
    # | local assignment with inferred dim    | `:info`  | `inferred-binding` |
    # | terminal `.in_<unit>` query           | `:info`  | `in-method-result` |
    # | dimensional mismatch in `+`/`-`/`*`/`/`/comparison | `:error` | `dimension-mismatch` |
    # | wrong `.in_<unit>` for the dimension  | `:error` | `in-method-mismatch` |
    #
    # The plugin only emits diagnostics — same scope-note as
    # `examples/rigor-lisp-eval/`. Once Rigor's plugin contract
    # grows a return-type contribution surface, the same
    # {Analyzer} body moves from emitting diagnostics to
    # supplying `FlowContribution` bundles for each call site,
    # and the demo's `sig/units.rbs` can drop its `untyped`
    # boundaries.
    #
    # Usage in `.rigor.yml`:
    #
    #   plugins:
    #     - rigor-units
    class Units < Rigor::Plugin::Base
      manifest(
        id: "units",
        version: "0.1.0",
        description: "Types a units-of-measure DSL (Distance / Time / Speed / Acceleration)."
      )

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        Analyzer.new(path: path).analyze(root).diagnostics
      end
    end

    Rigor::Plugin.register(Units)
  end
end
