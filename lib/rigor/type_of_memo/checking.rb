# frozen_string_literal: true

module Rigor
  module TypeOfMemo
    # G1's stage-3 comparison (ADR-129 WD5), mixed into {TypeOfMemo}'s singleton: on a would-be hit production computes,
    # and the result is compared with what serving the entry would have done.
    module Checking
      EMPTY = [].freeze
      private_constant :EMPTY

      private

      # A would-be hit: production computes, and G1 compares it with what serving the entry would have done.
      def check_hit(state, phase, scope, node, entry)
        stored, writes = entry.is_a?(Array) ? [entry[0], entry[2]] : [entry, EMPTY]
        count(phase, :checked)
        state.open_capture
        state.open_priors
        begin
          fresh = yield
        ensure
          priors = state.close_priors
          refused, = state.close_capture
        end
        judge(state, phase, scope, node, stored, fresh, writes, priors, refused)
        fresh
      end

      # G1's verdict on one would-be hit. An error in the comparison itself is counted as a mismatch rather than raised:
      # the typing path's rescues would turn a raise into a different answer.
      def judge(state, phase, scope, node, stored, fresh, writes, priors, refused) # rubocop:disable Metrics/ParameterLists
        compare(state, phase, scope, node, stored, fresh, writes, priors, refused)
      rescue StandardError => e
        count(phase, :mismatch)
        count(phase, :mismatch_judge_error)
        sample(phase, scope, node, [:judge_error, "#{e.class}: #{e.message[0, 120]}"], stored, fresh, [])
      end

      def compare(state, phase, scope, node, stored, fresh, writes, priors, refused) # rubocop:disable Metrics/ParameterLists
        kinds = []
        kinds << :type unless same?(fresh, stored)
        kinds << :resource if refused
        diffs = table_diffs(state, writes, priors)
        kinds << :table unless diffs.empty?
        return if kinds.empty?

        report(phase, scope, node, kinds, stored, fresh, diffs)
      end

      def report(phase, scope, node, kinds, stored, fresh, diffs)
        count(phase, :mismatch)
        kinds.each { |kind| count(phase, :"mismatch_#{kind}") if kind.is_a?(Symbol) }
        sample(phase, scope, node, kinds, stored, fresh, diffs)
        nil
      end

      # The entries where the live tables differ from their pre-computation state with `writes` replayed: each key
      # the entry wrote must hold its last written value, and each key only the live computation wrote must hold
      # the value it replaced.
      def table_diffs(state, writes, priors)
        expected = TypingState::KeyIndex.new
        diffs = []
        # The last write of a key is what a replay leaves there: walk backwards and take each key once.
        writes.each_slice(3).reverse_each do |slot, key, value|
          next if expected.key?(slot, key)

          expected.store(slot, key, value)
          now = state.entry(slot, key)
          diffs << [slot, key, value, now] unless same?(value, now)
        end
        priors.each_slice(3) do |slot, key, prior|
          next if expected.key?(slot, key)

          now = state.entry(slot, key)
          diffs << [slot, key, prior, now] unless same?(prior, now)
        end
        diffs.uniq { |slot, key, _, _| [slot, key.is_a?(Array) ? key.map(&:__id__) : key.__id__] }
      end

      # Entry values compare by identity, or by `==` element-wise, a scope (which the one-slot caches record) by
      # identity alone: `Scope#==` ignores fields typing reads.
      #
      # `==` ignores a Hash's order, which output shows: a type also compares its rendering
      # (`HashShape#==` compares its pairs as a Hash), and a Hash its entries in order.
      def same?(left, right)
        return true if left.equal?(right)
        return false if left.is_a?(Scope) || right.is_a?(Scope)
        return ordered_same?(left.to_a, right.to_a) if left.is_a?(Hash) && right.is_a?(Hash)
        return ordered_same?(left, right) if left.is_a?(Array) && right.is_a?(Array)
        return false unless left == right

        !left.respond_to?(:describe) || !right.respond_to?(:describe) || left.describe(:short) == right.describe(:short)
      end

      def ordered_same?(left, right)
        left.size == right.size && left.each_index.all? { |index| same?(left[index], right[index]) }
      end
    end
  end
end
