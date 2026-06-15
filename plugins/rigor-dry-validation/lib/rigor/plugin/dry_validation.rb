# frozen_string_literal: true

require "prism"

require "rigor/plugin"

require_relative "dry_validation/contract_scanner"

module Rigor
  module Plugin
    # rigor-dry-validation — Tier A per
    # [ADR-12](../../../../../docs/adr/12-dry-rb-packaging.md) and the
    # slicing plan in
    # [docs/design/20260517-dry-validation-slicing.md](../../../../../docs/design/20260517-dry-validation-slicing.md).
    #
    # Slice 1 floor:
    #
    # - Walks the project for `class T < Dry::Validation::Contract`
    #   subclasses and publishes the resulting set of contract
    #   class FQNs as the `:dry_validation_contracts` ADR-9
    #   cross-plugin fact.
    # - Ships an RBS overlay (`sig/dry_validation.rbs`) typing
    #   `Dry::Validation::Contract#call` (returns Result) and
    #   `Dry::Validation::Result#{success?, failure?, to_h}`.
    #   The manifest's `signature_paths: ["sig"]` auto-contributes
    #   the overlay (ADR-25) — no project-side wiring needed.
    #
    # Slice 2 (deferred, per design note):
    #
    # - Integrate with `:dry_schema_table` (published by
    #   `rigor-dry-schema`) so the `params { ... }` block inside a
    #   Contract contributes a typed `result.to_h` shape per the
    #   schema. Until this lands, `result.to_h` types as
    #   `Hash[Symbol, untyped]` (the generic RBS overlay shape).
    #
    # Slice 3 (deferred): `json { ... }` adapter parity with
    # `params { ... }`. Same shape as slice 2.
    #
    # No ADR-3 amendment is needed for the validation surface
    # itself; `Dry::Validation::Result` is a generic class, not a
    # sum type (the `success?` / `failure?` predicates narrow via
    # existing bool flow facts).
    class DryValidation < Rigor::Plugin::Base
      manifest(
        id: "dry-validation",
        version: "0.1.0",
        description: "Recognises `class T < Dry::Validation::Contract` subclasses and " \
                     "publishes the contract FQN set.",
        produces: [:dry_validation_contracts],
        # Auto-contribute the bundled RBS overlay (Contract#call -> Result,
        # Result#success?/#to_h/...) per ADR-25, so no project-side
        # signature_paths wiring is needed.
        signature_paths: ["sig"]
      )

      def prepare(services)
        contracts = ContractScanner.scan(paths: scannable_paths(services))
        return if contracts.empty?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :dry_validation_contracts,
          value: contracts
        )
      end

      def init(_services)
        @scannable_paths = nil
      end

      private

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
