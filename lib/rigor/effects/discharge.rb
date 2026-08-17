# frozen_string_literal: true

require_relative "label_set"

module Rigor
  module Effects
    # `effects.tolerated:` at judgment time — the discharge policy, **per origin** (ADR-103 WD1 / WD14;
    # normative in `docs/type-specification/effect-labels.md` § Discharge by policy).
    #
    # The rule the whole slice turns on: **a bundle is discharged when ANY of its labels is tolerated.**
    # An origin is one callee or one construct, and its labels are what that one thing does; tolerating
    # what the origin was *for* frees the transport it came with. `Logger#info` is `io` + `telemetry`, so
    # `tolerated: [telemetry]` discharges the whole bundle — the project has said "logging is fine", and
    # the `io` in that bundle is logging. A `File.read` in the same body is a different origin with a
    # different bundle, and its `io.fs.read` still counts. That is why summaries keep labels per origin at
    # all ({Summary#bundles}); a flat label set cannot tell the two `io`s apart.
    #
    # Discharge is a **judgment**, never a record. The snapshot on disk holds undischarged sets, the
    # collector attributes undischarged labels, and only the two consumers below subtract:
    # {EnvelopeCheck} (through {Propagator}'s second lane) and {SnapshotDiff}. `--no-tolerated-effects` is
    # the audit switch — the same judgment with {NONE} — and is what makes the policy inspectable
    # (Steins ADR-0084 invariant 3).
    class Discharge
      # The identity policy: nothing is tolerated, so nothing is discharged. What
      # `--no-tolerated-effects` judges with, and what a project that configured no `tolerated:` list
      # always has.
      def self.none
        @none ||= new([])
      end

      def initialize(tolerated)
        @tolerated = tolerated.is_a?(LabelSet) ? tolerated : LabelSet.new(Array(tolerated).map(&:to_s))
        freeze
      end

      # Whether the policy discharges nothing at all — the fast path every project that wrote no
      # `tolerated:` list takes, and the reason the second propagation lane costs zero when unconfigured.
      def inert?
        @tolerated.empty?
      end

      # Whether ONE origin's bundle is discharged: some member of it is tolerated (or subsumed by a
      # tolerated label — `tolerated: [io]` discharges an `io.fs.read` bundle). An empty bundle is
      # discharged by nothing, and never carries anything to discharge.
      def discharges?(labels)
        return false if inert?

        labels.to_a.any? { |label| @tolerated.admits?(label) }
      end

      # The join of every bundle this policy does NOT discharge — what a judgment reads in place of
      # {Summary#proven}. A label that arrives through both a discharged and an undischarged origin
      # survives, because the undischarged origin proves it on its own.
      def undischarged(bundles)
        return flatten(bundles) if inert?

        bundles.reduce(LabelSet::EMPTY) do |acc, (_origin, labels)|
          discharges?(labels) ? acc : acc.join(labels)
        end
      end

      private

      def flatten(bundles)
        bundles.each_value.reduce(LabelSet::EMPTY) { |acc, set| acc.join(set) }
      end
    end
  end
end
