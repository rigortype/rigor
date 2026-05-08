# frozen_string_literal: true

require_relative "gem_resolver"
require_relative "index"
require_relative "walker"

module Rigor
  module Analysis
    module DependencySourceInference
      # Folds a `Configuration::Dependencies` value into a
      # frozen {Index}. Resolves each non-disabled entry through
      # {GemResolver}, walks each resolved gem's `roots:` via
      # {Walker.walk}, and aggregates the per-gem method
      # catalogs into the Index's flat `(class_name,
      # method_name) → kind` table.
      #
      # Entries with `mode: :disabled` are skipped without
      # resolution attempts so users can "list and disable" a
      # gem in configuration without provoking a missing-gem
      # diagnostic.
      module Builder
        module_function

        # @param dependencies [Rigor::Configuration::Dependencies]
        # @return [Index]
        def build(dependencies)
          return Index::EMPTY if dependencies.empty?

          resolved = []
          unresolvable = []
          catalog = {}

          dependencies.source_inference.each do |entry|
            next if entry.disabled?

            outcome = GemResolver.resolve(entry)
            case outcome
            when GemResolver::Resolved
              resolved << outcome
              catalog.merge!(walker_catalog_for(outcome))
            when GemResolver::Unresolvable then unresolvable << outcome
            end
          end

          Index.new(resolved_gems: resolved, unresolvable: unresolvable, method_catalog: catalog)
        end

        # Per-resolved-gem walk. Isolated so a single gem's
        # filesystem error / parse failure cannot abort the
        # build; the walker swallows its own per-file errors,
        # and a top-level raise here degrades the gem to "no
        # contributions" without touching the rest of the run.
        def walker_catalog_for(resolved)
          Walker.walk(gem_dir: resolved.gem_dir, roots: resolved.roots)
        rescue StandardError
          {}
        end
      end
    end
  end
end
