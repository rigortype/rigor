# frozen_string_literal: true

module Rigor
  class Configuration
    # Parsed `dependencies:` section of `.rigor.yml`. Per
    # [ADR-10](../../../docs/adr/10-dependency-source-inference.md),
    # the only nested key today is `source_inference:`, listing
    # gems whose Ruby implementation Rigor MAY walk during
    # inference instead of degrading to `Dynamic[top]` at the
    # dependency boundary.
    #
    # Slice 1 lands the parser only — `Configuration#dependencies`
    # is read, but no analyzer machinery consumes it yet. Slice 2
    # wires `Analysis::DependencySourceInference` against this
    # value object.
    class Dependencies # rubocop:disable Metrics/ClassLength
      # Walking modes per
      # [ADR-10 § "Decision"](../../../docs/adr/10-dependency-source-inference.md#decision).
      VALID_MODES = %i[disabled when_missing full].freeze

      # Default `roots:` for an entry that does not supply one.
      # The hard-excluded directories (`spec/` / `test/` / `bin/`
      # / C extensions) are enforced by the walker, not the
      # parser — see ADR-10 § "Hard exclusions".
      DEFAULT_ROOTS = %w[lib].freeze

      # Default per-gem catalog cap. ADR-10 slice 4 picks
      # 5000 method definitions: it covers Rack (~1500),
      # Faraday (~500), Sidekiq (~800) and other realistic
      # opt-in targets, while still surfacing a diagnostic for
      # ActiveSupport-class libraries (~10 000+ methods) where
      # the user should ship RBS or de-list the gem instead.
      DEFAULT_BUDGET_PER_GEM = 5000

      # Range bounds per ADR-10 § "Budget interaction"
      # ("range 0.25× – 4×"). Configured against the default,
      # this lands at 1250 – 20 000.
      MIN_BUDGET_PER_GEM = (DEFAULT_BUDGET_PER_GEM * 0.25).to_i
      MAX_BUDGET_PER_GEM = (DEFAULT_BUDGET_PER_GEM * 4).to_i

      # ADR-10 5b — budget-overrun strategy enum.
      #
      # - `:walker_cap` (default): the (α) semantics. The
      #   walker stops harvesting at the cap; methods past the
      #   cap fall through to the existing user-class fallback
      #   path. Existing v0.1.3 behaviour.
      # - `:dependency_silence`: the (β) semantics. Same
      #   walker behaviour, but the dispatcher additionally
      #   consults `Index#class_to_gem` after a catalog miss.
      #   When the receiver's class belongs to a budget-
      #   exceeded gem, the call resolves to `Dynamic[top]`
      #   rather than falling through to user-class fallback.
      #   This silences `call.undefined-method` for unrecorded
      #   methods at the cost of weaker static checking on
      #   that gem's surface.
      VALID_BUDGET_OVERRUN_STRATEGIES = %i[walker_cap dependency_silence].freeze
      DEFAULT_BUDGET_OVERRUN_STRATEGY = :walker_cap

      # Frozen value object describing a single per-gem opt-in.
      # `gem:` is the gem name (matched against the bundle at
      # walk time); `mode:` is one of {VALID_MODES}; `roots:` is
      # the list of subdirectories within the gem's installation
      # directory to walk (defaults to `["lib"]`).
      class Entry < Data.define(:gem, :mode, :roots)
        def disabled? = mode == :disabled
        def when_missing? = mode == :when_missing
        def full? = mode == :full
      end

      attr_reader :source_inference, :budget_per_gem, :budget_overrun_strategy, :warnings

      # Parse the YAML-shaped `dependencies:` value into a
      # frozen {Dependencies}. Accepts `nil` / `{}` / a Hash with
      # `source_inference:` and / or `budget_per_gem:` /
      # `budget_overrun_strategy:` present.
      def self.from_h(data)
        return new([]) if data.nil?
        raise ArgumentError, "dependencies: must be a Hash, got #{data.inspect}" unless data.is_a?(Hash)

        raw_entries = Array(data["source_inference"]).map { |raw| coerce_entry(raw) }
        entries, warnings = dedupe_entries(raw_entries)
        budget = coerce_budget_per_gem(data.fetch("budget_per_gem", DEFAULT_BUDGET_PER_GEM))
        strategy = coerce_budget_overrun_strategy(
          data.fetch("budget_overrun_strategy", DEFAULT_BUDGET_OVERRUN_STRATEGY)
        )
        new(entries, budget, warnings, strategy)
      end

      def initialize(source_inference, budget_per_gem = DEFAULT_BUDGET_PER_GEM,
                     warnings = [], budget_overrun_strategy = DEFAULT_BUDGET_OVERRUN_STRATEGY)
        @source_inference = source_inference.freeze
        @budget_per_gem = budget_per_gem
        @warnings = warnings.freeze
        @budget_overrun_strategy = budget_overrun_strategy
        freeze
      end

      def to_h
        {
          "source_inference" => @source_inference.map do |entry|
            {
              "gem" => entry.gem,
              "mode" => entry.mode.to_s,
              "roots" => entry.roots
            }
          end,
          "budget_per_gem" => @budget_per_gem,
          "budget_overrun_strategy" => @budget_overrun_strategy.to_s
        }
      end

      def empty? = @source_inference.empty?

      class << self
        # ADR-10 § "config-conflict diagnostic" — merges a
        # potentially-duplicated entry list (the `includes:`
        # chain produces concatenated arrays via
        # `Configuration.deep_merge`'s special-case for
        # `dependencies.source_inference`) into a single
        # canonical entry per gem name. The merge rules:
        #
        # - Same gem, same all fields → idempotent collapse
        #   (no warning).
        # - Same gem, different `mode:` → keep the LAST entry
        #   (matches existing right-wins semantics elsewhere)
        #   AND emit a `:warning` so the user knows their
        #   `includes:` chain is ambiguous.
        # - Same gem, different `roots:` → union the roots
        #   silently (no warning). The walker is happy to
        #   visit the union.
        #
        # Returns `[entries, warnings]` so the caller can
        # plumb the warning list through to the Runner for
        # diagnostic emission.
        def dedupe_entries(entries)
          warnings = []
          by_gem = {}
          entries.each do |entry|
            existing = by_gem[entry.gem]
            by_gem[entry.gem] = if existing.nil?
                                  entry
                                else
                                  merge_entry_pair(existing, entry, warnings)
                                end
          end
          [by_gem.values, warnings]
        end

        def merge_entry_pair(existing, incoming, warnings)
          if existing.mode != incoming.mode
            warnings << "dependencies.source_inference[].gem #{incoming.gem.inspect} declared with " \
                        "conflicting modes (#{existing.mode.inspect} vs #{incoming.mode.inspect}); " \
                        "the later (#{incoming.mode.inspect}) wins."
          end
          merged_roots = (existing.roots + incoming.roots).uniq.freeze
          Entry.new(gem: incoming.gem, mode: incoming.mode, roots: merged_roots)
        end

        private

        def coerce_entry(raw)
          unless raw.is_a?(Hash)
            raise ArgumentError,
                  "dependencies.source_inference[] entry must be a Hash, got #{raw.inspect}"
          end

          Entry.new(
            gem: coerce_gem(raw["gem"]),
            mode: coerce_mode(raw["mode"]),
            roots: coerce_roots(raw)
          )
        end

        def coerce_gem(value)
          unless value.is_a?(String) && !value.empty?
            raise ArgumentError,
                  "dependencies.source_inference[].gem must be a non-empty String, got #{value.inspect}"
          end

          value.dup.freeze
        end

        def coerce_mode(value)
          mode = (value || "when_missing").to_sym
          return mode if VALID_MODES.include?(mode)

          raise ArgumentError,
                "dependencies.source_inference[].mode must be one of " \
                "#{VALID_MODES.inspect}, got #{value.inspect}"
        end

        def coerce_roots(raw)
          roots = Array(raw.fetch("roots", DEFAULT_ROOTS)).map(&:to_s).freeze
          return roots unless roots.empty?

          raise ArgumentError,
                "dependencies.source_inference[].roots must not be empty when supplied " \
                "(omit the key to fall back to the default #{DEFAULT_ROOTS.inspect})"
        end

        def coerce_budget_overrun_strategy(value)
          symbol = value.to_sym
          return symbol if VALID_BUDGET_OVERRUN_STRATEGIES.include?(symbol)

          raise ArgumentError,
                "dependencies.budget_overrun_strategy must be one of " \
                "#{VALID_BUDGET_OVERRUN_STRATEGIES.inspect}, got #{value.inspect}"
        end

        # ADR-10 slice 4. Per-gem catalog cap is mandatory
        # (the parser supplies the default before this is
        # called, so `nil` only reaches here on an explicit
        # `budget_per_gem: ~`). Range bounds match
        # MIN_BUDGET_PER_GEM .. MAX_BUDGET_PER_GEM
        # (i.e. 0.25× – 4× of the default).
        def coerce_budget_per_gem(value)
          unless value.is_a?(Integer)
            raise ArgumentError,
                  "dependencies.budget_per_gem must be an Integer, " \
                  "got #{value.inspect}"
          end

          unless value.between?(MIN_BUDGET_PER_GEM, MAX_BUDGET_PER_GEM)
            raise ArgumentError,
                  "dependencies.budget_per_gem must be in the range " \
                  "#{MIN_BUDGET_PER_GEM}..#{MAX_BUDGET_PER_GEM}, " \
                  "got #{value.inspect}"
          end

          value
        end
      end
    end
  end
end
