# frozen_string_literal: true

require "rbs"

# Adds `_dump` / `_load` to {RBS::Location} so an `RBS::Environment` (and its transitive AST nodes, all of
# which carry Locations) round-trips through `Marshal`. The rbs gem's C-extension `RBS::Location` ships
# without the Marshal hooks; until rbs grows them upstream this patch is the minimal monkey-patch the v0.0.9
# RBS::Environment cache relies on.
#
# Patch policy (purely additive):
#
# - `_dump` returns an empty string. The cached env loses per-node source-position info, but Rigor does not
#   consult `RBS::Location` from any analysis code path (every diagnostic uses Prism's own location), so the
#   loss is inert in practice.
# - `_load` reconstructs a sentinel Location backed by an empty `<cached>` Buffer. Code paths that DID consult
#   Location after a cache hit see a benign zero-range value rather than crashing.
#
# Idempotent: the guard checks `method_defined?(:_dump)` so requiring this file twice (or against an upstream
# rbs that adds Marshal hooks itself) is a no-op.
#
# `RBS::TypeName` / `RBS::Namespace` carry a second, subtler Marshal hazard, introduced by rbs 4.1's
# flyweight interning (ruby/rbs#2957): both memoise their `#hash` into an `@hash` ivar, and that value is
# derived from `Array#hash` / `Symbol#hash`, which Ruby seeds PER PROCESS. Marshal round-trips the ivar
# verbatim, so a cached `TypeName` loaded in a later process answers `hash` with the *writing* process's
# value while a freshly parsed `TypeName.parse("::String")` answers with this process's. The two are still
# `eql?`, so nothing raises — every Hash keyed by a TypeName simply misses. `RBS::Environment#class_decls`
# is exactly such a Hash, so a warm cache silently reported every core class as unknown.
#
# `_dump` / `_load` on both classes fixes it at the representation: the name is dumped as its source string
# and reconstructed through `.parse`, which routes back through the flyweight interner. That drops the stale
# `@hash` (it is re-memoised on demand, under this process's seed), and restores the flyweight identity the
# interner exists to provide — a cached env now shares one object per distinct name rather than one per
# reference. Both classes are value objects fully described by `to_s`, so the round-trip is lossless.
module RBS
  class Location
    unless method_defined?(:_dump)
      def _dump(_)
        ""
      end

      def self._load(_)
        new(buffer: ::RBS::Buffer.new(name: "<cached>", content: ""), start_pos: 0, end_pos: 0)
      end
    end
  end

  class Namespace
    unless method_defined?(:_dump)
      def _dump(_)
        to_s
      end

      def self._load(string)
        parse(string)
      end
    end
  end

  class TypeName
    unless method_defined?(:_dump)
      def _dump(_)
        to_s
      end

      def self._load(string)
        parse(string)
      end
    end
  end
end
