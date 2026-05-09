# frozen_string_literal: true

require_relative "../../cache/descriptor"

module Rigor
  module Analysis
    module DependencySourceInference
      # Per-run collection of gem-source-inference state. Holds
      # the resolved gems the walker MAY visit (slice 2b) plus
      # the unresolvable entries the runner SHOULD surface as
      # `dynamic.dependency-source.gem-not-found` diagnostics.
      #
      # Slice 2a lands the data structure only; the dispatcher
      # tier consults {#contribution_for} but the lookup always
      # answers `nil` until slice 2b populates the method table
      # by walking the resolved gems' `roots:`.
      class Index
        attr_reader :resolved_gems, :unresolvable, :method_catalog, :budget_exceeded

        # @param method_catalog [Hash{[String, Symbol] => Symbol}]
        #   the flat `(class_name, method_name) → :instance | :singleton`
        #   table produced by {Walker.walk}, aggregated across
        #   every resolved gem in the run. The Index itself stays
        #   gem-agnostic — the per-gem attribution that slice 3's
        #   cache descriptor needs lives on `Resolved`, not here.
        # @param budget_exceeded [Array<String>] gem names whose
        #   {Walker} run hit the per-gem catalog cap (slice 4).
        #   The Runner consumes this list to emit one
        #   `dynamic.dependency-source.budget-exceeded` warning
        #   per gem.
        def initialize(resolved_gems: [], unresolvable: [], method_catalog: {}, budget_exceeded: [])
          @resolved_gems = resolved_gems.freeze
          @unresolvable = unresolvable.freeze
          @method_catalog = method_catalog.freeze
          @budget_exceeded = budget_exceeded.freeze
          freeze
        end

        # Looks up the recorded method kind for a
        # `(class_name, method_name)` pair. Returns `:instance`
        # / `:singleton` when the walker observed a definition
        # under one of the resolved gems' `roots:`, or `nil`
        # otherwise. Slice 2b-ii enriches this with the inferred
        # return type so the dispatcher tier can build a
        # `Type::Dynamic` directly from the lookup result.
        def contribution_for(class_name:, method_name:)
          @method_catalog[[class_name, method_name]]
        end

        def empty?
          @resolved_gems.empty?
        end

        # Builds a frozen `Cache::Descriptor` carrying one
        # `DependencyEntry` row per resolved gem in this run.
        # Cache producers that observe ADR-10 inference outputs
        # compose this descriptor with their own (RBS, plugin,
        # file-digest) descriptors so a `bundle update` on a
        # listed gem invalidates exactly that gem's slice while
        # leaving the rest of the cache hot.
        #
        # Unresolvable entries contribute nothing — there is no
        # version to key on, and the runner already surfaces them
        # as `dynamic.dependency-source.gem-not-found`
        # diagnostics. Resolved-but-disabled entries are also
        # absent: the {Builder} skips them before resolution, so
        # they never reach the index.
        def cache_descriptor
          dependencies = @resolved_gems.map do |resolved|
            Cache::Descriptor::DependencyEntry.new(
              gem_name: resolved.gem_name,
              gem_version: resolved.version,
              mode: resolved.mode
            )
          end
          Cache::Descriptor.new(dependencies: dependencies)
        end
      end

      # Frozen empty index — the runner uses this when
      # `Configuration#dependencies.source_inference` is empty
      # so the dispatcher tier holds a stable, non-nil
      # reference even on default configurations.
      Index::EMPTY = Index.new.freeze
    end
  end
end
