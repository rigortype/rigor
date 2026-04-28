# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A hash shape with statically known keys. Inhabitants are Ruby
    # `Hash` instances that contain at least every declared key with a
    # value inhabiting the corresponding type. In RBS this corresponds
    # to the record form `{ key: T }`.
    #
    # Slice 5 phase 1 carries only the closed-but-not-strict variant:
    # every declared key MUST be present (depth subtyping is covariant
    # under acceptance), and acceptance permits the actual hash to
    # carry extra keys (width subtyping accepts wider shapes). Required
    # / optional / closed-extra-key policies and read-only markers are
    # the Rigor extensions described in
    # docs/type-specification/rigor-extensions.md (#hash-shape) and
    # land in Slice 5 phase 2.
    #
    # Keys are restricted to Symbol and String values. RBS records only
    # support symbol keys, so a HashShape with string keys erases to
    # the bare `Nominal[Hash]`. Symbol-keyed shapes erase to the RBS
    # record syntax `{ a: Integer, b: String }`.
    #
    # Equality and hashing are structural over the (key -> Rigor::Type)
    # pair set. Hash insertion order is preserved by the underlying
    # storage but does NOT affect equality (matching Ruby's `Hash#==`).
    #
    # See docs/type-specification/rbs-compatible-types.md (records) and
    # docs/type-specification/rigor-extensions.md (hash shape).
    class HashShape
      ALLOWED_KEY_CLASSES = [Symbol, String].freeze

      attr_reader :pairs

      # @param pairs [Hash{Symbol|String => Rigor::Type}] ordered map of
      #   keys to declared types. Keys MUST be Symbol or String;
      #   values MUST be Rigor::Type instances. The hash is duped and
      #   frozen at construction; callers MUST NOT mutate the input
      #   afterwards (mutation does not affect the carrier, but the
      #   carrier is a value object).
      def initialize(pairs)
        raise ArgumentError, "pairs must be a Hash, got #{pairs.class}" unless pairs.is_a?(Hash)

        pairs.each_key do |k|
          unless ALLOWED_KEY_CLASSES.any? { |c| k.is_a?(c) }
            raise ArgumentError, "HashShape keys must be Symbol or String, got #{k.class}"
          end
        end

        @pairs = pairs.dup.freeze
        freeze
      end

      def describe(verbosity = :short)
        return "{}" if pairs.empty?

        rendered = pairs.map { |k, v| "#{render_key(k)}: #{v.describe(verbosity)}" }
        "{ #{rendered.join(', ')} }"
      end

      # Erases to the RBS record form `{ a: Integer }` when every key
      # is a Symbol; otherwise degrades to the bare `Hash` nominal
      # because RBS records cannot carry string keys.
      def erase_to_rbs
        return "Hash" if pairs.empty?
        return "Hash" if pairs.each_key.any? { |k| !k.is_a?(Symbol) }

        rendered = pairs.map { |k, v| "#{k}: #{v.erase_to_rbs}" }
        "{ #{rendered.join(', ')} }"
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        Trinary.no
      end

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end

      def ==(other)
        other.is_a?(HashShape) && pairs == other.pairs
      end
      alias eql? ==

      def hash
        [HashShape, pairs].hash
      end

      def inspect
        "#<Rigor::Type::HashShape #{describe(:short)}>"
      end

      private

      def render_key(key)
        case key
        when Symbol then key.to_s
        when String then key.inspect
        end
      end
    end
  end
end
