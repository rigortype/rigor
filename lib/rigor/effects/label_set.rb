# frozen_string_literal: true

require_relative "label"

module Rigor
  module Effects
    # An immutable, sorted, de-duplicated set of effect labels — the carrier of a summary lane and
    # of an envelope's bound (ADR-103 WD1).
    #
    # Two sentinels bracket the lattice. {EMPTY} is the empty set: "no effects", the reading of
    # `%a{pure}` modulo `mutate.local`. {TOP} is the unbounded / unspecified reading: it admits
    # every label, it absorbs every join, and it is what a tag carrying an unknown label degrades
    # to (the fail-open rule). {TOP} is NOT the set of all registered labels and is deliberately
    # not enumerable — `top?` is the only way to tell it from {EMPTY} through `to_a`.
    #
    # Instances are frozen on construction and hold a frozen array, so they cross a Ractor boundary
    # and go into a cache entry as they are.
    class LabelSet
      NO_LABELS = [].freeze
      private_constant :NO_LABELS

      # Build a set from any enumerable of label strings. Members are normalised (de-duplicated and
      # sorted) so equality is structural and a snapshot rendering is deterministic.
      #
      # Raises `ArgumentError` on a member that does not satisfy {Label::PATTERN}: a LabelSet is a
      # value object over the grammar, and the fail-open handling of an unrecognised *spelling* is
      # the reader's job (it yields {TOP}), not this constructor's.
      #
      # `top:` is internal — it exists to build {TOP} and is not part of the surface later slices
      # build on.
      def initialize(labels = NO_LABELS, top: false)
        @top = top
        @labels = NO_LABELS
        unless top
          members = labels.to_a
          members.each do |label|
            raise ArgumentError, "not a well-formed effect label: #{label.inspect}" unless Label.valid?(label)
          end
          @labels = members.uniq.sort.freeze
        end
        freeze
      end

      # The unbounded set. Everything is subsumed by it; joining it with anything yields it.
      TOP = new(NO_LABELS, top: true)

      # The empty set — no effects at all.
      EMPTY = new(NO_LABELS)

      # Whether this is the unbounded sentinel {TOP}.
      def top?
        @top
      end

      # Whether this set records no labels. {TOP} is not empty: it records nothing because it
      # stands for everything.
      def empty?
        !@top && @labels.empty?
      end

      # The members, sorted, as a frozen array. {TOP} yields `[]` — consult {top?} first.
      def to_a
        @labels
      end

      # Exact membership among the recorded labels. `LabelSet.new(["io"]).include?("io.net")` is
      # false — that question is {admits?}. {TOP} records no members, so it includes none.
      def include?(label)
        @labels.include?(label)
      end

      # Whether some member of this set subsumes `label`. {TOP} admits every well-formed label.
      def admits?(label)
        return Label.valid?(label) if @top

        @labels.any? { |member| Label.subsumes?(member, label) }
      end

      # Union. {TOP} absorbs: a join involving it is {TOP}.
      #
      # A join that adds nothing returns `self` **without allocating**. That is the common case wherever
      # sets are joined in a loop — the propagator's fixpoint re-joins every edge on every visit — and the
      # sets are single-digit-sized, so the containment scan is cheaper than the construction it avoids.
      def join(other)
        return TOP if @top || other.top?
        return other if @labels.empty?

        others = other.to_a
        return self if others.empty?
        return self if others.all? { |label| @labels.include?(label) }

        self.class.new(@labels + others)
      end

      # Whether every member of this set is admitted by `bound_set` — the envelope check, modulo
      # the policy discharge that happens at judgment time. {TOP} is bounded only by {TOP}.
      def subsumed_by?(bound_set)
        return true if bound_set.top?
        return false if @top

        @labels.all? { |label| bound_set.admits?(label) }
      end

      def ==(other)
        return true if equal?(other)

        other.is_a?(LabelSet) && other.top? == @top && other.to_a == @labels
      end
      alias eql? ==

      def hash
        [self.class, @top, @labels].hash
      end

      def inspect
        return "#<Rigor::Effects::LabelSet TOP>" if @top

        "#<Rigor::Effects::LabelSet #{@labels.join(', ')}>"
      end
    end
  end
end
