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
    class Dependencies
      # Walking modes per
      # [ADR-10 § "Decision"](../../../docs/adr/10-dependency-source-inference.md#decision).
      VALID_MODES = %i[disabled when_missing full].freeze

      # Default `roots:` for an entry that does not supply one.
      # The hard-excluded directories (`spec/` / `test/` / `bin/`
      # / C extensions) are enforced by the walker, not the
      # parser — see ADR-10 § "Hard exclusions".
      DEFAULT_ROOTS = %w[lib].freeze

      # Frozen value object describing a single per-gem opt-in.
      # `gem:` is the gem name (matched against the bundle at
      # walk time); `mode:` is one of {VALID_MODES}; `roots:` is
      # the list of subdirectories within the gem's installation
      # directory to walk (defaults to `["lib"]`).
      Entry = Data.define(:gem, :mode, :roots) do
        def disabled? = mode == :disabled
        def when_missing? = mode == :when_missing
        def full? = mode == :full
      end

      attr_reader :source_inference

      # Parse the YAML-shaped `dependencies:` value into a
      # frozen {Dependencies}. Accepts `nil` / `{}` / a Hash with
      # `source_inference:` present.
      def self.from_h(data)
        return new([]) if data.nil?
        raise ArgumentError, "dependencies: must be a Hash, got #{data.inspect}" unless data.is_a?(Hash)

        entries = Array(data["source_inference"]).map { |raw| coerce_entry(raw) }
        new(entries)
      end

      def initialize(source_inference)
        @source_inference = source_inference.freeze
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
          end
        }
      end

      def empty? = @source_inference.empty?

      class << self
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
      end
    end
  end
end
