# frozen_string_literal: true

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #1507 — a file's issue #681 def-nesting table read over the cross-file seed rather than merged into a
      # copy of it. The copy inserted every `def` in the PROJECT once per analysed file (263 ms of an 18.95 s cold
      # Mastodon run); a lookup probes at most both layers, and only for a `def` whose body is re-walked.
      #
      # Both layers are keyed by node identity, so a same-file declaration and its cross-file twin are distinct keys
      # and the order cannot change an answer. The file layer is read first all the same, which is what the merge it
      # replaces did (`merge!(seed)`, then `merge!(file)`), so the answer holds even if a shared parse ever made the
      # keys overlap.
      #
      # It answers what the table's readers ask — `[]` ({ExpressionTyper#recorded_def_nesting}) and `empty?` — and
      # is deliberately not a Hash: `each`, `key?`, `size` or `==` would have to see both layers, and a Hash holding
      # one of them would answer those wrong instead of raising.
      class LayeredDefNestings
        def initialize(file, seed)
          @file = file
          @seed = seed
          freeze
        end

        # `fetch` rather than `||`, so presence in the file layer decides, as the later `merge!` did.
        def [](def_node)
          @file.fetch(def_node) { @seed[def_node] }
        end

        def empty?
          @file.empty? && @seed.empty?
        end
      end
    end
  end
end
