# frozen_string_literal: true

module Rigor
  module TypeOfMemo
    # One file's entries, `scope => node => state id => entry`, and the phase its analysis is in.
    class Table
      attr_accessor :phase
      attr_reader :entries

      # Whether the table keys on the ELIDE id ({TypingState::ElideId}) rather than the state id.
      attr_reader :elide

      # Recomputations of G1's stage-4 form open on this table ({TypeOfMemo.enable!} with `:serve`), during which the
      # memo is suspended.
      attr_accessor :suspended

      def initialize(elide: false, phase: :other)
        @entries = {}.compare_by_identity
        @phase = phase
        @elide = elide
        @suspended = 0
        @live_scopes = {}.compare_by_identity
        @live_ids = {}.compare_by_identity
        @live_entries = {}.compare_by_identity
      end

      # The live memo's entry for `node` in `scope` at state id `id`, or nil. Live, a node keeps one entry, the last
      # one stored (stage 0 measured a one-slot-per-node key losing under 0.3% of hits), in three identity Hashes keyed
      # on the node, so storing allocates no Hash per node.
      def live_entry(scope, node, id)
        return nil unless @live_ids[node] == id && @live_scopes[node].equal?(scope)

        @live_entries[node]
      end

      def live_store(scope, node, id, entry)
        @live_scopes[node] = scope
        @live_ids[node] = id
        @live_entries[node] = entry
      end
    end
  end
end
