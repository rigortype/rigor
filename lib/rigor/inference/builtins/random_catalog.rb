# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Random` catalog. Singleton — load once, consult during
      # dispatch.
      #
      # The static classifier marks most Random methods `:leaf`
      # because their C bodies do not call `rb_funcall*` /
      # `rb_yield` / `rb_check_frozen` directly. Random is the
      # canonical case where that heuristic under-counts: every
      # call to `#rand` / `#bytes` / `Random.rand` / `Random.bytes`
      # advances the receiver's Mersenne-Twister state through a
      # helper (`rand_random` -> `random_real` / `random_ulong_limited`),
      # so folding any of them statically is unsound.
      # `Random.new_seed` and `Random.urandom` are non-deterministic
      # (different output every call); even though they are
      # functionally pure they would produce a misleading constant
      # at fold time. The whole class is conservative-by-default
      # at the catalog tier; precision flows through the RBS layer.
      RANDOM_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/random.yml",
          __dir__
        ),
        mutating_selectors: {
          "Random" => Set[
            # `rand_random` -> `random_real` / `random_ulong_limited`
            # advance the MT state on the receiver (instance #rand)
            # and on `Random::DEFAULT` (singleton .rand). The
            # classifier misses the indirect mutator.
            :rand,
            # `random_bytes` / `random_s_bytes` consume MT output
            # the same way #rand does — every call mutates the
            # underlying generator.
            :bytes,
            # Non-deterministic: each call produces a fresh seed
            # via `with_random_seed` reading platform entropy. Folding
            # to a constant would freeze a value that the runtime
            # never actually returns twice.
            :new_seed,
            # Non-deterministic: reads from platform CSPRNG (e.g.
            # /dev/urandom). Folding is unsound for the same reason
            # as `new_seed`.
            :urandom,
            # `initialize_copy` is blocklisted by convention so a
            # hypothetical future `Constant<Random>` carrier
            # cannot fold an aliasing copy through the catalog.
            :initialize_copy
          ]
        }
      )
    end
  end
end
