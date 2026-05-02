# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # `Intersection[M1, M2, …]` — value set is the meet of every
    # member's value set. The carrier composes refinements that
    # share a base, in particular the catalogued
    # `non-empty-lowercase-string` (= `Difference[String, ""] &
    # Refined[String, :lowercase]`) and
    # `non-empty-uppercase-string` shapes from
    # [`imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md).
    # See [ADR-3](docs/adr/3-type-representation.md) for the
    # OQ3 working decision and the rationale for keeping
    # Intersection a thin wrapper rather than per-shape carriers.
    #
    # Construction MUST go through `Type::Combinator.intersection`
    # (or the per-name factories
    # `Combinator.non_empty_lowercase_string` /
    # `Combinator.non_empty_uppercase_string`). The factory:
    #
    # - flattens nested intersections,
    # - drops `Top` members (Top is the identity of intersection),
    # - collapses to `Bot` if any member is `Bot` (Bot is absorbing),
    # - deduplicates structurally-equal members,
    # - sorts the surviving members by `describe(:short)` so two
    #   structurally-equal intersections built in different orders
    #   compare equal,
    # - returns `Top` for the empty intersection,
    # - returns the lone member for a 1-element intersection (so
    #   the carrier is never inhabited by a degenerate single-member
    #   shape).
    #
    # Direct `.new` callers MUST pass an already-normalised member
    # list and are expected to be tests or the combinator itself.
    class Intersection
      attr_reader :members

      def initialize(members)
        @members = members.dup.freeze
        freeze
      end

      def describe(verbosity = :short)
        named = canonical_name
        return named if named

        members.map { |m| m.describe(verbosity) }.join(" & ")
      end

      # An intersection of refinements over the same base type
      # erases to that base. We use the first member's erasure
      # because the v0.0.4 catalogue (`non-empty-lowercase-string`
      # etc.) is restricted to same-base composition; richer
      # cross-base intersections will need a stricter erasure
      # rule (likely "lowest common ancestor" via the inference
      # engine's class hierarchy).
      def erase_to_rbs
        members.first.erase_to_rbs
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
        other.is_a?(Intersection) && members == other.members
      end
      alias eql? ==

      def hash
        [Intersection, members].hash
      end

      def inspect
        "#<Rigor::Type::Intersection #{describe(:short)}>"
      end

      private

      # Maps a structurally-recognised composite shape to its
      # kebab-case canonical name. The recognised set is kept in
      # sync with the imported-built-in catalogue
      # ([`imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md)).
      #
      # Detection is order-independent — `Combinator.intersection`
      # sorts the canonical member list, but reading the registry
      # the other way around (a user-authored Intersection built
      # in any order) MUST still print in its canonical spelling.
      def canonical_name
        return nil unless members.size == 2

        bases = members.map { |m| canonical_role(m) }.compact
        return nil unless bases.size == 2

        roles = bases.sort
        case roles
        when %w[lowercase non_empty_string] then "non-empty-lowercase-string"
        when %w[non_empty_string uppercase] then "non-empty-uppercase-string"
        end
      end

      # Returns a stable role tag for the recognised composite
      # members so `canonical_name` can pattern-match on a sorted
      # role pair regardless of construction order. Returns nil
      # when the member is not part of any catalogued composite —
      # any nil contribution disqualifies the canonical-name path
      # and the operator-form fallback kicks in.
      def canonical_role(member)
        case member
        when Difference
          "non_empty_string" if member == Type::Combinator.non_empty_string
        when Refined
          case member
          when Type::Combinator.lowercase_string then "lowercase"
          when Type::Combinator.uppercase_string then "uppercase"
          end
        end
      end
    end
  end
end
