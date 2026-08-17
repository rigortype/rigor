# frozen_string_literal: true

require_relative "effect_table"

module Rigor
  module Effects
    # "Why does this entry point reach `io.net.http`?" — the shortest edge path from a method to the
    # origin that introduced a label (ADR-103 WD7; design note § 9.4, "the review feature that pays for
    # the fixpoint").
    #
    #   OrdersController#create → OrderService#place → PaymentGateway#charge → Net::HTTP.get [io.net.http]
    #
    # A breadth-first walk over the {EffectTable}'s resolved edges, so the answer is a *shortest* path
    # rather than whichever one a depth-first walk stumbled into first — a reviewer wants the tightest
    # explanation available. Ties break on sorted key order, so two runs explain a change identically.
    #
    # The path ends at the **origin**, not at the last method: the catalogue row or language construct
    # that actually coloured the label is what the reviewer is looking for, and the method that owns it
    # is the hop before.
    module PathFinder
      # One explanation.
      #
      # `chain` are the project method keys walked, entry point first; `origin` is the callee key or
      # construct name that introduced the label, or nil when no method on the path proves it directly
      # (which happens only when the table is inconsistent, and is rendered as the method chain alone).
      class Path < Data.define(:symbol, :label, :chain, :origin, :origin_source)
        # The rendering the text form prints and the JSON payload carries as `path`.
        def to_a
          origin.nil? ? chain : chain + [origin]
        end

        def to_s
          "#{to_a.join(' → ')} [#{label}]"
        end
      end

      module_function

      # The shortest path from `symbol` to a direct origin of `label`, or nil when the table proves the
      # label nowhere reachable from it.
      def shortest(table, symbol:, label:)
        entry = table[symbol]
        return nil if entry.nil?

        walk(table, symbol, label)
      end

      # Every label of `symbol`'s transitive summary, explained. Sorted by label, so the output is stable.
      def explain_all(table, symbol:)
        entry = table[symbol]
        return [] if entry.nil?

        entry.proven.to_a.filter_map { |label| shortest(table, symbol: symbol, label: label) }
      end

      def walk(table, start, label)
        queue = [[start]]
        seen = { start => true }
        until queue.empty?
          trail = queue.shift
          entry = table[trail.last]
          next if entry.nil?

          origin = direct_origin(entry, label)
          if origin
            return Path.new(symbol: start, label: label, chain: trail.freeze,
                            origin: origin.name, origin_source: origin.source)
          end

          entry.edges.each do |callee|
            next unless seen[callee].nil?

            seen[callee] = true
            queue << (trail + [callee])
          end
        end
        nil
      end

      # Which origin of this method's own summary carries the label. Sorted by rendering, so a method
      # coloured by two rows explains through the same one every time.
      def direct_origin(entry, label)
        entry.direct.bundles.find { |_origin, labels| labels.include?(label) }&.first
      end

      private_class_method :walk, :direct_origin
    end
  end
end
