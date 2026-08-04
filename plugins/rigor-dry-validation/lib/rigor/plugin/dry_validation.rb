# frozen_string_literal: true

require "prism"

require "rigor/plugin"

require_relative "dry_validation/contract_scanner"
require_relative "dry_validation/params_shape"

module Rigor
  module Plugin
    # rigor-dry-validation — Tier A per
    # [ADR-12](../../../../../docs/adr/12-dry-rb-packaging.md) and the
    # slicing plan in
    # [docs/design/20260517-dry-validation-slicing.md](../../../../../docs/design/20260517-dry-validation-slicing.md).
    #
    # Slice 1 floor:
    #
    # - Walks the project for `class T < Dry::Validation::Contract` subclasses and publishes the
    #   resulting set of contract class FQNs as the `:dry_validation_contracts` ADR-9 cross-plugin fact.
    # - Ships an RBS overlay (`sig/dry_validation.rbs`) typing `Dry::Validation::Contract#call` (returns
    #   Result) and `Dry::Validation::Result#{success?, failure?, to_h}`. The manifest's
    #   `signature_paths: ["sig"]` auto-contributes the overlay (ADR-25) — no project-side wiring needed.
    #
    # Landed since (issue #137):
    #
    # - **Slice 2** — when `rigor-dry-schema` is loaded, a Contract's `params { ... }` block (the SAME
    #   dry-schema DSL a top-level `Dry::Schema.X { ... }` body uses) refines
    #   `NewUserContract.new.call(input).to_h` from the RBS overlay's generic `Hash[Symbol, untyped]` to
    #   the schema-typed `HashShape`. See {ContractScanner.scan_schema_blocks} + {ParamsShape}.
    # - **Slice 3** — `json { ... }` adapter parity with `params { ... }`. Same mechanism, same fact.
    #
    # Without `rigor-dry-schema` loaded, `result.to_h` still types per the RBS overlay's generic
    # `Hash[Symbol, untyped]` — this plugin ships no required/optional walker of its own; it delegates to
    # dry-schema's (see {ContractScanner}'s module doc for why that is a deliberate hard precondition, not
    # a degrade-gracefully fallback).
    #
    # The next ceiling item — per-Contract `rule(:key)` diagnostics — is issue #137's remaining checkbox.
    #
    # No ADR-3 amendment is needed for the validation surface itself; `Dry::Validation::Result` is a
    # generic class, not a sum type (the `success?` / `failure?` predicates narrow via existing bool flow
    # facts).
    class DryValidation < Rigor::Plugin::Base
      manifest(
        id: "dry-validation",
        version: "0.1.0",
        description: "Recognises `class T < Dry::Validation::Contract` subclasses, publishes the " \
                     "contract FQN set, and (with rigor-dry-schema loaded) refines each contract's " \
                     "`result.to_h` to its `params`/`json` schema shape.",
        produces: %i[dry_validation_contracts dry_validation_params],
        consumes: [{ plugin_id: "dry-types", name: :dry_type_aliases, optional: true }],
        # Auto-contribute the bundled RBS overlay (Contract#call -> Result, Result#success?/#to_h/...)
        # per ADR-25, so no project-side signature_paths wiring is needed.
        signature_paths: ["sig"]
      )

      # ADR-37 dynamic return — refines `NewUserContract.new.call(input).to_h` to the per-contract
      # `HashShape` when {#result_shape_for} finds one. Gated on the method name alone (mirrors
      # rigor-dry-schema's own `.to_h` rule): the RBS overlay types `Contract#call`'s return as the
      # generic `Result`, but that alone can't select a PER-CONTRACT shape, so the block does its own
      # syntactic chain match via {ParamsShape.contract_name} before touching the table. When
      # rigor-dry-schema isn't loaded, or the chain isn't a Contract call, this returns nil and the RBS
      # overlay's generic `Hash[Symbol, untyped]` stands.
      dynamic_return methods: [:to_h] do |call_node, _scope|
        result_shape_for(call_node)
      end

      def prepare(services)
        contracts = ContractScanner.scan(paths: scannable_paths(services))
        unless contracts.empty?
          services.fact_store.publish(
            plugin_id: manifest.id,
            name: :dry_validation_contracts,
            value: contracts
          )
        end

        type_aliases = services.fact_store.read(plugin_id: "dry-types", name: :dry_type_aliases) || {}
        params_table = ContractScanner.scan_schema_blocks(paths: scannable_paths(services), type_aliases: type_aliases)
        return if params_table.empty?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :dry_validation_params,
          value: params_table
        )
      end

      def init(_services)
        @scannable_paths = nil
        @params_shapes = {}
      end

      private

      # The HashShape for a `<Const>.new.call(...).to_h` chain, or nil when the chain isn't that shape,
      # names no contract in the table, or the contract's `params`/`json` shape declares no key.
      # `params` wins over `json` when (unusually) a Contract declares both — mirrors dry-schema's own
      # per-name memoisation, including nil, for the same reason: the miss is the common case.
      def result_shape_for(call_node)
        name = ParamsShape.contract_name(call_node)
        return nil if name.nil?

        shapes = (@params_shapes ||= {})
        return shapes[name] if shapes.key?(name)

        entry = read_fact(plugin_id: manifest.id, name: :dry_validation_params)&.[](name)
        row = entry && (entry[:params] || entry[:json])
        shapes[name] = row.nil? ? nil : ParamsShape.build(row)
      end

      def scannable_paths(services)
        @scannable_paths ||= services.configuration.paths.flat_map do |entry|
          if File.directory?(entry)
            Dir.glob(File.join(entry, "**", "*.rb"), sort: true)
          elsif File.file?(entry) && entry.end_with?(".rb")
            [entry]
          else
            []
          end
        end.uniq.freeze
      end
    end

    Rigor::Plugin.register(DryValidation)
  end
end
