# frozen_string_literal: true

require "rbs"

require_relative "annotation_location"

# Adds `_dump` / `_load` to {RBS::Location} so an `RBS::Environment` (and its transitive AST nodes, all of
# which carry Locations) round-trips through `Marshal`. The rbs gem's C-extension `RBS::Location` ships
# without the Marshal hooks; until rbs grows them upstream this patch is the minimal monkey-patch the v0.0.9
# RBS::Environment cache relies on.
#
# Patch policy (purely additive):
#
# - `_dump` returns the buffer's NAME and nothing else. Per-node source POSITIONS are still dropped (Rigor
#   does not consult them from any analysis path — every diagnostic uses Prism's own location), but the
#   file a declaration came from is cheap to keep and is not inert: `rbs.coverage.definition-build-failed`
#   names the conflicting signature files, and dropping the name made a warm run omit that clause while a
#   cold run printed it, so the same project said different things by cache state (issue #696 review,
#   second pass). It costs cache SIZE: a `_dump` payload is raw bytes, not a linkable object graph, so the
#   path is written once per Location rather than once per buffer. Memoising the coerced name per buffer was
#   tried and changes nothing for exactly that reason. Measured +6.6% on a realistic project (Rigor's own
#   349-file `lib`: 4,332K to 4,616K) and +12.3% on a one-file project (1,672K to 1,876K), both stable
#   across reps — the env blob is fixed overhead, so the ratio falls as a project's own cached data grows
#   and the realistic figure is the lower one. That is the price of a diagnostic that reads the same warm
#   and cold; positions, which are far more numerous and which nothing reads, stay dropped.
# - `_load` reconstructs a zero-range Location over that name, falling back to a `<cached>` sentinel when
#   the dump carried none. Code paths that DID consult Location after a cache hit see a benign value rather
#   than crashing, and one that reads `buffer.name` now sees the real path.
# - Both directions were exercised rather than assumed. A NEW blob read by an OLDER `_load` — which ignored
#   its argument — loads and behaves exactly as before; that direction is clean. An OLD blob read by THIS
#   `_load` also loads without raising, and the sentinel fallback keeps it from ever naming `<cached>` as a
#   path — but the conflicting-files clause then goes missing, so a warm run off a pre-change blob says less
#   than a cold run does. ADR-6's store never evicts, so that would persist. `Cache::Store::FORMAT_VERSION`
#   is therefore bumped to 3: `PAYLOAD_ABI_VERSION` already rebuilds across a release, and the bump closes
#   the same-version window too.
# - `RBS::AST::Annotation` carries its own `marshal_dump` / `marshal_load`, which keep the annotation's
#   POSITION as well as its file (issue #799). "Nothing reads positions" was never quite true: the two
#   `conforms-to` rows — `rbs_extended.unsatisfied-conformance` and `dynamic.rbs-extended.unresolved` —
#   are reported AT the directive, because there is no Ruby `def` a missing interface method could be
#   reported at, so both read `start_line` / `start_column` off an annotation's location. (They are the
#   only readers: {Rigor::RbsExtended::EnvelopeScanner} positions `effect.unknown-label` at an annotation
#   too, but reaches it by parsing the project's own `.rbs` rather than the built env — refusing this very
#   loss is one of the two reasons it does.) Cold the row is `sig/buffer.rbs:6:1`; through a `_dump`ed
#   location it collapsed to `1:1`, which made `--verify-incremental` fail outright on any project carrying
#   an unsatisfied directive (the replica normalises rows by position, and only one side of the comparison
#   runs against the cached env) and made a warm `--incremental` run move a row on a tree that had not
#   changed. The carry is scoped to annotations rather than done in `_dump` for the reason the paragraph
#   above gives: a Location hangs off every AST node, and carrying its position measured +2.9% on Rigor's
#   own env (9,941K to 10,229K) on top of the names. An annotation is rare by comparison — 18 of them in
#   that same env — so the same carry costs +1.4K there, which is the whole argument for scoping it here
#   rather than widening `_dump`. `Cache::Store::FORMAT_VERSION` is bumped to 4 for the same reason it was
#   bumped to 3: a pre-change blob still loads (Marshal encodes an ivar dump and a `marshal_dump` payload
#   differently, and only the latter reaches `marshal_load`), so without the bump a stale blob would keep
#   reporting the moved position indefinitely.
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
    # The name a Location gets back when the dump carried none — an old blob, or a buffer that never had
    # one. Never a real path, so a consumer that reports file names must filter it
    # ({Rigor::Environment::RbsLoader::CACHED_LOCATION_BUFFER_NAME}).
    CACHED_BUFFER_NAME = "<cached>"

    unless method_defined?(:_dump)
      def _dump(_)
        buffer&.name.to_s
      end

      def self._load(name)
        name = CACHED_BUFFER_NAME if name.nil? || name.empty?
        new(buffer: ::RBS::Buffer.new(name: name, content: ""), start_pos: 0, end_pos: 0)
      end
    end
  end

  module AST
    class Annotation
      # Carries the annotation's POSITION across the cache, not just its file. See the header's fourth
      # bullet for why this one AST node opts out of the position-dropping `RBS::Location#_dump` above.
      unless method_defined?(:marshal_dump)
        def marshal_dump
          [string, Rigor::Cache::AnnotationLocation.dump(location)]
        end

        def marshal_load(payload)
          dumped_string, dumped_location = payload
          @string = dumped_string
          @location = Rigor::Cache::AnnotationLocation.load(dumped_location)
        end
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
