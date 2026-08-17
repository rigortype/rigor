# frozen_string_literal: true

require_relative "label_set"
require_relative "origin"
require_relative "taint_cause"

module Rigor
  module Effects
    # One method's effect summary — the value the collector produces and the propagator closes over
    # (ADR-103 WD1 / WD12; the lanes and the exhaustiveness bit are normative in
    # `docs/type-specification/effect-labels.md`).
    #
    # Three carriers and one projection:
    #
    # - {#bundles} — `{Origin => LabelSet}`, the labels kept **per origin** so the judgment can discharge
    #   policy per origin (tolerating what an origin was *for* frees its transport, WD14; {Discharge}).
    # - {#declared_bundles} — the same shape for the `≤` lane, and {#declared} its flat projection. Its one
    #   producer today is the project's `effects.attribution:` table (#385), whose origins carry
    #   {Origin::ATTRIBUTION}; a *nominal supertype's* envelope joins it with #386. The lane is kept apart
    #   from {#bundles} because nothing declared is ever proven: diagnostics read {#proven} only, so an
    #   attributed label can never manufacture an `effect.envelope-exceeded`.
    # - {#exhaustive} — false when some call this method makes could not be resolved.
    # - {#causes} — why, from {TaintCause}'s closed enum, as `[cause, detail]` pairs. Empty when exhaustive.
    #
    # {#proven} is the flat projection of {#bundles}: the join of every bundle. It is computed once at
    # construction rather than memoised, because the instance is frozen (and so crosses a fork-pool marshal
    # and a Ractor boundary as it is).
    #
    # Summaries compose by {#join}, which is associative and commutative on every field, so merging a
    # project's per-file collections in any order — pooled or sequential — yields the same table.
    class Summary
      NO_BUNDLES = {}.freeze
      private_constant :NO_BUNDLES

      NO_CAUSES = [].freeze
      private_constant :NO_CAUSES

      # The bound {#trivial?} measures against. Not a user-facing knob: it is `%a{pure}`'s carve-out,
      # spelled once.
      TRIVIAL_BOUND = LabelSet.new(["mutate.local"])

      # The pure-modulo-frame-ownership summary: no origins, nothing declared, exhaustive, untainted.
      def self.empty
        @empty ||= new
      end

      # Builds a summary carrying a single taint and no labels — the fail-soft answer for a unit the
      # collector could not finish (`collector-error`) and the shape a caller uses to taint a method it
      # knows nothing else about.
      def self.tainted(cause, detail = nil)
        new(exhaustive: false, causes: [[cause, detail]])
      end

      attr_reader :bundles, :declared_bundles, :declared, :causes, :proven

      def initialize(bundles: NO_BUNDLES, declared_bundles: NO_BUNDLES, exhaustive: true, causes: NO_CAUSES)
        @bundles = normalize_bundles(bundles)
        @declared_bundles = normalize_bundles(declared_bundles)
        @exhaustive = exhaustive ? true : false
        @causes = normalize_causes(causes)
        @proven = flatten(@bundles)
        @declared = flatten(@declared_bundles)
        freeze
      end

      # Whether every call this method makes was resolved. A false bit reads "these effects, and possibly
      # more" and MUST NOT on its own produce a finding.
      def exhaustive?
        @exhaustive
      end

      # Whether this summary is worth showing at all: an exhaustive method whose whole proven footprint is
      # frame-local mutation. `mutate.local` is tolerated by every envelope (`%a{pure}` included), so a
      # method that only mutates what its own frame allocated reads as pure for reporting purposes. The
      # report omits these unless `--full` is given; the snapshot of #381 omits them from `methods:`.
      def trivial?
        @exhaustive && @proven.subsumed_by?(TRIVIAL_BOUND)
      end

      # Union in every lane: bundles join per origin, the declared lane joins, the exhaustiveness bit ANDs,
      # causes union. Reopenings of one method and the several files that contribute to it fold through
      # this.
      def join(other)
        return self if other.equal?(self)

        self.class.new(
          bundles: merge_bundles(@bundles, other.bundles),
          declared_bundles: merge_bundles(@declared_bundles, other.declared_bundles),
          exhaustive: @exhaustive && other.exhaustive?,
          causes: @causes + other.causes
        )
      end

      def ==(other)
        other.is_a?(Summary) && other.bundles == @bundles && other.declared_bundles == @declared_bundles &&
          other.exhaustive? == @exhaustive && other.causes == @causes
      end
      alias eql? ==

      def hash
        [self.class, @bundles, @declared_bundles, @exhaustive, @causes].hash
      end

      def inspect
        "#<Rigor::Effects::Summary #{@proven.to_a.join(', ')}#{' ?' unless @exhaustive}>"
      end

      private

      def merge_bundles(mine, theirs)
        return mine if theirs.empty?
        return theirs if mine.empty?

        merged = mine.dup
        theirs.each { |origin, set| merged[origin] = merged.key?(origin) ? merged[origin].join(set) : set }
        merged
      end

      def flatten(bundles)
        bundles.each_value.reduce(LabelSet::EMPTY) { |acc, set| acc.join(set) }
      end

      # Origins are sorted by their rendering so two summaries built from the same facts in different
      # orders are `==` and render identically. A repeated origin joins rather than clobbers.
      def normalize_bundles(bundles)
        return NO_BUNDLES if bundles.empty?

        merged = {}
        bundles.each do |origin, set|
          merged[origin] = merged.key?(origin) ? merged[origin].join(set) : set
        end
        merged.reject { |_, set| set.empty? }.sort_by { |origin, _| origin.to_s }.to_h.freeze
      end

      # `[cause, detail]` pairs, de-duplicated and sorted. A cause outside {TaintCause}'s enum is dropped
      # rather than raised on: the collector is fail-soft, and a producer bug must not take a run down.
      def normalize_causes(causes)
        return NO_CAUSES if causes.empty?

        causes
          .filter_map { |cause, detail| [cause.to_s, detail&.to_s].freeze if TaintCause.valid?(cause) }
          .uniq
          .sort_by { |cause, detail| [cause, detail.to_s] }
          .freeze
      end
    end
  end
end
