# frozen_string_literal: true

require "rigor/plugin"

require_relative "units/method_table"
require_relative "units/analyzer"

module Rigor
  module Plugin
    # Example plugin: types a units-of-measure DSL that extends `Numeric` with constructor methods (`100.kilometers`,
    # `2.hours`) and propagates dimensional types through arithmetic, chained constructors (`60.kilometers.per_hour`),
    # and conversion queries (`speed.in_kilometers_per_hour`).
    #
    # The plugin walks the file's AST ({Analyzer}), maintains a local-variable binding map (`distance: :distance`,
    # `speed: :speed`, …), and emits one diagnostic per recognised event:
    #
    # | Event                                 | Severity | Rule |
    # | ---                                   | ---      | --- |
    # | local assignment with inferred dim    | `:info`  | `inferred-binding` |
    # | terminal `.in_<unit>` query           | `:info`  | `in-method-result` |
    # | dimensional mismatch in `+`/`-`/`*`/`/`/comparison | `:error` | `dimension-mismatch` |
    # | wrong `.in_<unit>` for the dimension  | `:error` | `in-method-mismatch` |
    #
    # In addition to diagnostics the plugin contributes return types for every recognised call site via
    # {.dynamic_return}, so the engine's flow analysis threads the dimensional type (`Distance` / `Speed` / …) through
    # assignments and into downstream calls instead of seeing the DSL's untyped RBS boundary.
    #
    # ## Why the parallel binding map is NOT redundant
    #
    # It is tempting to delete {Analyzer}'s `@bindings` map and have the diagnostics side read dimensions straight from
    # `Scope#type_of`, the way `rigor-pattern` reads literal-string facts back from the engine. That does not work here,
    # and the asymmetry is worth understanding:
    #
    # - The `Scope` handed to `#diagnostics_for_file` / a `node_rule`
    #   is the **seed entry scope** (`seed_project_scope(Scope.empty)`).
    #   `Scope#type_of` re-evaluates a node on demand, so it folds a
    #   *self-contained* expression — `scope.type_of(100.kilometers)`
    #   re-runs the {.dynamic_return} block and yields `Distance`. But
    #   it carries **no flow-accumulated local bindings**: for
    #   `speed = distance / time`, `scope.type_of(distance)` is
    #   `untyped`, because the entry scope never bound `distance` — the
    #   binding only ever existed in the mid-inference flow scope.
    # - The `Scope` handed to {.dynamic_return} IS that flow scope, at
    #   the call site, so there `scope.type_of(distance)` is `Distance`.
    #   The engine threads dimensions correctly (a downstream
    #   `speed.upcase` really does trip `call.undefined-method` on
    #   `Speed`), but the diagnostics API cannot see that thread.
    #
    # So the two halves read dimensions from different sources of necessity: {.dynamic_return} from the flow
    # `Scope#type_of`, and {Analyzer} from its own single-pass binding map — the only way to follow a dimension across
    # statements on the diagnostics side. A plugin that needs a value literally at one call site (rigor-pattern) reaches
    # for the engine; a plugin that needs cross-statement local flow on the diagnostics side (this one) still tracks it.
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

      # Dimension → Rigor type. Used by the {.dynamic_return} rule to translate the {MethodTable} dispatch result back
      # into the carrier the engine threads through call sites.
      DIMENSION_NOMINALS = {
        distance: "Distance",
        time: "Time",
        speed: "Speed",
        acceleration: "Acceleration",
        float: "Float"
      }.freeze

      # Inverse map — Rigor type → dimension Symbol. Keyed on the nominal class name; non-class carriers (Constant,
      # IntegerRange) fall through and the contribution declines.
      NOMINAL_DIMENSIONS = {
        "Distance" => :distance,
        "Time" => :time,
        "Speed" => :speed,
        "Acceleration" => :acceleration,
        "Float" => :float,
        "Integer" => :numeric,
        "Numeric" => :numeric
      }.freeze

      # Union of every method name {MethodTable.dispatch} can recognise:
      # numeric unit constructors, chained speed/acceleration constructors, arithmetic and comparison operators, and
      # every `.in_<unit>` query across all receiver dimensions. Used as the `methods:` gate for the {.dynamic_return}
      # declaration below so the engine skips this block for every call to an unrelated method.
      RECOGNISED_METHODS = (
        MethodTable::DISTANCE_UNIT_METHODS +
        MethodTable::TIME_UNIT_METHODS +
        MethodTable::DISTANCE_PER_TIME +
        MethodTable::DISTANCE_PER_TIME_SQUARED +
        %i[+ - * /] +
        MethodTable::COMPARISON_OPS +
        MethodTable::IN_METHODS.values.flatten
      ).uniq.freeze

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        Analyzer.new(path: path).analyze(root).diagnostics
      end

      # v0.1.2 — return-type contribution via the {.dynamic_return} DSL. The same {MethodTable} the diagnostics path
      # consults supplies the call-site return type when both receiver and argument map cleanly to a known dimension.
      # Dimensional mismatches stay at the RBS-level untyped return — surfacing the existing `dimension-mismatch` /
      # `in-method-mismatch` error diagnostic without propagating `bot` downstream. The engine wraps a non-nil return in
      # a `FlowContribution`; the block returns a bare `Rigor::Type`.
      dynamic_return methods: RECOGNISED_METHODS do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil if call_node.receiver.nil?

        receiver_dim = dimension_for_type(scope.type_of(call_node.receiver))
        next nil if receiver_dim.nil?

        arg_dims = call_node.arguments&.arguments&.map { |arg| dimension_for_type(scope.type_of(arg)) } || []
        next nil if arg_dims.any?(&:nil?)

        result = MethodTable.dispatch(receiver: receiver_dim, method: call_node.name, args: arg_dims)
        next nil if result.nil? || result.error || result.dimension.nil?

        type_for_dimension(result.dimension)
      end

      private

      def dimension_for_type(type)
        case type
        when Rigor::Type::Nominal then NOMINAL_DIMENSIONS[type.class_name]
        when Rigor::Type::Constant
          case type.value
          when Integer, Float then :numeric
          when true, false then :bool
          when ::String then :string
          end
        when Rigor::Type::IntegerRange then :numeric
        end
      end

      def type_for_dimension(dimension)
        case dimension
        when :bool
          Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.constant_of(true),
            Rigor::Type::Combinator.constant_of(false)
          )
        else
          class_name = DIMENSION_NOMINALS[dimension]
          Rigor::Type::Combinator.nominal_of(class_name) if class_name
        end
      end
    end

    Rigor::Plugin.register(Units)
  end
end
