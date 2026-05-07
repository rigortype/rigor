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

      # Dimension → Rigor type. Used by `flow_contribution_for`
      # to translate the {MethodTable} dispatch result back into
      # the carrier the analyzer threads through call sites.
      DIMENSION_NOMINALS = {
        distance: "Distance",
        time: "Time",
        speed: "Speed",
        acceleration: "Acceleration",
        float: "Float"
      }.freeze

      # Inverse map — Rigor type → dimension Symbol. Keyed on the
      # nominal class name; non-class carriers (Constant, IntegerRange)
      # fall through and the contribution declines.
      NOMINAL_DIMENSIONS = {
        "Distance" => :distance,
        "Time" => :time,
        "Speed" => :speed,
        "Acceleration" => :acceleration,
        "Float" => :float,
        "Integer" => :numeric,
        "Numeric" => :numeric
      }.freeze

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        Analyzer.new(path: path).analyze(root).diagnostics
      end

      # v0.1.2 — return-type contribution. The same {MethodTable}
      # the diagnostics path consults supplies the call-site
      # return type when both receiver and argument map cleanly
      # to a known dimension. Dimensional mismatches stay at the
      # RBS-level untyped return — surfacing the existing
      # `dimension-mismatch` / `in-method-mismatch` error
      # diagnostic without propagating `bot` downstream.
      def flow_contribution_for(call_node:, scope:)
        return nil unless call_node.is_a?(Prism::CallNode)
        return nil if call_node.receiver.nil?

        receiver_dim = dimension_for_type(scope.type_of(call_node.receiver))
        return nil if receiver_dim.nil?

        arg_dims = call_node.arguments&.arguments&.map { |arg| dimension_for_type(scope.type_of(arg)) } || []
        return nil if arg_dims.any?(&:nil?)

        result = MethodTable.dispatch(receiver: receiver_dim, method: call_node.name, args: arg_dims)
        return nil if result.nil? || result.error || result.dimension.nil?

        return_type = type_for_dimension(result.dimension)
        return nil if return_type.nil?

        Rigor::FlowContribution.new(
          return_type: return_type,
          provenance: Rigor::FlowContribution::Provenance.new(
            source_family: "plugin.#{manifest.id}",
            plugin_id: manifest.id,
            node: call_node,
            descriptor: nil
          )
        )
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
