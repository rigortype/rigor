# frozen_string_literal: true

require "rbs"

# Adds `_dump` / `_load` to {RBS::Location} so an
# `RBS::Environment` (and its transitive AST nodes, all of
# which carry Locations) round-trips through `Marshal`. The
# rbs gem's C-extension `RBS::Location` ships without the
# Marshal hooks; until rbs grows them upstream this patch is
# the minimal monkey-patch the v0.0.9 RBS::Environment cache
# relies on.
#
# Patch policy (purely additive):
#
# - `_dump` returns an empty string. The cached env loses
#   per-node source-position info, but Rigor does not consult
#   `RBS::Location` from any analysis code path (every
#   diagnostic uses Prism's own location), so the loss is
#   inert in practice.
# - `_load` reconstructs a sentinel Location backed by an
#   empty `<cached>` Buffer. Code paths that DID consult
#   Location after a cache hit see a benign zero-range value
#   rather than crashing.
#
# Idempotent: the guard checks `method_defined?(:_dump)` so
# requiring this file twice (or against an upstream rbs that
# adds Marshal hooks itself) is a no-op.
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
end
