# frozen_string_literal: true

require_relative "top"
require_relative "bot"
require_relative "dynamic"
require_relative "nominal"
require_relative "constant"
require_relative "union"

module Rigor
  module Type
    # Factory entry point that routes every public construction through the
    # deterministic normalization rules. Production code paths MUST go
    # through Rigor::Type::Combinator. Direct constructor calls are an
    # internal escape hatch for tests and for combinator's own
    # implementation.
    #
    # See docs/internal-spec/internal-type-api.md and
    # docs/type-specification/normalization.md.
    module Combinator
      module_function

      def top
        Top.instance
      end

      def bot
        Bot.instance
      end

      def untyped
        @untyped ||= Dynamic.new(top)
      end

      # Wraps the static facet in a Dynamic[T] carrier. Idempotent on the
      # static facet so Dynamic[Dynamic[T]] collapses to Dynamic[T] per the
      # value-lattice algebra.
      def dynamic(static_facet)
        return untyped if static_facet.equal?(top)

        facet = static_facet.is_a?(Dynamic) ? static_facet.static_facet : static_facet
        return untyped if facet.is_a?(Top)

        Dynamic.new(facet)
      end

      def nominal_of(class_name_or_object)
        name =
          case class_name_or_object
          when Module then class_name_or_object.name
          when String then class_name_or_object
          else
            raise ArgumentError, "expected Class/Module or String, got #{class_name_or_object.class}"
          end

        raise ArgumentError, "anonymous class has no name" if name.nil? || name.empty?

        Nominal.new(name)
      end

      def constant_of(value)
        Constant.new(value)
      end

      # Normalized union. Flattens nested Unions, deduplicates structurally
      # equal members, drops Bot, and collapses 0/1-member results.
      def union(*types)
        flattened = []
        types.each { |t| flatten_into(flattened, t) }

        # Drop Bot (identity for union).
        flattened.reject! { |t| t.is_a?(Bot) }

        # Top absorbs everything.
        return top if flattened.any? { |t| t.is_a?(Top) }

        # Deduplicate structurally.
        unique = []
        flattened.each { |t| unique << t unless unique.any? { |u| u == t } }

        case unique.size
        when 0 then bot
        when 1 then unique.first
        else
          Union.new(sort_members(unique))
        end
      end

      class << self
        private

        def flatten_into(acc, type)
          if type.is_a?(Union)
            type.members.each { |m| flatten_into(acc, m) }
          else
            acc << type
          end
        end

        def sort_members(members)
          members.sort_by { |m| m.describe(:short) }
        end
      end
    end
  end
end
