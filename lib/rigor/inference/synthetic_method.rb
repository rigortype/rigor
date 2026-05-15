# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-16 Tier C output — one synthetic method declared by a
    # plugin's `Plugin::Macro::HeredocTemplate` entry, after the
    # pre-pass has interpolated the call-site literal symbol into
    # the template name. Stored in {SyntheticMethodIndex} and
    # consulted by {MethodDispatcher} below the RBS dispatch tier.
    #
    # Per ADR-16 § WD13 (cost-bounded best-effort): the v0.1.x
    # delivery commitment is the floor — method names emit; their
    # return types degrade to `Dynamic[T]` until slice 6
    # (precision promotion) routes the recorded `return_type`
    # string through ADR-13's `Plugin::TypeNodeResolver` chain.
    # The string is preserved so the ceiling slice can resolve it
    # without re-walking.
    #
    # The `provenance` Hash carries debug / `--explain` metadata:
    # plugin id, the template's call shape, and the source
    # location of the originating DSL call. Surfaced through the
    # dispatcher's `macro.tier_c.*` provenance markers.
    class SyntheticMethod
      INSTANCE = :instance
      SINGLETON = :singleton
      VALID_KINDS = [INSTANCE, SINGLETON].freeze

      attr_reader :class_name, :method_name, :return_type, :kind, :provenance

      def initialize(class_name:, method_name:, return_type:, kind: INSTANCE, provenance: {})
        validate!(class_name, method_name, return_type, kind, provenance)
        @class_name = class_name.dup.freeze
        @method_name = method_name.to_sym
        @return_type = return_type.dup.freeze
        @kind = kind
        @provenance = provenance.transform_keys(&:to_sym).transform_values do |v|
          v.is_a?(String) ? v.dup.freeze : v
        end.freeze
        freeze
      end

      def instance? = kind == INSTANCE
      def singleton? = kind == SINGLETON

      def to_h
        {
          "class_name" => class_name,
          "method_name" => method_name.to_s,
          "return_type" => return_type,
          "kind" => kind.to_s,
          "provenance" => provenance.transform_keys(&:to_s)
        }
      end

      def ==(other)
        other.is_a?(SyntheticMethod) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      private

      def validate!(class_name, method_name, return_type, kind, provenance)
        unless class_name.is_a?(String) && !class_name.empty?
          raise ArgumentError, "SyntheticMethod#class_name must be non-empty String, got #{class_name.inspect}"
        end
        unless method_name.is_a?(Symbol) || (method_name.is_a?(String) && !method_name.empty?)
          raise ArgumentError, "SyntheticMethod#method_name must be Symbol/non-empty String, got #{method_name.inspect}"
        end
        unless return_type.is_a?(String) && !return_type.empty?
          raise ArgumentError, "SyntheticMethod#return_type must be non-empty String, got #{return_type.inspect}"
        end
        unless VALID_KINDS.include?(kind)
          raise ArgumentError, "SyntheticMethod#kind must be one of #{VALID_KINDS.inspect}, got #{kind.inspect}"
        end

        return if provenance.is_a?(Hash)

        raise ArgumentError, "SyntheticMethod#provenance must be a Hash, got #{provenance.inspect}"
      end
    end
  end
end
