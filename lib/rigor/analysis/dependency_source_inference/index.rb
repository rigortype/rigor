# frozen_string_literal: true

require_relative "../../cache/descriptor"
require_relative "../../inference/scope_indexer"

module Rigor
  module Analysis
    module DependencySourceInference
      # Per-run collection of gem-source-inference state. Holds the resolved gems the walker visits plus the
      # unresolvable entries the runner surfaces as `dynamic.dependency-source.gem-not-found` diagnostics.
      # The method table is fully populated by {Walker} at build time; {#contribution_for} returns live
      # entries.
      class Index
        # Issue #1814 — what one walked gem's walk read: the classes and modules it names ({Walker::Outcome#modules})
        # and whether it read all of them ({Walker::Outcome#fully_read?}). Held beside {#refinements}.
        Reading = Data.define(:gem_name, :modules, :fully_read)

        attr_reader :resolved_gems, :unresolvable, :method_catalog, :budget_exceeded,
                    :class_to_gem, :budget_overrun_strategy, :gem_modes, :refinements, :readings

        # @param method_catalog — => Symbol}] the flat
        #   `(class_name, method_name) → :instance | :singleton` table produced by {Walker.walk}, aggregated
        #   across every resolved gem in the run. The Index itself stays gem-agnostic — the per-gem
        #   attribution that slice 3's cache descriptor needs lives on `Resolved`, not here.
        # @param budget_exceeded — gem names whose {Walker} run hit the per-gem catalog cap
        #   (slice 4). The Runner consumes this list to emit one `dynamic.dependency-source.budget-exceeded`
        #   warning per gem.
        # @param class_to_gem — reverse lookup `class_name → gem_name` (slice 5b). Built
        #   first-write-wins: when two opt-in gems re-open the same class, the first gem owns it. The
        #   dispatcher consults this map under the `:dependency_silence` budget overrun strategy so call
        #   sites on a budget-exceeded gem's classes degrade to `Dynamic[top]` instead of falling through to
        #   the user-class fallback.
        # @param gem_modes — per-gem mode table (`gem_name → :disabled | :when_missing |
        #   :full`). ADR-10 slice 5c consults this through {#mode_for} to identify call sites where
        #   gem-source and RBS both contribute under `mode: :full`. The map is keyed on `gem_name` (not
        #   class) because re-opened classes belong to the first gem they appeared in per `class_to_gem`;
        #   `mode_for(class_name)` chains the two lookups.
        # @param refinements — issue #1672: the opt-in gems' `refine X do … end` bodies, `{refined class =>
        #   {method => [refining modules]}}` ({Walker::Outcome#refinements}). The runner merges it into the
        #   project's `discovered_refinements` seed, so `using M` for a gem's `M` reaches the check rules.
        # @param readings — issue #1814: one {Reading} per walked entry, what its walk read. {#fully_read_module?}
        #   answers from it, and `InEffectRefinements.opaque_module?` asks that.
        def initialize( # rubocop:disable Metrics/ParameterLists
          resolved_gems: [], unresolvable: [], method_catalog: {},
          budget_exceeded: [], class_to_gem: {},
          budget_overrun_strategy: :walker_cap, gem_modes: {}, refinements: {}, readings: []
        )
          @resolved_gems = resolved_gems.freeze
          @unresolvable = unresolvable.freeze
          @method_catalog = normalize_catalog(method_catalog).freeze
          @budget_exceeded = budget_exceeded.freeze
          @class_to_gem = class_to_gem.freeze
          @budget_overrun_strategy = budget_overrun_strategy
          @gem_modes = gem_modes.freeze
          @refinements = Inference::ScopeIndexer.freeze_refinements(refinements)
          @readings = readings.freeze
          @fully_read_modules = fully_read_modules_of(readings).freeze
          freeze
        end

        # Accepts both the post-heuristic `CatalogEntry` shape (the Walker's current output) and the legacy
        # bare-Symbol `:instance` / `:singleton` shape (older tests + earlier in-tree callers). Symbol values
        # are wrapped into `CatalogEntry(kind: value, return_type: nil)` so the downstream dispatcher always
        # sees a single shape.
        def normalize_catalog(catalog)
          catalog.transform_values do |value|
            value.is_a?(Symbol) ? Walker::CatalogEntry.new(kind: value) : value
          end
        end
        private :normalize_catalog

        def fully_read_modules_of(readings)
          named = Set.new
          spoiled = Set.new
          readings.each do |reading|
            named.merge(reading.modules)
            spoiled.merge(reading.modules) unless reading.fully_read
          end
          named - spoiled
        end
        private :fully_read_modules_of

        # @return the gem that owns `class_name` (first-write-wins); `nil` when the class isn't
        #   in any opt-in gem's catalog.
        def gem_for(class_name)
          @class_to_gem[class_name]
        end

        # Issue #1814 — has every file that could refine `module_name` been read? True when a walked gem names it and
        # every walked gem that names it was read in full: a gem that was truncated, had an unreadable file or may mix a
        # module into a module could have refined it where the walk did not look. A module nothing walked names is not
        # fully read, however the RBS or the project describe it.
        def fully_read_module?(module_name)
          @fully_read_modules.include?(module_name)
        end

        # ADR-10 slice 5c — per-class mode lookup. Chains `class_to_gem` + `gem_modes`; returns `nil` when
        # the class isn't owned by any opt-in gem in this run.
        def mode_for(class_name)
          gem_name = @class_to_gem[class_name]
          return nil if gem_name.nil?

          @gem_modes[gem_name]
        end

        # ADR-10 slice 5c — true when the receiver class belongs to a gem the user opted into `mode: :full`
        # for. The dispatcher consults this AFTER an authoritative-source (RBS / plugin) dispatch resolves
        # so it can record the boundary-crossing for audit.
        def full_mode?(class_name)
          mode_for(class_name) == :full
        end

        # Looks up the recorded method kind for a `(class_name, method_name)` pair. Returns `:instance` /
        # `:singleton` when the walker observed a definition under one of the resolved gems' `roots:`, or
        # `nil` otherwise. Slice 2b-ii enriches this with the inferred return type so the dispatcher tier can
        # build a `Type::Dynamic` directly from the lookup result.
        def contribution_for(class_name:, method_name:)
          @method_catalog[[class_name, method_name]]
        end

        def empty?
          @resolved_gems.empty?
        end

        # Builds a frozen `Cache::Descriptor` carrying one `DependencyEntry` row per resolved gem in this
        # run. Cache producers that observe ADR-10 inference outputs compose this descriptor with their own
        # (RBS, plugin, file-digest) descriptors so a `bundle update` on a listed gem invalidates exactly
        # that gem's slice while leaving the rest of the cache hot.
        #
        # Unresolvable entries contribute nothing — there is no version to key on, and the runner already
        # surfaces them as `dynamic.dependency-source.gem-not-found` diagnostics. Resolved-but-disabled
        # entries are also absent: the {Builder} skips them before resolution, so they never reach the index.
        def cache_descriptor
          Cache::Descriptor.new(dependencies: @resolved_gems.map(&:dependency_entry))
        end
      end

      # Frozen empty index — the runner uses this when `Configuration#dependencies.source_inference` is
      # empty so the dispatcher tier holds a stable, non-nil reference even on default configurations.
      Index::EMPTY = Index.new.freeze
    end
  end
end
