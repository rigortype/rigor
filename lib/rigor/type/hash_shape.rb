# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"
require_relative "plain_lattice"

module Rigor
  module Type
    # A hash shape with statically known keys. Inhabitants are Ruby `Hash` instances whose known entries
    # inhabit the corresponding value types. RBS records correspond to the exact closed subset; Rigor
    # extends that carrier with optional keys, read-only entry views, and an open/closed extra-key policy.
    #
    # Keys are restricted to value-pinned scalar literals: Symbol, String, Integer, Float, and the
    # `true` / `false` / `nil` singletons. Exact closed symbol-keyed shapes erase to the RBS record
    # syntax `{ a: Integer, ?b: String }`; all other shapes degrade to `Hash[K, V]` or raw `Hash` when
    # no useful bounds are available. Key identity follows Ruby's own `Hash` `eql?` semantics because
    # the pairs are stored in a native Ruby Hash — `1` and `1.0` are DISTINCT keys (`1.eql?(1.0)` is
    # false), while `1.0` and `1.00` are the same key.
    #
    # Equality and hashing are structural over the (key -> Rigor::Type) pair set and policy fields. Hash
    # insertion order is preserved by the underlying storage but does NOT affect equality (matching
    # Ruby's `Hash#==`).
    #
    # See docs/type-specification/rbs-compatible-types.md (records) and
    # docs/type-specification/rigor-extensions.md (hash shape).
    class HashShape
      ALLOWED_KEY_CLASSES = [Symbol, String, Integer, Float, TrueClass, FalseClass, NilClass].freeze
      EXTRA_KEY_POLICIES = %i[open closed].freeze
      POLICY_KEYWORDS = %i[required_keys optional_keys read_only_keys extra_keys].freeze
      # A Symbol whose text matches renders as a bare RBS record key (`lang:`) in {#erase_to_rbs};
      # anything else must be quoted with a fat arrow (`"data-contrast" =>`). See {#erase_key_prefix}.
      BARE_RECORD_KEY = /\A[A-Za-z_][A-Za-z0-9_]*[?!]?\z/

      attr_reader :pairs, :required_keys, :optional_keys, :read_only_keys, :extra_keys

      # @rbs pairs: Hash[Symbol | String, Rigor::Type] --
      #   Ordered map of keys to declared types. Keys MUST be Symbol or String; values MUST be Rigor::Type instances.
      #   The hash is duped and frozen at construction; callers MUST NOT mutate the input afterwards (mutation does
      #   not affect the carrier, but the carrier is a value object).
      # @rbs required_keys: Array[Symbol | String]? --
      #   Keys that MUST be present. When omitted, every non-optional key is required. When supplied without
      #   optional_keys, every remaining known key is treated as optional.
      # @rbs optional_keys: Array[Symbol | String]? -- Keys that MAY be absent. Optional absence is not a stored nil.
      # @rbs read_only_keys: Array[Symbol | String] -- Entries that cannot be written through this shape view.
      # @rbs extra_keys: Symbol -- :closed rejects keys outside pairs; :open permits them.
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

      # Erases to the RBS record form `{ a: Integer, ?b: String }` for exact closed symbol-keyed shapes.
      # Open shapes and string-keyed closed shapes degrade to a generic Hash bound.
      def erase_to_rbs
        return "{}" if pairs.empty? && closed?
        return hash_erasure unless closed?
        return hash_erasure if pairs.each_key.any? { |k| !k.is_a?(Symbol) }

        rendered = pairs.map { |k, v| "#{erase_key_prefix(k)} #{v.erase_to_rbs}" }
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

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :pairs, :required_keys, :optional_keys, :read_only_keys, :extra_keys

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

          raise ArgumentError,
                "HashShape keys must be one of #{ALLOWED_KEY_CLASSES.join(', ')}, got #{key.class}"
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
        prefix << "#{rendered_key}#{key_separator(key)}"
        "#{prefix.join(' ')} #{value.describe(verbosity)}"
      end

      # `describe` is a human-facing display contract (it feeds diagnostic messages, never a parser),
      # so it keeps the compact `"a":` form for a quoted key. Non-(Symbol|String) scalar keys render in
      # the natural hashrocket spelling (`1 => 2`, `1.0 => 4`, `nil => 0`) via {#key_separator}; their
      # `inspect` is the canonical Ruby literal, so describe stays deterministic. The RBS-erasure path
      # uses {#erase_key_prefix} instead, which must emit a parseable key.
      def render_key(key)
        case key
        when Symbol then key.to_s
        else key.inspect
        end
      end

      # Symbol / String keys keep the compact colon form (`a: 1`, `"k": 2`); every other scalar key uses
      # the hashrocket (`1 => 2`) — the form the user would have to write in source.
      def key_separator(key)
        case key
        when Symbol, String then ":"
        else " =>"
        end
      end

      # An RBS record entry's key + separator, for the {#erase_to_rbs} path (which only ever sees
      # Symbol keys — string-keyed shapes degrade to `Hash[...]` before reaching here). A Symbol whose
      # text is a plain identifier is a bare key with a colon (`lang:`); a hyphenated / punctuated
      # Symbol MUST use the quoted `"data-contrast" =>` form, because RBS rejects both a bare
      # non-identifier (`data-contrast:`) and a quoted key with a colon (`"data-contrast":`). Getting
      # this wrong made sig-gen emit an unparseable Mastodon `html_attributes` shape that crashed the
      # whole RBS env build. Valid identifier keys (incl. Ruby keywords like `class`) keep the colon
      # form, so only genuinely non-identifier keys change. Optional keys carry a leading `?`.
      def erase_key_prefix(key)
        optional = optional_key?(key) ? "?" : ""
        if BARE_RECORD_KEY.match?(key.to_s)
          "#{optional}#{key}:"
        else
          "#{optional}#{key.to_s.inspect} =>"
        end
      end

      def hash_erasure
        return "Hash[top, top]" if open?
        return "Hash" if pairs.empty?

        key_type = hash_erasure_key_type
        value_type = Type::Combinator.union(*pairs.values)
        "Hash[#{key_type.erase_to_rbs}, #{value_type.erase_to_rbs}]"
      end

      # Conservative per-key-class bound for the `Hash[K, V]` degradation. Symbol / String / Integer /
      # Float keys widen to their class nominal; the `true` / `false` / `nil` singletons keep their
      # literal carrier (the constant IS the class's whole value set, and RBS spells the literal — `nil`
      # reads better than `NilClass`).
      def hash_erasure_key_type
        key_types = pairs.keys.map do |key|
          case key
          when true, false, nil then Type::Combinator.constant_of(key)
          else Type::Combinator.nominal_of(key.class)
          end
        end
        Type::Combinator.union(*key_types)
      end
    end
  end
end
