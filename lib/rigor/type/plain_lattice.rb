# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # Supplies the lattice-membership trio for the "plain" carriers — the
    # concrete value types that are neither a lattice extreme (`Top` /
    # `Bot` / `Dynamic`) nor a wrapper that computes membership from an
    # inner type.
    #
    # Every such carrier answers `top` / `bot` / `dynamic` with the same
    # `Trinary.no` ("this value is not that lattice point"), so the trio
    # lived as a byte-identical copy in a dozen carriers. The extremes
    # override the relevant member (`Top#top` / `Bot#bot` /
    # `Dynamic#dynamic` answer `Trinary.yes`) and the delegators (`App`,
    # `Difference`, `Refined`, `Union`) compute `dynamic` from their inner
    # type(s); none of those include this module.
    #
    # Mirrors the existing {AcceptanceRouter} / `ValueSemantics` mixins —
    # narrow trait sharing, never carrier inheritance (which the type-object
    # contract forbids).
    module PlainLattice
      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        Trinary.no
      end
    end
  end
end
