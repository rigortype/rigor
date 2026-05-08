# frozen_string_literal: true

require_relative "gem_resolver"
require_relative "index"

module Rigor
  module Analysis
    module DependencySourceInference
      # Folds a `Configuration::Dependencies` value into a
      # frozen {Index}. Resolves each non-disabled entry through
      # {GemResolver} and partitions the outcomes; entries with
      # `mode: :disabled` are skipped without an attempt
      # (allowing users to "list and disable" a gem in
      # configuration without provoking a missing-gem
      # diagnostic).
      module Builder
        module_function

        # @param dependencies [Rigor::Configuration::Dependencies]
        # @return [Index]
        def build(dependencies)
          return Index::EMPTY if dependencies.empty?

          resolved = []
          unresolvable = []

          dependencies.source_inference.each do |entry|
            next if entry.disabled?

            outcome = GemResolver.resolve(entry)
            case outcome
            when GemResolver::Resolved then resolved << outcome
            when GemResolver::Unresolvable then unresolvable << outcome
            end
          end

          Index.new(resolved_gems: resolved, unresolvable: unresolvable)
        end
      end
    end
  end
end
