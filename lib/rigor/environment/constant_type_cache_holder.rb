# frozen_string_literal: true

module Rigor
  class Environment
    # Per-key memoization container for {Environment#constant_for_name}.
    # Held by {Environment} so the otherwise-frozen instance can cache
    # constant-resolution results on first access — the sibling of
    # {HktRegistryHolder}, generalised from one slot to a name-keyed map.
    #
    # Why this exists: `constant_for_name` is a pure function of its
    # name for a given Environment (both the predefined-constant
    # refinement table and the RBS loader's constant table are fixed for
    # the Environment's lifetime), yet it is the hottest non-dispatch
    # path on a large Rails app. {ExpressionTyper#resolve_constant_name}
    # peels a lexical-candidate ladder per constant reference, so the
    # same qualified names recur thousands of times across files — and
    # each miss runs a `const_get` walk that raises + rescues `NameError`
    # for every project-defined constant (the common case). Caching the
    # result collapses the repeats to a hash lookup.
    #
    # Caches `nil` results too (a name that resolves to no refined /
    # RBS constant type stays unresolved for the run), so the
    # const_get-and-rescue is paid at most once per distinct name.
    #
    # Concurrency: single-threaded use only, the same discipline as
    # {HktRegistryHolder} — the Ractor pool builds a per-worker
    # Environment and the LSP single-publish invariant serialises the
    # shared-Environment reader path. If a future caller introduces a
    # multi-threaded reader against one Environment, the synchronisation
    # belongs at that caller's seam, not here.
    class ConstantTypeCacheHolder
      def initialize
        @cache = {}
      end

      def fetch(key)
        return @cache[key] if @cache.key?(key)

        @cache[key] = yield
      end
    end
  end
end
