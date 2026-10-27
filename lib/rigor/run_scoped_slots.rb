# frozen_string_literal: true

module Rigor
  # Issues #2412 and #2399 — the registry of per-thread memo slots whose contents belong to one analysis run. An
  # owner registers its `Thread.current` key where it names it (`KEY = RunScopedSlots.register(:key)`), and each
  # entry point that runs an analysis calls {.release} in its `ensure`, so a finished run, or one that raised,
  # leaves none of its scopes, discovery tables or environment behind on the thread.
  #
  # A slot that holds its run until the next run overwrites it retains one run per thread. A slot whose value
  # reaches its own key retains every run, as `LoopValueRecord`'s `ObjectSpace::WeakKeyMap` did: the map holds
  # its values strongly, and a recorded scope reaches the parse tree that holds the key node. Releasing at run end
  # bounds both. Inside a run nothing changes: every memo keeps its key and its hit rate, and a slot read outside
  # a run (a language-server hover on the main thread) refills on its first miss.
  #
  # Only memo slots belong here. A slot a `with_*` frame installs and restores around a block is already empty
  # when the frame returns, and clearing it from inside a frame would break the frame.
  #
  # The registry is a module-level array filled at require time, so it is for the main Ractor only.
  module RunScopedSlots
    @keys = []

    # Adds `key` to the registry and returns it, so the owner's constant keeps its value.
    def self.register(key)
      @keys << key unless @keys.include?(key)
      key
    end

    # Every registered key, in registration order.
    def self.keys = @keys.dup.freeze

    # Empties every registered slot on the calling thread.
    def self.release
      thread = Thread.current
      @keys.each { |key| thread[key] = nil }
      nil
    end
  end
end
