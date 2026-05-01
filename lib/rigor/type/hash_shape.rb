# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A hash shape with statically known keys. Inhabitants are Ruby
    # `Hash` instances whose known entries inhabit the corresponding
    # value types. RBS records correspond to the exact closed subset;
    # Rigor extends that carrier with optional keys, read-only entry
    # views, and an open/closed extra-key policy.
    #
    # Keys are restricted to Symbol and String values. Exact closed
    # symbol-keyed shapes erase to the RBS record syntax
    # `{ a: Integer, ?b: String }`; all other shapes degrade to
    # `Hash[K, V]` or raw `Hash` when no useful bounds are available.
    #
    # Equality and hashing are structural over the (key -> Rigor::Type)
    # pair set and policy fields. Hash insertion order is preserved by
    # the underlying storage but does NOT affect equality (matching
    # Ruby's `Hash#==`).
    #
    # See docs/type-specification/rbs-compatible-types.md (records) and
    # docs/type-specification/rigor-extensions.md (hash shape).
    # rubocop:disable Metrics/ClassLength
    class HashShape
      ALLOWED_KEY_CLASSES = [Symbol, String].freeze
      EXTRA_KEY_POLICIES = %i[open closed].freeze
      POLICY_KEYWORDS = %i[required_keys optional_keys read_only_keys extra_keys].freeze

      attr_reader :pairs, :required_keys, :optional_keys, :read_only_keys, :extra_keys

      # @param pairs [Hash{Symbol|String => Rigor::Type}] ordered map of
      #   keys to declared types. Keys MUST be Symbol or String;
      #   values MUST be Rigor::Type instances. The hash is duped and
      #   frozen at construction; callers MUST NOT mutate the input
      #   afterwards (mutation does not affect the carrier, but the
      #   carrier is a value object).
      # @param required_keys [Array<Symbol|String>, nil] keys that MUST
      #   be present. When omitted, every non-optional key is required.
      #   When supplied without optional_keys, every remaining known key
      #   is treated as optional.
      # @param optional_keys [Array<Symbol|String>, nil] keys that MAY
      #   be absent. Optional absence is not a stored nil.
      # @param read_only_keys [Array<Symbol|String>] entries that cannot
      #   be written through this shape view.
      # @param extra_keys [Symbol] :closed rejects keys outside pairs;
      #   :open permits them.
      def initialize(pairs = nil, **keywords)
        pairs, policy = split_constructor_args(pairs, keywords)
        validate_pairs!(pairs)

        @pairs = pairs.dup.freeze
        apply_policy!(policy)
        freeze
      end

      def describe(verbosity = :short)
        return "{}" if pairs.empty?

        rendered = pairs.map { |k, v| render_entry(k, v, verbosity) }
        rendered << "..." if open?
        "{ #{rendered.join(', ')} }"
      end

      # Erases to the RBS record form `{ a: Integer, ?b: String }`
      # for exact closed symbol-keyed shapes. Open shapes and
      # string-keyed closed shapes degrade to a generic Hash bound.
      def erase_to_rbs
        return "{}" if pairs.empty? && closed?
        return hash_erasure unless closed?
        return hash_erasure if pairs.each_key.any? { |k| !k.is_a?(Symbol) }

        rendered = pairs.map { |k, v| "#{record_key(k)}: #{v.erase_to_rbs}" }
        "{ #{rendered.join(', ')} }"
      end

      def open?
        extra_keys == :open
      end

      def closed?
        extra_keys == :closed
      end

      def required_key?(key)
        required_keys.include?(key)
      end

      def optional_key?(key)
        optional_keys.include?(key)
      end

      def read_only_key?(key)
        read_only_keys.include?(key)
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
        other.is_a?(HashShape) &&
          pairs == other.pairs &&
          required_keys == other.required_keys &&
          optional_keys == other.optional_keys &&
          read_only_keys == other.read_only_keys &&
          extra_keys == other.extra_keys
      end
      alias eql? ==

      def hash
        [HashShape, pairs, required_keys, optional_keys, read_only_keys, extra_keys].hash
      end

      def inspect
        "#<Rigor::Type::HashShape #{describe(:short)}>"
      end

      private

      def split_constructor_args(pairs, keywords)
        if pairs.nil?
          policy = keywords.slice(*POLICY_KEYWORDS)
          entries = keywords.except(*POLICY_KEYWORDS)
          return [entries, policy]
        end

        unknown = keywords.keys - POLICY_KEYWORDS
        raise ArgumentError, "unknown keywords: #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

        [pairs, keywords]
      end

      def validate_pairs!(pairs)
        raise ArgumentError, "pairs must be a Hash, got #{pairs.class}" unless pairs.is_a?(Hash)

        pairs.each_key do |key|
          next if ALLOWED_KEY_CLASSES.any? { |klass| key.is_a?(klass) }

          raise ArgumentError, "HashShape keys must be Symbol or String, got #{key.class}"
        end
      end

      def apply_policy!(policy)
        extra_keys = policy.fetch(:extra_keys, :closed)
        unless EXTRA_KEY_POLICIES.include?(extra_keys)
          raise ArgumentError, "extra_keys must be :open or :closed, got #{extra_keys.inspect}"
        end

        @extra_keys = extra_keys
        @required_keys, @optional_keys = classify_keys(
          policy.fetch(:required_keys, nil),
          policy.fetch(:optional_keys, nil)
        )
        @read_only_keys = canonical_key_list(policy.fetch(:read_only_keys, []), label: "read_only_keys")
      end

      def classify_keys(required_source, optional_source)
        required, optional = key_sources(required_source, optional_source)
        required_keys = canonical_key_list(required, label: "required_keys")
        optional_keys = canonical_key_list(optional, label: "optional_keys")
        validate_key_partition(required_keys, optional_keys)
        [required_keys, optional_keys]
      end

      def key_sources(required_source, optional_source)
        if required_source && optional_source.nil?
          required = Array(required_source)
          optional = pairs.keys - required
        else
          optional = optional_source.nil? ? [] : Array(optional_source)
          required = required_source.nil? ? pairs.keys - optional : Array(required_source)
        end

        [required, optional]
      end

      def canonical_key_list(keys, label:)
        keys = Array(keys)
        raise ArgumentError, "#{label} must not contain duplicate keys" unless keys.uniq.size == keys.size

        unknown = keys - pairs.keys
        raise ArgumentError, "#{label} contains keys not present in pairs: #{unknown.inspect}" unless unknown.empty?

        keys.sort_by { |key| [key.class.name, key.inspect] }.freeze
      end

      def validate_key_partition(required, optional)
        overlap = required & optional
        raise ArgumentError, "required_keys and optional_keys overlap: #{overlap.inspect}" unless overlap.empty?

        missing = pairs.keys - (required + optional)
        return if missing.empty?

        raise ArgumentError, "keys must be classified as required or optional: #{missing.inspect}"
      end

      def render_entry(key, value, verbosity)
        prefix = []
        prefix << "readonly" if read_only_key?(key)
        rendered_key = optional_key?(key) ? "?#{render_key(key)}" : render_key(key)
        prefix << "#{rendered_key}:"
        "#{prefix.join(' ')} #{value.describe(verbosity)}"
      end

      def render_key(key)
        case key
        when Symbol then key.to_s
        when String then key.inspect
        end
      end

      def record_key(key)
        optional_key?(key) ? "?#{key}" : key.to_s
      end

      def hash_erasure
        return "Hash[top, top]" if open?
        return "Hash" if pairs.empty?

        key_type = hash_erasure_key_type
        value_type = Type::Combinator.union(*pairs.values)
        "Hash[#{key_type.erase_to_rbs}, #{value_type.erase_to_rbs}]"
      end

      def hash_erasure_key_type
        key_types = pairs.keys.map { |key| Type::Combinator.nominal_of(key.class) }
        Type::Combinator.union(*key_types)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
