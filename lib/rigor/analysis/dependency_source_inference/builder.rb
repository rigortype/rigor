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
      # {Walker.walk} under the configured `budget_per_gem` cap,
      # and aggregates the per-gem method catalogs into the
      # Index's flat `(class_name, method_name) → kind` table.
      #
      # Entries with `mode: :disabled` are skipped without
      # resolution attempts so users can "list and disable" a
      # gem in configuration without provoking a missing-gem
      # diagnostic.
      module Builder
        module_function

        # @param dependencies [Rigor::Configuration::Dependencies]
        # @return [Index]
        def build(dependencies) # rubocop:disable Metrics/MethodLength
          return Index::EMPTY if dependencies.empty?

          resolved = []
          unresolvable = []
          catalog = {}
          class_to_gem = {}
          budget_exceeded = []
          budget = dependencies.budget_per_gem

          dependencies.source_inference.each do |entry|
            next if entry.disabled?

            outcome = GemResolver.resolve(entry)
            case outcome
            when GemResolver::Resolved
              resolved << outcome
              walked = walker_outcome_for(outcome, budget)
              catalog.merge!(walked.catalog)
              record_class_to_gem(walked.catalog, outcome.gem_name, class_to_gem)
              budget_exceeded << outcome.gem_name if walked.truncated?
            when GemResolver::Unresolvable then unresolvable << outcome
            end
          end

          Index.new(
            resolved_gems: resolved, unresolvable: unresolvable,
            method_catalog: catalog, budget_exceeded: budget_exceeded,
            class_to_gem: class_to_gem,
            budget_overrun_strategy: dependencies.budget_overrun_strategy
          )
        end

        # ADR-10 5b — per-class reverse-lookup table (β budget
        # semantics). Records `class_name → gem_name` for every
        # class observed in the gem's catalog. First-write-wins:
        # if two opt-in gems re-open the same class, the first
        # gem to harvest the class owns it in the reverse index.
        # The dispatcher only consults this map when the
        # `budget_overrun_strategy` is `:dependency_silence`,
        # so the storage cost is never paid back unless the
        # user opts in.
        def record_class_to_gem(catalog, gem_name, class_to_gem)
          catalog.each_key do |(class_name, _method_name)|
            class_to_gem[class_name] ||= gem_name
          end
        end

        # Per-resolved-gem walk. Isolated so a single gem's
        # filesystem error / parse failure cannot abort the
        # build; the walker swallows its own per-file errors,
        # and a top-level raise here degrades the gem to "no
        # contributions" without touching the rest of the run.
        def walker_outcome_for(resolved, budget)
          Walker.walk(gem_dir: resolved.gem_dir, roots: resolved.roots, budget: budget)
        rescue StandardError
          Walker::Outcome.new(catalog: {}.freeze, truncated: false)
        end
      end
    end
  end
end
